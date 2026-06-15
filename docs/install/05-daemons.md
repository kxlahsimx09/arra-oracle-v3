# 05 — Daemons: Start Order, Logs & Fixes

## Daemon Inventory

| Daemon | Script | Supervisor | Auto-restart |
|--------|--------|------------|--------------|
| Oracle HTTP | `bun src/server.ts` | launchd (optional) | yes if installed |
| inbox-watcher | `scripts/inbox-watcher.sh start` | **launchd** `com.soulbrews.inbox-watcher` | yes (KeepAlive=true) |
| w2-watcher | `scripts/w2-watcher.sh` | nohup | no — restart manually |
| brew-ops-bot | `scripts/brew-ops-bot/bot.sh` | nohup | no — restart manually |
| chat-watcher (brew-ops) | `scripts/brew-ops-bot/chat-watcher.sh` | spawned by bot.sh | auto-recover (WATCHER_RECOVER_INTERVAL=300s) |
| fleet-health | `scripts/brew-ops-bot/fleet-health.sh` | called by bot.sh | n/a |
| orchestrator-bot | `scripts/orchestrator-bot/bot.sh` | nohup | no |
| chat-watcher (orch) | `scripts/orchestrator-bot/chat-watcher.sh` | spawned by bot.sh | auto-recover |

---

## Start Order (strict)

Start in this order. Later daemons depend on Oracle being up.

```
1. Oracle HTTP (:47778)
2. inbox-watcher    (launchd — fires immediately after install)
3. w2-watcher
4. brew-ops-bot
5. orchestrator-bot
```

---

## 1. Oracle HTTP Server

```bash
ARRA=~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3

# Start (foreground for first-run check):
bun run server --cwd "$ARRA"

# Verify:
curl -s http://localhost:47778/api/health | jq .
# → { "status": "ok", ... }
```

**PID file:** `~/.arra-oracle-v2/oracle-http.pid`
**Logs:** stdout/stderr of the bun process.

For production keep-alive, use the example plist at
`scripts/com.oracle.server.plist.example` (copy, edit, load with launchctl).

---

## 2. inbox-watcher (launchd supervised)

This is the fleet's core dispatch mechanism. It **must** run under launchd
for KeepAlive auto-restart. The installer is idempotent.

```bash
ARRA=~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
bash "$ARRA/scripts/install-inbox-watcher-supervisor.sh"
```

**What the installer does (in order):**
1. Renders `scripts/launchd/com.soulbrews.inbox-watcher.plist` → `~/Library/LaunchAgents/`
   substituting `__ARRA__` and `__HOME__` with real paths.
2. Tears down any existing launchd job (`launchctl bootout`).
3. Stops any running watcher and **waits up to 40s** for it to exit
   (inbox-watcher traps SIGTERM but defers until the current gc sweep
   returns — a slow stop is normal; racing `launchctl load` against a
   still-dying process causes KeepAlive respawn-fail loops).
4. Bootstraps the new job and kickstarts it immediately.
5. Waits up to 6s for the process to appear, then prints confirmation.

**Log:** `~/.cache/soul-brews-startup/inbox-watcher.launchd.log`

```bash
tail -f ~/.cache/soul-brews-startup/inbox-watcher.launchd.log
pgrep -fl "inbox-watcher.sh start"
bash "$ARRA/scripts/inbox-watcher.sh" status
```

**Note on session type:** launchd KeepAlive auto-restart is honoured only in
the GUI (Aqua) login session. If you install from SSH/Background, the job
starts immediately but will only auto-restart after the next GUI login.

---

## 3. w2-watcher

Watches mobiz-payment-gateway and bank-bot for new commits; wakes
pg-writer, bot-writer, and pg-tester roles after a 30-min settle window.

```bash
ARRA=~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
mkdir -p ~/.cache/soul-brews-startup
nohup bash "$ARRA/scripts/w2-watcher.sh" \
  >> ~/.cache/soul-brews-startup/w2-watcher.log 2>&1 &
disown
echo $! > ~/.cache/soul-brews-startup/w2-watcher.pid
```

**Log:** `~/.cache/soul-brews-startup/w2-watcher.log`
**Poll interval:** 5 min; settle window: 30 min; min-gap between fires: 2 hr.

---

## 4. brew-ops-bot

Telegram bot for Soul-Brews ops awareness. Reads credentials from
`~/.cache/brew-ops-bot/.env`.

