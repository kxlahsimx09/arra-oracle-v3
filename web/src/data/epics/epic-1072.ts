import type { Epic } from "./types";

// Epic 1072 — API gateway router on :47778.
// Verified against `main` HEAD. The gateway plugin is always mounted on the
// main server. Its status endpoint returns `{ enabled: false }` when no
// oracle-gateway.json exists and no VECTOR_URL is set (pure pass-through).
// With VECTOR_URL set, a config is synthesized in memory (no file needed).

export const epic1072: Epic = {
  id: 1072,
  slug: "1072-api-gateway",
  title: "API gateway router on :47778",
  summary:
    "A built-in gateway exposes status/health endpoints, proxies vector traffic with an FTS5 fallback when the vector service is down, hot-reloads its config file, and ships named request/response/error hooks.",
  status: "pending",
  verifiedBy: "",
  verifiedDate: "",
  prerequisites: [
    "Open a terminal at the repo root (the folder with package.json and src/).",
    "Install deps once if needed: `bun install`.",
    "Start the dev server with `bun run server` — it listens on http://localhost:47778. Stop it with Ctrl-C.",
    "Use a SECOND terminal for the curl commands so the server keeps running.",
    "Gateway routes/hooks are counts in the status JSON, not arrays. With no config and no VECTOR_URL the gateway is a no-op pass-through — that is expected.",
  ],
  features: [
    {
      id: "status",
      name: "`GET /api/gateway/status` returns gateway state",
      steps: [
        "Start the server with `bun run server` (no extra env).",
        "In the second terminal: `curl -s http://localhost:47778/api/gateway/status`.",
      ],
      expected:
        'With no config file and no VECTOR_URL the response is exactly `{ "enabled": false }`. When a config or VECTOR_URL is active the response is `{ "enabled": true, "routes": <number>, "services": { ... }, "hooks": <number> }` (routes and hooks are counts).',
    },
    {
      id: "health",
      name: "`GET /api/gateway/health` reports service health",
      steps: [
        "With the server running, in the second terminal: `curl -s http://localhost:47778/api/gateway/health`.",
      ],
      expected:
        'Returns `{ "services": { ... } }`. With no gateway config the services object is empty: `{ "services": {} }`. With a vector service configured each entry looks like `{ "status": "up"|"down"|"unknown", "lastCheck": <ms> }`.',
    },
    {
      id: "vector-fallback",
      name: "VECTOR_URL proxy with fts5 fallback when vector is down",
      notes:
        "Setting VECTOR_URL synthesizes a gateway config with a `vector` service and 6 routes. The /api/search route has `fallback: 'fts5'`, so if the vector backend is unreachable the request falls through to the local FTS5 search handler instead of erroring.",
      steps: [
        "Pick a vector URL that is NOT running, e.g. http://localhost:47781. Start the server pointed at it: `VECTOR_URL=http://localhost:47781 bun run server`.",
        "In the second terminal confirm the gateway is enabled: `curl -s http://localhost:47778/api/gateway/status` → expect `\"enabled\": true` with `\"routes\": 6`.",
        "Now run a search that would normally hit vector: `curl -s \"http://localhost:47778/api/search?q=test&mode=hybrid\"`.",
      ],
      expected:
        "gateway/status shows enabled:true, routes:6, and a `vector` service. The search request does NOT fail with a 502/504 — it falls through to the local FTS5 search and returns a normal `{ results, total, ... }` JSON body because of the `fts5` fallback.",
    },
    {
      id: "hot-reload",
      name: "Hot-reload of oracle-gateway.json via fs.watch",
      notes:
        "The gateway watches `oracle-gateway.json` in the data dir with fs.watch (200ms debounce) and also watches the directory so a first-time create is picked up live — no restart needed. Disable with ORACLE_GATEWAY_HOT_RELOAD=0.",
      steps: [
        "Start the server with `bun run server` (no VECTOR_URL). Confirm `curl -s http://localhost:47778/api/gateway/status` → `{ \"enabled\": false }`.",
        "Find the data dir the server uses (printed at boot, or the value of ORACLE_DATA_DIR / the default data dir). Create a minimal `oracle-gateway.json` there with one service and route, for example: `{ \"services\": { \"demo\": { \"url\": \"http://localhost:9\" } }, \"routes\": [ { \"path\": \"/api/demo\", \"service\": \"demo\" } ] }`.",
        "WITHOUT restarting, re-run: `curl -s http://localhost:47778/api/gateway/status`.",
      ],
      expected:
        "Within a fraction of a second of saving the file, gateway/status flips to `\"enabled\": true` and reports the new route count — proving the config was hot-reloaded without a server restart.",
    },
    {
      id: "hooks",
      name: "Built-in hooks are registered",
      notes:
        "Five built-in hooks ship: auth-guard, request-logger, rate-limit, fts5-fallback, error-json (plus an extra request-logger-response onResponse hook). Hooks are registered at startup but only RUN when named in the config's `hooks` arrays.",
      steps: [
        "Confirm the hook source files exist (each calls registerHook with its name): `ls src/gateway/hooks/`.",
        "Verify the five names are present: `grep -rh \"name:\" src/gateway/hooks/ | sort`.",
      ],
      expected:
        "src/gateway/hooks/ contains auth-guard.ts, request-logger.ts, rate-limit.ts, fts5-fallback.ts, and error-json.ts, and the grep lists the hook names auth-guard, request-logger, rate-limit, fts5-fallback, error-json (plus request-logger-response).",
    },
  ],
};
