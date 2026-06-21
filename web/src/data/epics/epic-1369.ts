import type { Epic } from "./types";

// Epic 1369 — Zero-config onboarding.
// Verified against `main` HEAD. With VECTOR_URL empty (the default), search
// falls to a local FTS5 floor and no vector store directory is created. The
// web docs-site provides /search, /connect, and /install onboarding pages.
// The tool-toggle and vector-config endpoints persist opt-in choices to config.

export const epic1369: Epic = {
  id: 1369,
  slug: "1369-zero-config-onboarding",
  title: "Zero-config onboarding",
  summary:
    "A fresh install works with no vector backend: keyword (FTS5) search runs locally with no lancedb/ dir, the web site guides Connect/Install, per-tool MCP toggles persist, and vector is strictly opt-in.",
  status: "pending",
  verifiedBy: "",
  verifiedDate: "",
  prerequisites: [
    "Open a terminal at the repo root (the folder with package.json and src/). Install deps once if needed: `bun install`.",
    "Start the backend with `bun run server` — it listens on http://localhost:47778. Use a SECOND terminal for curl. Stop the server with Ctrl-C.",
    "For the web-page checks, run the docs-site separately: `cd web && bun run dev`, then open the printed local URL (Astro dev server) in a browser.",
    "Keep VECTOR_URL unset/empty for the zero-config checks — that is the default and the whole point of this epic.",
  ],
  features: [
    {
      id: "fts-floor",
      name: "FTS keyword search works with no vector backend and no lancedb/ dir",
      notes:
        "With VECTOR_URL empty, `mode=fts` runs the local FTS5 search path only — it never opens or creates a vector store, so no lancedb/ directory appears.",
      steps: [
        "Make sure VECTOR_URL is empty (do not set it). Start the server: `bun run server`.",
        "From the repo root, list directories so you have a before-picture: `ls`. Note there is no `lancedb` folder.",
        "In the second terminal: `curl -s \"http://localhost:47778/api/search?mode=fts&q=oracle\"`.",
        "Back at the repo root, run `ls` again and confirm no `lancedb` folder was created.",
      ],
      expected:
        'The search returns JSON `{ results, total, limit, offset, query, ... }` (results may be empty if nothing is indexed, which is fine). No `lancedb/` directory is created by the FTS request.',
    },
    {
      id: "web-pages",
      name: "Onboarding pages /search, /connect, /install render",
      notes:
        "These are static Astro pages served by the docs-site (cd web && bun run dev), not the backend.",
      steps: [
        "With the docs-site running, open `/search` — a keyword search box. Type a query and submit; it calls the backend `GET /api/search?...&mode=fts` and lists results.",
        "Open `/connect` — it stores your backend URL and an optional token, generating a `claude mcp add ...` command you can copy.",
        "Open `/install` — a 3-step copy-friendly setup guide (backend, UI, CLI one-liners).",
      ],
      expected:
        "All three pages load. /connect produces a command of the form `claude mcp add arra-oracle-v3 --env ORACLE_API='<api>' -- bunx --bun arra-oracle-v3@github:Soul-Brews-Studio/arra-oracle-v3` (with an extra `--env ARRA_API_TOKEN=...` if you set a token). /install shows three copyable steps.",
    },
    {
      id: "tool-toggle",
      name: "Per-tool MCP toggle persists allowed_tools",
      notes:
        "The page is /tools/config. Saving calls `PUT /api/settings/tools` with body `{ enabled_tools: string[] }`, which writes `allowed_tools` into the project .arra/config.json. The endpoint is session-gated, so use the web page (which carries the session cookie) rather than a raw curl.",
      steps: [
        "With both the backend (`bun run server`) and docs-site (`cd web && bun run dev`) running, open `/tools/config` in the browser.",
        "Untick a tool (or two), then click Save. The page should confirm success.",
        "At the repo root, inspect the written config: `cat .arra/config.json`.",
      ],
      expected:
        "The save succeeds and `.arra/config.json` now contains an `allowed_tools` array reflecting your selection (the tools you left enabled). Re-opening /tools/config shows the same selection.",
    },
    {
      id: "vector-opt-in",
      name: "Vector is opt-in via PATCH /api/vector/config",
      notes:
        "Vector stays off until you opt in. PATCH `/api/vector/config` with `{ enabled: true }` turns it on and the response carries a recommended next action (nested under `state.recommendedAction`).",
      steps: [
        "With the backend running, in the second terminal: `curl -s -X PATCH http://localhost:47778/api/vector/config -H 'content-type: application/json' -d '{\"enabled\":true}'`.",
        "Read the JSON response, specifically the `state.recommendedAction` field.",
        "Optional: turn it back off with `curl -s -X PATCH http://localhost:47778/api/vector/config -H 'content-type: application/json' -d '{\"enabled\":false}'`.",
      ],
      expected:
        'The response JSON has `state.enabled: true` and `state.recommendedAction: "POST /api/vector/index/start"` (when no index is built yet). A `vector-server.json` config file is written only after this opt-in — not before.',
    },
  ],
};
