# 07 — Linux / Cloud Migration Track (the non-macOS path)

The 00–06 guide assumes a **macOS server** (Homebrew + launchd). This track is the
**Linux / cloud** counterpart — use it for an EC2 / VPS / bare-metal Linux box. It
documents only what **differs**; for the unchanged parts (repo inventory, symlink
topology, secrets inventory, data stores, the reindex `ORACLE_REPO_ROOT` trap)
follow the referenced macOS section. Daemons (launchd → systemd) get their own
file → [08-systemd-daemons.md](08-systemd-daemons.md).

> **Why this track exists:** the fleet outgrew an 8 GB Mac (RAM exhausted, heavy
> swap, CPU saturated → "agents feel slow"). The fix is a bigger Linux host.
> First proven on AWS EC2 `ap-southeast-1`, 2026-06-15. Worked example with real
> IDs: `ψ/plans/2026-06-15_oracle-ec2-migration.md`.

## macOS → Linux translation at a glance

| macOS (00–06) | Linux / cloud (this track) |
|---|---|
| Homebrew `brew install` | `apt-get install` (+ `go install` for **ghq** — not in apt) |
| launchd plist + `launchctl` | **systemd** unit (`systemctl --user` + `enable-linger`) → 08 |
| `nohup … & disown` (w2 / bots, "restart manually") | systemd `Restart=always` (auto-restart + survives reboot) |
| `brew services start ollama` | `ollama serve` systemd unit (the official installer adds it) |
| `/opt/homebrew/bin` in PATH | `/usr/bin` + `~/.bun/bin` + `~/.local/bin` |
| BSD `stat -f` / `date -r` | GNU `stat -c` / `date -d` → **portability audit** (§8) |
| launchd "GUI/Aqua session only" KeepAlive caveat | **gone** — systemd runs headless fully (a cloud advantage) |
| `~/.aws/credentials` copied | **IAM instance-profile role** (never copy account-root creds) |
| (starts from a fresh box) | **Phase -1: provision the instance** (new) |

---

## Phase -1 — Provision the instance (cloud — NEW)

RAM is the bottleneck (each agent ~150–560 MB · Ollama `bge-m3` ~600 MB · headless
Chromium ~1 GB · builds). Size for RAM first → memory-optimized.

| Tier | vCPU / RAM | example | ~/mo 24×7 |
|---|---|---|---|
| recommended | 8 / 64 GB | `r7i.2xlarge` | ~$385 |
| value (ARM) | 8 / 64 GB | `r7g.2xlarge` | ~$310 |
| interim / budget | 4 / 32 GB | `r7i.xlarge` | ~$200 |

**EC2 gotchas (hit live 2026-06-15):**

1. **vCPU quota.** A fresh account's On-Demand **Standard** quota is **8 vCPU**
   (Service Quotas `L-1216C47A`) — r7i.2xlarge (8 vCPU) plus any existing
   instances won't fit (`VcpuLimitExceeded`). Request the increase **first**:
   `aws service-quotas request-service-quota-increase --service-code ec2
   --quota-code L-1216C47A --desired-value 32`. It opens an AWS **case**
   (`CASE_OPENED`, hours — not instant). Start on the interim 4-vCPU box that fits
   the free quota, then **resize**: `stop-instances` → `modify-instance-attribute
   --instance-type r7i.2xlarge` → `start-instances` (same EBS + EIP; ~5 min).
2. Keypair → `~/.ssh/<key>.pem` (chmod 600). Security group: SSH 22 from the
   operator IP **only** (consider SSM Session Manager instead). 200 GB gp3 root.
   Ubuntu 24.04 LTS AMI (Canonical owner `099720109477`). Allocate + associate an
   **EIP** — a stable IP across the resize stop/start.

---

## Phase 0 — System deps (apt)  ↔ [01-deps.md](01-deps.md)

```bash
sudo apt-get update -y
sudo apt-get install -y build-essential git tmux jq curl wget unzip ripgrep \
  fd-find python3 python3-pip rsync htop lsof procps sqlite3 ca-certificates gnupg
# Node 22 + bun (→ ~/.bun/bin)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs
curl -fsSL https://bun.sh/install | bash
# ghq is NOT in apt — install via go (or grab the GitHub release binary)
sudo apt-get install -y golang-go && go install github.com/x-motemen/ghq@latest
echo 'export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/go/bin:$PATH"' >> ~/.bashrc
# gh (apt repo), aws-cli v2 (installer), vercel + wrangler (npm -g),
# supabase (release tarball → /usr/local/bin) — standard Linux installs.
# claude-code: use the NATIVE installer (matches the Mac's ~/.local/share/claude/versions)
curl -fsSL https://claude.ai/install.sh | bash      # → ~/.local/bin/claude
```

### Ollama (systemd, not `brew services`)
```bash
curl -fsSL https://ollama.com/install.sh | sh   # installs ollama + a systemd unit
ollama pull bge-m3                               # ~600 MB; on a <4 GB box use nomic-embed-text
systemctl status ollama && curl -s localhost:11434/api/tags | jq '.models[].name'
```