```bash
mkdir -p ~/.cache/brew-ops-bot
nohup bash "$ARRA/scripts/brew-ops-bot/bot.sh" \
  >> ~/.cache/brew-ops-bot/bot.log 2>&1 &
disown
echo $! > ~/.cache/brew-ops-bot/bot.pid
```

**Logs:**
- `~/.cache/brew-ops-bot/bot.log`
- `~/.cache/brew-ops-bot/watcher.log` (chat-watcher)
- `~/.cache/brew-ops-bot/audit.log`

**chat-watcher reap fix (CRITICAL — 2026-05-26):**
`chat-watcher.sh` tails a claude session's JSONL and pushes new turns to
Telegram. The JSONL for a new session with a large `CLAUDE.md` can take
**7+ minutes** to appear. The default wait was 30s → 180s → now **480s**:

```bash
# If deploying from source (already in chat-watcher.sh):
# JSONL_WAIT_SECONDS=${JSONL_WAIT_SECONDS:-480}
```

bot.sh also runs a periodic recover loop (`WATCHER_RECOVER_INTERVAL=300s`)
to respawn any watcher that bailed. Both are in the checked-in scripts.

---

## 5. orchestrator-bot

Telegram daemon for the orchestrator role (chat `2002026175`). Writes
envelopes to `~/.arra-oracle-v2/ψ/inbox/for-orchestrator/` which
inbox-watcher routes to the orchestrator session.

```bash
mkdir -p ~/.cache/orchestrator-bot
nohup bash "$ARRA/scripts/orchestrator-bot/bot.sh" \
  >> ~/.cache/orchestrator-bot/bot.log 2>&1 &
disown
echo $! > ~/.cache/orchestrator-bot/bot.pid
```

**Logs:** `~/.cache/orchestrator-bot/bot.log`

---

## Stop Commands

```bash
# inbox-watcher (launchd)
ARRA=~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
bash "$ARRA/scripts/inbox-watcher.sh" stop

# nohup daemons
kill $(cat ~/.cache/soul-brews-startup/w2-watcher.pid) 2>/dev/null
kill $(cat ~/.cache/brew-ops-bot/bot.pid)              2>/dev/null
kill $(cat ~/.cache/orchestrator-bot/bot.pid)          2>/dev/null
```

---

## Hooks (Claude Code global)

```bash
# Stop-hook loop-closure enforcement (blocks oracle sessions from
# exiting while their directed-inbox loop is open)
bash "$ARRA/scripts/install-inbox-loop-closure-hook.sh"

# Orchestrator guard (blocks docs/code edits from the orchestrator window)
bash "$ARRA/scripts/install-orchestrator-guard-hook.sh"
```

---

## Cutover — old box → new box (the flip)

You **cannot run the watchers/bots on both boxes at once** — they share state:
- `inbox-watcher` + `w2-watcher`: same git vault → push races + the SAME envelope
  dispatched twice.
- Telegram bots: one token → the second poller gets `getUpdates` **409 Conflict**.
- `oracle-http` is the one exception (per-box `oracle.db` + localhost) — fine on both.

So bring the new box up **ready but with its watchers/bots stopped**, then flip:

1. **Don't flip mid-campaign.** Let the old box finish/clear in-flight agent work
   first; the new box waits.
2. **Final vault sync** (old box `git add -A && commit && push`; new box `git pull`)
   so no inbox envelope is stranded. (Cloud: also EBS-snapshot the new box.)
3. **Stop the OLD daemons — map them PRECISELY first.** Pidfiles go stale and a
   daemon may not be under the documented launchd label; a broad `pkill -f
   inbox-watcher` also kills agent sessions whose command line contains the string.
   Find real parents: `ps -Ao pid,ppid,command | grep -E
   'scripts/(inbox-watcher|w2-watcher).sh|/(brew-ops|orchestrator)-bot/bot.sh'`
   (`ppid=1` = the daemon). `launchctl bootout` the launchd job so it can't respawn,
   kill those exact pids, reap orphaned `chat-watcher.sh`.
4. **Start the new daemons** (macOS: the launchd installer + `nohup` blocks above;
   Linux: `systemctl --user start …`, see [08-systemd-daemons.md](08-systemd-daemons.md)).
5. **Verify:** a Telegram `getMe` succeeds (one consumer now), `inbox-watcher.sh
   status` shows it polling. Demote the old box to an operator terminal. Rollback =
   restart the old daemons (nothing was deleted).
