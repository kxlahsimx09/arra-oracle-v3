#!/usr/bin/env bash
# Register bot commands with Telegram so the `/` menu shows autocomplete.
# Re-run after adding/renaming commands. Idempotent.

set -u
ENV_FILE=${ENV_FILE:-$HOME/.cache/brew-ops-bot/.env}
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a
TOKEN=${BREW_OPS_BOT_TOKEN:?missing in $ENV_FILE}

curl -sf "https://api.telegram.org/bot${TOKEN}/setMyCommands" \
  -H 'Content-Type: application/json' \
  -d '{
    "commands": [
      {"command":"help",     "description":"แสดงคำสั่งทั้งหมด"},
      {"command":"blockers", "description":"🔴 active [BLOCK_*] markers ใน main"},
      {"command":"pending",  "description":"🟡 [AWAITING_*]/[RATIFICATION_*] + thread count"},
      {"command":"threads",  "description":"💬 open arra_threads"},
      {"command":"roles",    "description":"🎭 list roles + chat counts"},
      {"command":"chats",    "description":"💬 list chats (all or by role)"},
      {"command":"chat",     "description":"เข้า chat (auto-pick ถ้า role มี 1 chat)"},
      {"command":"new",      "description":"➕ spawn new chat: /new <role> [slug]"},
      {"command":"close",    "description":"✖️ close chat: /close <role/slug>"},
      {"command":"look",     "description":"👁️ tmux scrollback (default 25, /look full)"},
      {"command":"key",      "description":"⌨️ TUI nav keys: /key [chat] up down enter esc"},
      {"command":"end",      "description":"clear active chat (ไม่ kill)"},
      {"command":"watch",    "description":"🔔 watcher: /watch list|on|off|all [chat]"},
      {"command":"history",  "description":"📜 claude JSONL turns: /history [target] [N]"},
      {"command":"retro",    "description":"📓 workflow retros: /retro [role] [N]"},
      {"command":"closed",   "description":"🪦 recently-ended chats (JSONL on disk)"},
      {"command":"list",     "description":"🪟 raw tmux panes (incl watcher)"}
    ]
  }' | jq -r 'if .ok then "✓ commands registered" else "✗ \(.description // .)" end'
