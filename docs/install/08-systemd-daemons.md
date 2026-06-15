# 08 — Daemons on Linux: systemd units (the launchd → systemd translation)

The Linux counterpart to [05-daemons.md](05-daemons.md). On macOS the inbox-watcher
runs under **launchd** and the rest under **nohup** ("restart manually"). On Linux
they all become **systemd `--user` units** with `Restart=always` — auto-restart on
crash AND on reboot, journald logs, and none of the launchd "GUI-session only"
caveat. *Validated on the 2026-06-15 EC2 migration (Ubuntu 24.04): a `Restart=always`
user unit auto-restarted after its MainPID was killed, headless over SSH.*

## Prerequisite (the tested gotcha)

`systemctl --user` over SSH only works once the user manager is running. Enable
**linger** (starts the user manager without an interactive login — the headless
equivalent of launchd KeepAlive) and export `XDG_RUNTIME_DIR`:

```bash
sudo loginctl enable-linger "$USER"
export XDG_RUNTIME_DIR=/run/user/$(id -u)     # add to ~/.bashrc
mkdir -p ~/.config/systemd/user
```
Without these, `systemctl --user` errors with `Failed to connect to bus`.

## Daemon inventory (start order — strict; later units need Oracle up)

| Order | Unit | Was (macOS) | Notes |
|---|---|---|---|
| — | `ollama.service` | `brew services` | **system** unit, added by the Ollama installer (already enabled) |
| 1 | `oracle-http.service` | nohup / optional plist | the :47778 MCP backend |
| 2 | `inbox-watcher.service` | **launchd** KeepAlive | core fleet dispatch — `TimeoutStopSec` matters (below) |
| 3 | `w2-watcher.service` | nohup | settle-window deploy watcher |
| 4 | `brew-ops-bot.service` | nohup | Telegram bot (spawns chat-watcher) |
| 5 | `orchestrator-bot.service` | nohup | Telegram bot |

`ollama.service` is **system-level** (runs as the `ollama` user) — leave it as the
installer set it; the user units below reference it with `After=` only (ordering
across the system/user boundary is best-effort, which is fine — Oracle retries the
embedder).

## Unit templates → `~/.config/systemd/user/`

`%h` = the home dir; bun is at `%h/.bun/bin/bun`. Edit the repo path if yours differs.

```ini
# oracle-http.service
[Unit]
Description=Oracle HTTP API + MCP backend (:47778)
After=network-online.target ollama.service
[Service]
Type=simple
WorkingDirectory=%h/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
Environment=ORACLE_DATA_DIR=%h/.arra-oracle-v2
Environment=PATH=%h/.bun/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.bun/bin/bun run server
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
```

```ini
# inbox-watcher.service
[Unit]
Description=Oracle inbox-watcher (fleet dispatch)
After=oracle-http.service
Requires=oracle-http.service
[Service]
Type=simple
WorkingDirectory=%h/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
ExecStart=/bin/bash %h/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/scripts/inbox-watcher.sh start
Restart=always
RestartSec=10
# The watcher traps SIGTERM but defers until its current gc sweep returns (~40s).
# TimeoutStopSec must exceed that, or systemd SIGKILLs mid-sweep (the launchd guide's
# 40s-wait note, in systemd form).
TimeoutStopSec=60
[Install]
WantedBy=default.target
```

```ini
# w2-watcher.service  (also: brew-ops-bot.service, orchestrator-bot.service — same shape)
[Unit]
Description=w2-watcher (staging deploy settle-window)
After=oracle-http.service
[Service]
Type=simple
WorkingDirectory=%h/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
ExecStart=/bin/bash %h/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/scripts/w2-watcher.sh
Restart=always
RestartSec=15
[Install]
WantedBy=default.target
```

For **brew-ops-bot** / **orchestrator-bot** use `scripts/brew-ops-bot/bot.sh` /
`scripts/orchestrator-bot/bot.sh` as `ExecStart` (they read `~/.cache/<bot>/.env`
and spawn their own chat-watcher — no separate unit needed).

## Enable + start (in order)

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user daemon-reload
for u in oracle-http inbox-watcher w2-watcher brew-ops-bot orchestrator-bot; do
  systemctl --user enable --now "$u.service"
  sleep 2; systemctl --user is-active "$u.service"
