// inbox-watcher.sh — engine/model runtime dispatch metadata.
//
// Guards Codex parity for directed-inbox dispatch: envelopes can request a
// runtime, maw wake receives it, and verified sessions cache that runtime so
// later same-campaign resumes do not silently switch engine/model.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");

let root: string;
let inboxBase: string;
let stateDir: string;
let codexSessions: string;
let mawLog: string;
let wtPath: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "iw-runtime-"));
  inboxBase = join(root, "inbox");
  stateDir = join(root, "state");
  codexSessions = join(root, "codex-sessions");
  mawLog = join(root, "maw-calls.log");
  wtPath = join(root, "fake.wt-1-runtime");
  mkdirSync(join(inboxBase, "for-brew-ops"), { recursive: true });
  mkdirSync(codexSessions, { recursive: true });
  mkdirSync(wtPath, { recursive: true });
  writeFileSync(mawLog, "");

  const stub = join(root, "maw-stub.sh");
  writeFileSync(
    stub,
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${mawLog}"\n` +
      `echo "+ worktree: ${wtPath} (branch)"\nexit 0\n`,
    { mode: 0o755 },
  );
  process.env.__IW_MAW = `bash ${stub}`;
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function writeEnvelope(name: string, extraFields: string[] = []) {
  const lines = [
    "---",
    "from: orchestrator",
    "to: brew-ops",
    "type: dispatch",
    "thread: 501",
    "parent_thread: 500",
    ...extraFields,
    "created: 2026-05-25T10:00:00+07:00",
    "---",
    "",
    "body",
  ];
  writeFileSync(join(inboxBase, "for-brew-ops", name), lines.join("\n"));
}

function scanOnce() {
  return spawnSync("bash", [SCRIPT, "scan-once"], {
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      STATE_DIR: stateDir,
      CODEX_SESSIONS: codexSessions,
      MAW_BIN: process.env.__IW_MAW,
      INBOX_POLL_INTERVAL: "1",
    },
    encoding: "utf8",
  });
}

function mawCalls(): string {
  return readFileSync(mawLog, "utf8");
}

function stateText(): string {
  const dir = join(stateDir, "state", "brew-ops");
  const file = readdirSync(dir).find((f) => f.endsWith(".state"))!;
  return readFileSync(join(dir, file), "utf8");
}

test("fresh dispatch forwards envelope engine/model/reasoning to maw wake", () => {
  writeEnvelope("2026-05-25_10-00_from-orchestrator_thread-501_dispatch.md", [
    "engine: codex",
    "model: gpt-5.5",
    "reasoning_effort: xhigh",
  ]);

  const r = scanOnce();
  expect(r.status).toBe(0);

  const calls = mawCalls();
  expect(calls).toContain("wake brew-ops --fresh --engine codex --model gpt-5.5 --reasoning-effort xhigh");
});

test("same-campaign resume reuses cached runtime instead of new envelope override", () => {
  const wt = join(root, "fake.wt-7-prev");
  mkdirSync(wt, { recursive: true });
  const sessDir = join(stateDir, "sessions", "brew-ops");
  mkdirSync(sessDir, { recursive: true });
  writeFileSync(join(sessDir, "thread-500.session-id"), "SID-CODEX\n");
  writeFileSync(join(sessDir, "thread-500.session-engine"), "codex\n");
  writeFileSync(join(sessDir, "thread-500.session-model"), "gpt-5.5\n");
  writeFileSync(join(sessDir, "thread-500.session-reasoning-effort"), "xhigh\n");
  const stDir = join(stateDir, "state", "brew-ops");
  mkdirSync(stDir, { recursive: true });
  writeFileSync(
    join(stDir, "prev.state"),
    ["fired_at=1", "oracle=brew-ops", "fname=prev.md", "thread_id=499",
      "wake_key=500", `wt_path=${wt}`, "status=completed"].join("\n") + "\n",
  );
  writeEnvelope("2026-05-25_10-01_from-orchestrator_thread-501_dispatch.md", [
    "engine: claude",
    "model: sonnet",
  ]);

  const r = scanOnce();
  expect(r.status).toBe(0);

  const calls = mawCalls();
  expect(calls).toContain("--resume SID-CODEX");
  expect(calls).toContain("--engine codex --model gpt-5.5 --reasoning-effort xhigh");
  expect(calls).not.toContain("--engine claude");
  expect(calls).not.toContain("--model sonnet");
});

test("codex delivery verification caches runtime metadata for later resumes", () => {
  const fname = "2026-05-25_10-02_from-orchestrator_thread-501_dispatch.md";
  writeEnvelope(fname, [
    "engine: codex",
    "model: gpt-5.5",
    "reasoning_effort: high",
  ]);

  expect(scanOnce().status).toBe(0);

  const rollout = join(codexSessions, "2026", "05", "25", "rollout-codex.jsonl");
  mkdirSync(dirname(rollout), { recursive: true });
  writeFileSync(
    rollout,
    [
      JSON.stringify({ type: "session_meta", payload: { id: "CODEX-SID-1", cwd: wtPath } }),
      JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: `Bootstrap and process inbox: ${fname}` } }),
    ].join("\n") + "\n",
  );

  expect(scanOnce().status).toBe(0);

  expect(stateText()).toContain("status=verified");
  expect(stateText()).toContain("session_engine=codex");
  const sessDir = join(stateDir, "sessions", "brew-ops");
  expect(readFileSync(join(sessDir, "thread-500.session-id"), "utf8").trim()).toBe("CODEX-SID-1");
  expect(readFileSync(join(sessDir, "thread-500.session-engine"), "utf8").trim()).toBe("codex");
  expect(readFileSync(join(sessDir, "thread-500.session-model"), "utf8").trim()).toBe("gpt-5.5");
  expect(readFileSync(join(sessDir, "thread-500.session-reasoning-effort"), "utf8").trim()).toBe("high");
});
