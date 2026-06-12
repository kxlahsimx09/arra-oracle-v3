#!/usr/bin/env bash
# provision-regression-droplet.sh — idempotent bring-up of a DigitalOcean (or any
# Ubuntu) host as a mobiz integration-test regression runner.
#
# Codifies the recipe proven green on temp-mb-regression-droplet (178.128.93.199)
# 2026-06-12 (learning 2026-06-12_fleet-infra-temp-mb-regression-droplet). Runs
# FROM the control machine; everything happens on the target over SSH. Idempotent:
# re-running on an already-provisioned host is a near no-op + a smoke check.
#
# Usage:   bash scripts/provision-regression-droplet.sh [user@host] [--smoke]
# Default host: root@178.128.93.199
#
# PREREQUISITE (the one manual step — cannot be scripted): per-repo GitHub deploy
# keys must already be staged on the target at /root/.ssh/{deploy_mobiz,
# deploy_bankbot} with a /root/.ssh/config mapping Host github-mobiz / github-bankbot
# (IdentitiesOnly yes). Add the .pub keys under each repo's Settings→Deploy keys.
# This script verifies they work and aborts with guidance if not.

set -uo pipefail

HOST="${1:-root@178.128.93.199}"
SMOKE=0; [ "${2:-}" = "--smoke" ] && SMOKE=1
MOBIZ_DIR="/root/Code/github.com/kokarat/mobiz-payment-gateway"
NODE_MAJOR=20

ssh_opts=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes)
d() { ssh "${ssh_opts[@]}" "$HOST" "$@"; }
say() { printf '\n\033[0;36m[provision]\033[0m %s\n' "$*"; }
ok()  { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[0;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

say "Target: $HOST"
d 'echo ok' >/dev/null 2>&1 || die "cannot SSH to $HOST (need passphrase-less key, e.g. ~/.ssh/id_ed25519)"
ok "SSH reachable"

# ── 1. Deploy keys (verify — manual prerequisite) ─────────────────────────────
say "Verifying GitHub deploy-key access (mobiz + bank-bot)…"
d 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes -T git@github-mobiz   2>&1 | grep -q "successfully authenticated"' \
  || die "github-mobiz deploy key missing/unauthorized. Stage /root/.ssh/deploy_mobiz + config, add .pub to kokarat/mobiz-payment-gateway Deploy keys."
d 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes -T git@github-bankbot 2>&1 | grep -q "successfully authenticated"' \
  || die "github-bankbot deploy key missing/unauthorized. Stage /root/.ssh/deploy_bankbot + config, add .pub to kokarat/bank-bot Deploy keys."
ok "both deploy keys authenticate (repo-scoped)"

# ── 2. Host packages: docker, node, mongosh (+ python3/curl/jq usually present) ─
say "Ensuring host packages (docker, node ${NODE_MAJOR}, mongosh)…"
d "command -v docker >/dev/null 2>&1" \
  || die "docker not installed on target (install docker-ce first; see setup-droplet.sh Step 2)"
d "docker info >/dev/null 2>&1" || die "docker daemon not running on target"
d bash -se <<REMOTE || die "package install failed"
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - >/tmp/prov-node.log 2>&1
  apt-get install -y -qq nodejs >>/tmp/prov-node.log 2>&1
fi
if ! command -v mongosh >/dev/null 2>&1; then
  curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg 2>/dev/null
  echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list
  apt-get update -qq >/tmp/prov-mongosh.log 2>&1
  apt-get install -y -qq mongodb-mongosh >>/tmp/prov-mongosh.log 2>&1
fi
# /etc/hosts: setup-infra.sh mongo_exec (DOCKER_MODE=true) hardcodes mongodb://mongodb:27117;
# the ports are published to host, so alias the docker-net names → loopback.
grep -qE '(^| )mongodb( |$)' /etc/hosts || echo '127.0.0.1 mongodb redis backend mock-bank' >> /etc/hosts
# redis-tools + socat forward: setup-infra.sh redis_exec (DOCKER_MODE=true) runs
# 'redis-cli -h redis -p 6379', but redis publishes 6399:6379 (port mismatch —
# unlike mongo's matching 27117:27117). A persistent socat 127.0.0.1:6379 → :6399
# makes the helper's FLUSHALL (permission-cache invalidation) actually land;
# without it test-deposit-refund fails "Insufficient permissions: deposit:refund".
command -v redis-cli >/dev/null 2>&1 && command -v socat >/dev/null 2>&1 \
  || apt-get install -y -qq redis-tools socat >/tmp/prov-redis.log 2>&1
cat > /etc/systemd/system/redis-fwd.service <<'UNIT'
[Unit]
Description=Forward redis:6379 -> 127.0.0.1:6399 for integration-test redis_exec
After=network.target docker.service
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:6379,bind=127.0.0.1,fork,reuseaddr TCP:127.0.0.1:6399
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now redis-fwd.service >/dev/null 2>&1
REMOTE
ok "node=$(d 'node -v' 2>/dev/null)  mongosh=$(d 'mongosh --version 2>/dev/null | head -1')  hosts-alias set"
ok "redis-fwd: $(d 'redis-cli -h redis -p 6379 PING 2>&1' 2>/dev/null) (helper path -h redis -p 6379)"

# ── 3. Clone repos (mobiz + nested bank-bot), or fast-forward if present ───────
say "Cloning/refreshing repos (bank-bot nests inside mobiz, gitignored)…"
d bash -se <<REMOTE || die "clone/sync failed"
set -e
mkdir -p "$(dirname $MOBIZ_DIR)"
if [ -d "$MOBIZ_DIR/.git" ]; then
  git -C "$MOBIZ_DIR" fetch origin main --quiet && git -C "$MOBIZ_DIR" merge --ff-only origin/main --quiet || true
else
  git clone --quiet git@github-mobiz:kokarat/mobiz-payment-gateway "$MOBIZ_DIR"
fi
if [ -d "$MOBIZ_DIR/bank-bot/.git" ]; then
  git -C "$MOBIZ_DIR/bank-bot" fetch origin main --quiet && git -C "$MOBIZ_DIR/bank-bot" merge --ff-only origin/main --quiet || true
else
  git clone --quiet git@github-bankbot:kokarat/bank-bot "$MOBIZ_DIR/bank-bot"
fi
REMOTE
ok "mobiz @ $(d "git -C $MOBIZ_DIR rev-parse --short HEAD")  bank-bot @ $(d "git -C $MOBIZ_DIR/bank-bot rev-parse --short HEAD")"

# ── 4. Build images ───────────────────────────────────────────────────────────
say "docker compose build (cached layers short-circuit when unchanged)…"
d "cd $MOBIZ_DIR/integration-tests && docker compose build" 2>&1 | tail -3
ok "images built"

# ── 5. Optional smoke ─────────────────────────────────────────────────────────
if [ "$SMOKE" = 1 ]; then
  say "Smoke: bring up stack + run test-deposit-flow.sh…"
  d "cd $MOBIZ_DIR/integration-tests && docker compose up -d" >/dev/null 2>&1
  if d "cd $MOBIZ_DIR && TEST_RUNNER_MODE=1 DOCKER_MODE=true SKIP_INFRA=true timeout 540 bash integration-tests/test-deposit-flow.sh >/root/provision-smoke.log 2>&1"; then
    ok "smoke PASS (test-deposit-flow.sh)"
  else
    die "smoke FAILED — see $HOST:/root/provision-smoke.log"
  fi
fi

say "Provisioned. Run the suite with:  REGRESSION_HOST=$HOST bash scripts/regression-on-droplet.sh"
