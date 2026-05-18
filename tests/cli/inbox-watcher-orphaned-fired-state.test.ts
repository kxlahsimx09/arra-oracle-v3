// inbox-watcher.sh — orphaned `fired` state reconciliation (thread #170).
//
// Guards the 2026-05-18 campaign dead-lock: next-writer's #167 dispatch sat
// DEFERRED ~2h. Root cause — an earlier same-campaign envelope was fired,
// then resumed/processed/archived by the agent INSIDE one poll interval, so
// Pass 1's verify_delivery (T1) never saw the file and the state froze at
// `fired`. campaign_inflight()/parent_session_busy() count a `fired` sibling
// as in-flight, so every later envelope of that campaign deferred forever.
//
// The fix: Pass 2 (the archived-envelope reconciliation sweep) gained a
// `fired)` case, mirroring `verified`/`delivered_to_owner` — a `fired`
// envelope whose backing file is gone is finalized to `completed`.
//
// Hermetic: a stub `maw` records every `wake` call; no real worktrees or
// claude processes are touched.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readdirSync, readFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");

let root: string;
let inboxBase: string;
let stateDir: string;
let mawLog: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "iw-orphan-"));
  inboxBase = join(root, "inbox");
  stateDir = join(root, "state");
  mawLog = join(root, "maw-calls.log");
  mkdirSync(join(inboxBase, "for-next-writer"), { recursive: true });
  mkdirSync(stateDir, { recursive: true });

  const stub = join(root, "maw-stub.sh");
  writeFileSync(
    stub,
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${mawLog}"\n` +
      `echo "+ worktree: ${root}/fake.wt-1-stub (branch)"\nexit 0\n`,
    { mode: 0o755 },
  );
  writeFileSync(mawLog, "");
  process.env.__IW_MAW = `bash ${stub}`;
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

/** Write an envelope into for-next-writer/. */
function envelope(name: string, thread: number, parentThread: number) {
  const lines = [
    "---",
    "from: orchestrator",
    "to: next-writer",
    "type: consult",
    `thread: ${thread}`,
    `parent_thread: ${parentThread}`,
    "created: 2026-05-18T19:00:00+07:00",
    "---",
    "",
    "body",
  ];
  writeFileSync(join(inboxBase, "for-next-writer", name), lines.join("\n"));
}

/** Move an envelope out of the inbox root — i.e. §11d archive. */
function archive(name: string) {
  const handled = join(inboxBase, "for-next-writer", "handled", "2026-05");
  mkdirSync(handled, { recursive: true });
  renameSync(join(inboxBase, "for-next-writer", name), join(handled, name));
}

function scanOnce() {
  return spawnSync("bash", [SCRIPT, "scan-once"], {
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      STATE_DIR: stateDir,
      MAW_BIN: process.env.__IW_MAW,
      INBOX_POLL_INTERVAL: "1",
    },
    encoding: "utf8",
  });
}

function fireCount(): number {
  return readFileSync(mawLog, "utf8").split("\n").filter((l) => l.includes("wake ")).length;
}

/** Map of envelope filename → status, read from the state files. */
function states(): Record<string, string> {
  const dir = join(stateDir, "state", "next-writer");
  const out: Record<string, string> = {};
  let files: string[] = [];
  try {
    files = readdirSync(dir);
  } catch {
    return out;
  }
  for (const f of files) {
    if (!f.endsWith(".state")) continue;
    const m = readFileSync(join(dir, f), "utf8").match(/^status=(.*)$/gm);
    // last status= line wins (set_state_field appends in some paths)
    out[f.replace(/\.state$/, "")] = m ? m[m.length - 1].slice("status=".length) : "?";
  }
  return out;
}

test("a `fired` envelope archived before T1 verification is reconciled to `completed`", () => {
  const e1 = "2026-05-18_17-55_from-orchestrator_thread-167_consult.md";
  envelope(e1, 167, 167);

  scanOnce(); // e1 fires
  expect(states()[e1]).toBe("fired");

  // Agent resumed, processed, archived it inside one poll interval — Pass 1's
  // verify_delivery never saw the file.
  archive(e1);

  const r = scanOnce(); // Pass 2 must reconcile the orphaned `fired` state
  expect(r.status).toBe(0);
  expect(states()[e1]).toBe("completed");
});

test("an orphaned `fired` sibling no longer dead-locks later campaign envelopes (thread #170)", () => {
  const e1 = "2026-05-18_17-55_from-orchestrator_thread-167_consult.md";
  const e2 = "2026-05-18_19-21_from-orchestrator_thread-167_consult.md";

  // e1 fires and reaches `fired`.
  envelope(e1, 167, 167);
  scanOnce();
  expect(fireCount()).toBe(1);

  // e1 archived before verify_delivery ran → Pass 2 reconciles it.
  archive(e1);
  scanOnce();
  expect(states()[e1]).toBe("completed");

  // e2 — same campaign (parent_thread 167). Pre-fix, the orphaned `fired` e1
  // made parent_session_busy()/campaign_inflight() see a perpetual in-flight
  // sibling and e2 deferred forever. Post-fix, e1 is terminal so e2 fires.
  envelope(e2, 167, 167);
  const r = scanOnce();
  expect(r.status).toBe(0);
  expect(fireCount()).toBe(2);
  expect(states()[e2]).toBe("fired");
});
