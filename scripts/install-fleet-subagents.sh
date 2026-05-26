#!/usr/bin/env bash
# install-fleet-subagents.sh
#
# Deploys the shared, fleet-wide sonnet sub-agents to the USER-level agents dir
# (~/.claude/agents/) so EVERY role in EVERY repo can delegate to them — not just
# arra-oracle-v3 sessions. (Project-level .claude/agents only reach that repo;
# the dpay + arra MCP servers are configured user-level in ~/.claude.json, so a
# user-level dpay-finder works everywhere.)
#
# The sub-agents:
#   • code-finder  (sonnet) — read-only code search; returns file:line + excerpts.
#   • dpay-finder  (sonnet) — read-only dpay PROD payment-DB queries via dpay MCP.
#
# Both run on sonnet to keep large/noisy search + prod-query output out of the
# (opus) main session's context, and cheaper.
#
# What it does (idempotent — safe to re-run): copies the source agent files to
# ~/.claude/agents/. Re-run after editing .claude/agents/{code-finder,dpay-finder}.md
# — the repo copy is the source of truth; the user-level dir holds the deployed copy.
#
# Owner: brew-ops.

set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.claude/agents" && pwd)
DEST_DIR="$HOME/.claude/agents"
AGENTS=(code-finder dpay-finder)

mkdir -p "$DEST_DIR"
for a in "${AGENTS[@]}"; do
  src="$SRC_DIR/$a.md"
  [ -f "$src" ] || { echo "✗ source agent not found: $src" >&2; exit 1; }
  cp "$src" "$DEST_DIR/$a.md"
  echo "✓ deployed: $DEST_DIR/$a.md (model: $(awk -F': ' '/^model:/{print $2; exit}' "$src"))"
done
echo "✓ fleet sub-agents installed at user level — available to every role in every repo"
