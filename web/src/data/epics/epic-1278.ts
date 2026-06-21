import type { Epic } from "./types";

// Epic 1278 — Server plugin engine.
// Verified against `main` HEAD. CLI binary is `arra-cli`; from the repo root
// run it with `bun cli/src/cli.ts <args>`. Plugin enable/disable changes are
// read only at server boot, so a restart is required after each toggle.

export const epic1278: Epic = {
  id: 1278,
  slug: "1278-plugin-engine",
  title: "Server plugin engine",
  summary:
    "Bundled server plugins can be listed, enabled, and disabled from the CLI; toggling a plugin mounts or unmounts its routes after a restart, core plugins are protected, and the choice persists to config.",
  status: "pending",
  verifiedBy: "",
  verifiedDate: "",
  prerequisites: [
    "Open a terminal at the repo root (the folder containing package.json and src/).",
    "Install deps once if you have not already: `bun install`.",
    "You will start and stop the dev server several times below. Start it with `bun run server` (it listens on http://localhost:47778). Stop it with Ctrl-C.",
    "The CLI is the `arra-cli` binary. From the repo root, run it as `bun cli/src/cli.ts <args>`.",
  ],
  features: [
    {
      id: "list",
      name: "`plugin list` lists installed plugins",
      notes:
        "`plugin list` reports WASM/dir plugins installed under ~/.oracle/plugins. On a fresh machine this list is empty — that is the correct, expected output, not an error.",
      steps: [
        "In a terminal at the repo root, run:",
        "$ bun cli/src/cli.ts plugin list",
        "Read the output. It prints the plugin install directory and any installed plugins.",
      ],
      expected:
        "The command exits 0 and prints the plugin directory (~/.oracle/plugins) with an empty plugin list on a fresh checkout. No stack trace.",
    },
    {
      id: "route-flip",
      name: "Disable/enable the federation plugin flips the /info route",
      notes:
        "The federation plugin is disabled by default and mounts `GET /info`. Enable/disable is read at boot, so you must restart the server after each toggle.",
      steps: [
        "Start the server: `bun run server`. In a SECOND terminal run: `curl -s -o /dev/null -w \"%{http_code}\\n\" http://localhost:47778/info` — federation is off by default so expect 404. Stop the server (Ctrl-C).",
        "Enable federation: `bun cli/src/cli.ts plugin enable federation`.",
        "Restart the server: `bun run server`. In the second terminal run the same curl: `curl -s -o /dev/null -w \"%{http_code}\\n\" http://localhost:47778/info`. Now expect 200. Stop the server.",
        "Disable it again to restore defaults: `bun cli/src/cli.ts plugin disable federation`. Restart and curl `/info` once more — back to 404. Stop the server.",
      ],
      expected:
        "/info returns 404 while federation is disabled and 200 after `plugin enable federation` + restart. The flip is reversible.",
    },
    {
      id: "core-refused",
      name: "Disabling a core plugin is refused",
      notes:
        "Core plugins (health, search, knowledge, concepts, verify, vector, files, indexer) cannot be disabled.",
      steps: [
        "Run: `bun cli/src/cli.ts plugin disable search`.",
        "Read the printed error and check the exit code with: `echo $?`.",
      ],
      expected:
        'The command prints `Cannot disable core server plugin "search"` and exits with code 1. No config is changed.',
    },
    {
      id: "api-manifest",
      name: "API-manifest plugin mounts a route",
      notes:
        "The `plugin-api-example` plugin (disabled by default) declares an API manifest that mounts `GET /api/plugin-example`.",
      steps: [
        "Enable it: `bun cli/src/cli.ts plugin enable plugin-api-example`.",
        "Start the server: `bun run server`.",
        "In a second terminal: `curl -s http://localhost:47778/api/plugin-example`.",
        "Stop the server and restore defaults: `bun cli/src/cli.ts plugin disable plugin-api-example`.",
      ],
      expected:
        'The route returns JSON `{ "ok": true, "plugin": "plugin-api-example", "mountedBy": "server-plugin-api-manifest" }`. Before enabling, the same route returns 404.',
    },
    {
      id: "unified-lifecycle",
      name: "Unified one-handler plugin emits start/stop lifecycle",
      notes:
        "The `unified-example` plugin (disabled by default) mounts `GET`/`POST /api/unified-example` and logs lifecycle lines on plugin start and stop.",
      steps: [
        "Enable it: `bun cli/src/cli.ts plugin enable unified-example`.",
        "Start the server: `bun run server`. Watch the server's stdout — on startup it prints `[unified-example] start`.",
        "In a second terminal: `curl -s -X POST http://localhost:47778/api/unified-example -H 'content-type: application/json' -d '{\"hi\":1}'`.",
        "Stop the server with Ctrl-C and watch stdout — it prints `[unified-example] stop`.",
        "Restore defaults: `bun cli/src/cli.ts plugin disable unified-example`.",
      ],
      expected:
        'Server stdout shows `[unified-example] start` on boot and `[unified-example] stop` on shutdown. The POST returns JSON `{ "ok": true, "plugin": "unified-example", "source": "api", "method": "POST", "body": { "hi": 1 } }`.',
    },
    {
      id: "config-persist",
      name: "Plugin toggles persist to config",
      notes:
        "`plugin disable`/`enable` write `disabledPlugins` / `enabledPlugins` arrays to the GLOBAL config file (~/.config/arra/config.json), which the server reads at boot. A project-scoped .arra/config.json is also read but is not the CLI write target.",
      steps: [
        "Disable a non-core plugin: `bun cli/src/cli.ts plugin disable federation`.",
        "Inspect the global config: `cat ~/.config/arra/config.json`.",
        "Re-enable to restore: `bun cli/src/cli.ts plugin enable federation`.",
      ],
      expected:
        'After disabling, ~/.config/arra/config.json contains `"disabledPlugins": ["federation"]` (and the reverse `"enabledPlugins"` entry after enabling). The file persists across restarts.',
    },
  ],
};