done
```

## Logs + ops (journald replaces the macOS log files)

```bash
journalctl --user -u inbox-watcher.service -f          # follow
journalctl --user -u oracle-http.service --since "10 min ago"
systemctl --user status inbox-watcher.service
systemctl --user restart inbox-watcher.service         # after re-syncing arra (§3c discipline)
```

> **Runtime-checkout discipline still applies** (02-repos-symlinks §3c): both
> `arra-oracle-v3` and `maw-js` primaries stay on `feat/all-prs-rebased`; after a
> `git merge --ff-only`, **`systemctl --user restart inbox-watcher.service`** (the
> bash daemon re-reads its file on restart) — the systemd equivalent of the macOS
> "stop then start" step.

## ⚠️ Blocked-on: BSD→GNU portability (07 §8) — do this BEFORE enabling the units

The daemons will *start* but **silently misbehave** until the BSD-isms found in the
2026-06-15 audit are fixed (Linux GNU coreutils differ):

- `scripts/inbox-watcher.sh` — **5× `stat -f %m`** (lines ~417/744/781/1718/1765):
  JSONL mtime/recency → returns empty on Linux → liveness/dispatch misfires. **Highest risk.**
- `scripts/w2-watcher.sh` — **3× `date -r <epoch>`** (~196/197/469): on Linux `date -r`
  reads the arg as a *file* → wrong wake timestamps + broken silent-fail alerts.
- `scripts/brew-ops-bot/bot.sh`, `scripts/inbox-loop-closure-hook.sh` — `stat -f %m`.
- `scripts/orchestrator-bot/chat-watcher.sh` already does `stat -f %z || stat -c %s`
  — the portable pattern to copy everywhere.

Fix forward (portable form or `[[ "$(uname)" == Darwin ]]` branch) and PR back. The
6 `install-launchd*.sh` / `*.plist` installers stay macOS-only; this file is their
Linux replacement.

## Cutover — old runner → new (the flip)

You **cannot parallel-run the watchers/bots on both boxes** — they share state:
- `inbox-watcher` + `w2-watcher`: same git vault → push races + the SAME envelope
  dispatched twice.
- Telegram bots: one token → `getUpdates` returns **409 Conflict** to the second.
- `oracle-http` is the ONE exception: per-box `oracle.db` + localhost — fine on both.

So the new box's `inbox-watcher`/`w2-watcher`/`*-bot` units are **enabled but NOT
started** until the old box's are stopped. Flip order:

1. **Don't flip mid-campaign.** Let the old box finish/clear in-flight agent work
   first (active dispatches, open campaigns). The new box is staged and waiting.
2. **EBS snapshot** of the new box; **final vault sync** (old box `git add -A &&
   commit && push`; new box `git pull`) so no inbox envelope is stranded.
3. **Stop the OLD daemons — map them PRECISELY first.** Pidfiles go stale and the
   daemon may not be under the documented launchd label / a clean `nohup` — a broad
   `pkill -f inbox-watcher` will also hit agent sessions whose command line contains
   the string. Find the real parents (`ps -Ao pid,ppid,command | grep -E
   'scripts/(inbox-watcher|w2-watcher).sh|/(brew-ops|orchestrator)-bot/bot.sh'`,
   `ppid=1` = the daemon), `launchctl bootout` any launchd job so it doesn't
   respawn, then kill those exact pids. Reap orphaned `chat-watcher.sh` children.
4. **Start the new daemons:** `systemctl --user start inbox-watcher w2-watcher
   brew-ops-bot orchestrator-bot`.
5. **Verify:** all `--user is-active` = active; a Telegram `getMe` succeeds (one
   consumer now); `inbox-watcher.sh status` shows it polling. Demote the old box to
   an operator terminal. Rollback = restart the old daemons (nothing was deleted).

## Nightly full reindex (systemd timer)

The FTS5 + bge-m3 vector index drifts as learnings accrue — rebuild it nightly. The
vector step is **latency-bound, not CPU-bound** (sequential Ollama round-trips; the
box sits ~98% idle at ~0.4 doc/s → ~3.4 h for ~5k docs, so more vCPU barely helps).
It runs cheap in the background, **FTS stays up the whole time** (FTS5 is SQLite, not
LanceDB) and vector degrades gracefully to FTS-only during the rebuild; the service
restarts `oracle-http` at the end so it serves the fresh vectors.

`~/.config/systemd/user/oracle-reindex.service`:
```ini
[Unit]
Description=Oracle full reindex (FTS5 + bge-m3 vectors)
After=ollama.service
[Service]
Type=oneshot
WorkingDirectory=%h/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
# ORACLE_REPO_ROOT = the VAULT repo (github.com/ beside ψ/), NOT the data dir, or
# only ~98 of ~1200 learnings index — the repoRoot trap (04-data §2).
Environment=ORACLE_REPO_ROOT=%h/Code/github.com/kxlahsimx09/mb_agent_oracle_memory
Environment=ORACLE_DATA_DIR=%h/.arra-oracle-v2
Environment=PATH=%h/.bun/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.bun/bin/bun run reindex:full
ExecStartPost=/usr/bin/systemctl --user restart oracle-http.service
TimeoutStartSec=6h
```
`~/.config/systemd/user/oracle-reindex.timer`:
```ini
[Unit]
Description=Nightly Oracle full reindex
[Timer]
OnCalendar=*-*-* 03:00:00      # set the box TZ first: sudo timedatectl set-timezone Asia/Bangkok
Persistent=true                # catch up a missed run if the box was off
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
```
```bash
systemctl --user daemon-reload && systemctl --user enable --now oracle-reindex.timer
systemctl --user list-timers oracle-reindex.timer    # confirm the NEXT time
```
systemd runs **one instance per unit**, so a slow rebuild never overlaps the next
night's trigger. Logs: `journalctl --user -u oracle-reindex.service`.