---

## Phase 1 — AWS creds: IAM instance-profile role (NOT copied creds — NEW)

brew-ops + bank-bot deploys need AWS, but the macOS secrets inventory (§03) has
**no AWS entry**. On a cloud box, attach a **scoped IAM role** to the instance —
the SDK/CLI pick it up with no static keys on disk. **Never copy
`~/.aws/credentials`, and never put the account-root `root-bootstrap` profile on
the box.**

```bash
aws ec2 associate-iam-instance-profile --instance-id <id> \
  --iam-instance-profile Name=oracle-runner-deploy        # role scoped to the deploy actions
aws sts get-caller-identity      # on the box → shows the assumed role, no keys on disk
```

A non-root token that must be a file (e.g. a Supabase access token) lives in the
fleet-secret slots (§03), not under `~/.aws/`.

---

## Phases 2–6 — identical to macOS (follow the referenced sections verbatim)

These are OS-independent (`git`, `ghq`, `rsync`, `ln -sfn`, `bun`):

- **ghq root + clone the 7 repos** → [02-repos-symlinks.md](02-repos-symlinks.md) (`git config --global ghq.root "$HOME/Code"`).
- **Secrets** → [03-secrets.md](03-secrets.md): the `scp` tarball (`fleet-secrets/`, `~/.cache/{brew-ops,orchestrator}-bot/.env`, `~/.claude.json`) is identical; add only the AWS-role note above. After untar: `chmod 700 fleet-secrets`, `chmod 600` the `.env`s.
- **Data** → [04-data.md](04-data.md): rsync `oracle.db` + `lancedb/` + the ψ vault identically. **The `ORACLE_REPO_ROOT` reindex trap (point it at the vault repo, not the data dir, or you index only ~98 of ~950 learnings) is OS-independent — applies unchanged.**
- **Build** → quickstart Phase 5 (`bun install` / `db:push` / `bun run build`).
- **Symlink topology** → [02-repos-symlinks.md](02-repos-symlinks.md) §Symlink Topology — identical.

---

## Phase 7 — Daemons as systemd  → [08-systemd-daemons.md](08-systemd-daemons.md)

The launchd plist (inbox-watcher) + the nohup daemons (Oracle HTTP, w2-watcher,
brew-ops-bot, orchestrator-bot, ollama) all become **systemd `--user` units** with
`Restart=always` + `loginctl enable-linger <user>`. Strictly better than the macOS
setup: auto-restart on crash **and** on reboot, journald logs, and none of the
launchd "GUI-session only" caveat. Unit templates + start order in 08.

---

## Phase 8 — Script portability audit (BSD → GNU — NEW)

The fleet scripts were written for macOS (BSD coreutils). These forms **silently
misbehave** on Linux — audit before trusting the daemons:

| BSD (macOS) | GNU (Linux) | where it bites |
|---|---|---|
| `stat -f %m FILE` | `stat -c %Y FILE` | inbox-watcher JSONL mtime / recency |
| `date -r <epoch>` | `date -d @<epoch>` | log / envelope timestamps |
| `sed -i '' …` | `sed -i …` | in-place edits |
| `readlink FILE` | `readlink -f FILE` | symlink resolution |
| `pgrep -fl` (fmt differs) | `pgrep -af` | agent PID tracking |

```bash
rg -n "stat -f|date -r|sed -i ''|readlink [^-]|pgrep -fl" \
  ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/scripts/
```
**Run live 2026-06-15 — real hits (do not skip):** `inbox-watcher.sh` ×5 `stat -f %m`
(the core daemon — JSONL liveness breaks), `w2-watcher.sh` ×3 `date -r`, plus
`brew-ops-bot/bot.sh` + `inbox-loop-closure-hook.sh`. `chat-watcher.sh` already
shows the portable form (`stat -f %z || stat -c %s`). The fix-list + why-it-bites
is in [08-systemd-daemons.md](08-systemd-daemons.md) §Blocked-on. Fix forward
(portable form, or `[[ "$(uname)" == Darwin ]]`) and PR back.

---

## Phases 9–11 — MCP, verify, cutover

- **MCP + sub-agents** → quickstart Phase 8 — same; just fix the `~/.claude.json`
  `mcpServers["arra-oracle-v3"].args` path for the new `$HOME`.
- **Verify** → [06-verify.md](06-verify.md): `/api/health`, `/api/stats`
  (learning count must be ~950+, **not ~98** — the repoRoot trap), `maw oracle ls`,
  `arra_search`.
- **Cutover (NEW):** parallel-run — keep the Mac fleet up; validate agents + a
  build + one deploy on the new box; take an **EBS snapshot**; then shift the fleet
  over and demote the Mac to an operator terminal. Rollback = keep using the Mac
  until the new box has a few clean days.
