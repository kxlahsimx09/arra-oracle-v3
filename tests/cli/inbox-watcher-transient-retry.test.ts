// inbox-watcher.sh — transient API-error auto-retry (thread #210).
//
// A freshly-woken session can 529 ("API Error: 529 Overloaded", transient
// Anthropic-side) on its FIRST turn and exit before any work. The wake prompt
// IS in the JSONL, so T1 marks the envelope `verified`; pre-#210 it then sat
// ~30 min to T2 `failed_stuck` and recovery was a manual `maw wake --resume`.
// #210 detects the transient-error JSONL tail on a `verified` envelope whose
// claude has exited, then re-resumes the SAME session/worktree with backoff,
// capped, before escalating.
//
// Four branches (orchestrator thread #210, point 7), per P-004 replaying the
// REAL #203 (e779dccd) + #209 (0b30477f) JSONLs as the (a)/(b) fixtures:
//   (a) happy retry  — 529 tail → backoff → tail advances to real work →
//                      recovered → completed
//   (b) exhaust      — 529 persists across the cap → failed_transient_exhausted
//                      + re-dispatchable escalation envelope to for-orchestrator/
//   (c) discriminator— non-transient 4xx tail → failed_api_nontransient,
//                      escalate, NO retry
//   (d) logic stall  — no isApiErrorMessage tail → unchanged failed_stuck, NO retry
//
// Hermetic: a stub `maw` records every wake; no real worktrees/claude touched.
// claude_alive_at sees no process at the temp worktree → always "dead", so the
// JSONL-tail classifier drives every transition deterministically. Backoff is
// zeroed via env so retries fire on consecutive scans without real waits.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync, rmSync, writeFileSync, appendFileSync, mkdirSync,
  readdirSync, readFileSync, renameSync, copyFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");
const FIXTURES = join(import.meta.dir, "fixtures", "transient-retry");
const ORACLE = "next-impl";

let root: string;
let inboxBase: string;
let stateDir: string;
let claudeProjects: string;
let mawLog: string;
let mawStub: string;
let wt: string; // the (fake) worktree maw "creates" and the stub echoes back

// claude encodes a cwd into a project-dir name by replacing / and . with -.
const encodeCwd = (p: string) => p.replace(/[/.]/g, "-");

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "iw-transient-"));
  inboxBase = join(root, "inbox");
  stateDir = join(root, "state");
  claudeProjects = join(root, "claude-projects");
  mawLog = join(root, "maw-calls.log");
  wt = join(root, "wts", `mb-next.wt-1-inbox-test`);

  mkdirSync(join(inboxBase, `for-${ORACLE}`), { recursive: true });
  mkdirSync(join(inboxBase, "for-orchestrator"), { recursive: true });
  mkdirSync(stateDir, { recursive: true });
  mkdirSync(wt, { recursive: true });
  mkdirSync(join(claudeProjects, encodeCwd(wt)), { recursive: true });

  // Stub maw: log args, echo the worktree line fire_wake parses, exit 0.
  mawStub = join(root, "maw-stub.sh");
  writeFileSync(
    mawStub,
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${mawLog}"\n` +
      `echo "+ worktree: ${wt} (branch)"\nexit 0\n`,
    { mode: 0o755 },
  );
  writeFileSync(mawLog, "");
});

afterEach(() => rmSync(root, { recursive: true, force: true }));

/** Write an envelope into for-next-impl/ (no parent_thread → wake_key = thread). */
function envelope(name: string, thread: number) {
  writeFileSync(
    join(inboxBase, `for-${ORACLE}`, name),
    [
      "---", "from: orchestrator", `to: ${ORACLE}`, "type: consult",
      `thread: ${thread}`, "needs_response: true",
      "created: 2026-05-22T11:06:00+07:00", "---", "", "body",
    ].join("\n"),
  );
}

/** Place a JSONL transcript at the worktree's encoded project dir under `sid`. */
function putJsonl(sid: string, contents: string) {
  writeFileSync(join(claudeProjects, encodeCwd(wt), `${sid}.jsonl`), contents);
}
function appendJsonl(sid: string, line: string) {
  appendFileSync(join(claudeProjects, encodeCwd(wt), `${sid}.jsonl`), line.endsWith("\n") ? line : line + "\n");
}

function archive(name: string) {
  const handled = join(inboxBase, `for-${ORACLE}`, "handled", "2026-05");
  mkdirSync(handled, { recursive: true });
  renameSync(join(inboxBase, `for-${ORACLE}`, name), join(handled, name));
}

function scanOnce(extraEnv: Record<string, string> = {}) {
  return spawnSync("bash", [SCRIPT, "scan-once"], {
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      STATE_DIR: stateDir,
      CLAUDE_PROJECTS: claudeProjects,
      MAW_BIN: `bash ${mawStub}`,
      INBOX_POLL_INTERVAL: "1",
      // zero the backoff so retries fire on consecutive scans (no real waits)
      INBOX_RETRY_BACKOFF: "0 0 0 0",
      INBOX_RETRY_VERIFY_WINDOW: "0",
      INBOX_RETRY_MAX: "4",
      // generous T2 so the retry dance is never pre-empted by failed_stuck…
      T2_PROCESSING_DEADLINE: "100000",
      ...extraEnv, // …(d) overrides T2 to force the logic-stall path
    },
    encoding: "utf8",
  });
}

function statusOf(name: string): string {
  const f = join(stateDir, "state", ORACLE, `${name}.state`);
  let txt = "";
  try { txt = readFileSync(f, "utf8"); } catch { return "(no-state)"; }
  const m = txt.match(/^status=(.*)$/gm);
  return m ? m[m.length - 1].slice("status=".length) : "(no-status)";
}
function stateField(name: string, key: string): string {
  const f = join(stateDir, "state", ORACLE, `${name}.state`);
  const txt = readFileSync(f, "utf8");
  const m = txt.match(new RegExp(`^${key}=(.*)$`, "gm"));
  return m ? m[m.length - 1].slice(`${key}=`.length) : "";
}
function resumeCount(): number {
  return readFileSync(mawLog, "utf8").split("\n").filter((l) => l.includes("--resume")).length;
}
function escalationEnvelopes(): string[] {
  const dir = join(inboxBase, "for-orchestrator");
  try { return readdirSync(dir).filter((f) => f.endsWith("_escalate.md")); } catch { return []; }
}

// Drive an envelope NEW → fired → verified, returning when status=verified.
function driveToVerified(name: string, thread: number) {
  scanOnce();                              // NEW → fire (--fresh)
  expect(statusOf(name)).toBe("fired");
  scanOnce();                              // fired → verified (T1: prompt in JSONL)
  expect(statusOf(name)).toBe("verified");
}

const REAL_203 = readFileSync(join(FIXTURES, "real-203-e779dccd.jsonl"), "utf8");
const REAL_209_RECOVERY = readFileSync(join(FIXTURES, "real-209-recovery-turn.jsonl"), "utf8").trim();
const SID_203 = "e779dccd-8850-4837-8eaa-7ef0157cd798";
const ENV_203 = "2026-05-22_11-06_from-orchestrator_thread-203_consult.md";

test("(a) happy retry: real 529 stall → re-resume → tail advances → recovered → completed", () => {
  envelope(ENV_203, 203);
  putJsonl(SID_203, REAL_203); // real #203 transcript: 529 tail, no work after
  driveToVerified(ENV_203, 203);

  scanOnce(); // verify_processing → detects transient tail → transient_retry
  expect(statusOf(ENV_203)).toBe("transient_retry");
  expect(stateField(ENV_203, "last_error")).toBe("529");

  scanOnce(); // reconsider → backoff(0) elapsed → fire re-resume #1
  expect(statusOf(ENV_203)).toBe("transient_retry");
  expect(resumeCount()).toBeGreaterThanOrEqual(1);

  // The resumed session recovers: append a REAL #209 work turn after the error.
  appendJsonl(SID_203, REAL_209_RECOVERY);

  scanOnce(); // reconsider → tail now "progress" → recovered → verified
  expect(statusOf(ENV_203)).toBe("verified");

  archive(ENV_203);
  scanOnce(); // Pass 2 → file gone → completed
  expect(statusOf(ENV_203)).toBe("completed");
}, 30000); // generous: each scan runs claude_alive_at (pgrep+lsof), slow on a busy box

test("(b) exhaust: real 529 persists across the cap → failed_transient_exhausted + re-dispatchable escalation", () => {
  envelope(ENV_203, 203);
  putJsonl(SID_203, REAL_203); // never recovers
  driveToVerified(ENV_203, 203);

  // Drive the full retry cycle: enter + 4 re-resumes + exhaust. Backoff/verify
  // windows are 0, so each scan advances one step; loop generously.
  for (let i = 0; i < 10; i++) {
    scanOnce();
    if (statusOf(ENV_203) === "failed_transient_exhausted") break;
  }
  expect(statusOf(ENV_203)).toBe("failed_transient_exhausted");
  expect(resumeCount()).toBe(4); // exactly INBOX_RETRY_MAX attempts
  expect(stateField(ENV_203, "retry_count")).toBe("4");

  const esc = escalationEnvelopes();
  expect(esc.length).toBe(1);
  const body = readFileSync(join(inboxBase, "for-orchestrator", esc[0]), "utf8");
  // Re-dispatchable (point 5): carries sid, wt_path, last_error, retry_count, fname.
  expect(body).toContain("to: orchestrator");
  expect(body).toContain("type: escalate");
  expect(body).toContain(SID_203);
  expect(body).toContain(wt);
  expect(body).toContain("last_error: `529`");
  expect(body).toContain("retry_count: `4`");
  expect(body).toContain(ENV_203);
}, 45000); // generous: up to ~10 scans, each running claude_alive_at (pgrep+lsof)

test("(c) discriminator: non-transient 4xx tail → failed_api_nontransient, escalate, no retry", () => {
  const name = "2026-05-22_12-00_from-orchestrator_thread-301_consult.md";
  const sid = "c0000000-0000-4000-8000-000000000400";
  envelope(name, 301);
  putJsonl(sid, [
    JSON.stringify({ type: "user", message: { role: "user", content: `inbox: ${name}` } }),
    JSON.stringify({
      type: "assistant", isApiErrorMessage: true, apiErrorStatus: 400,
      message: { role: "assistant", content: [{ type: "text", text: "API Error: 400 invalid_request" }] },
    }),
    JSON.stringify({ type: "last-prompt", lastPrompt: `inbox: ${name}` }),
  ].join("\n") + "\n");

  driveToVerified(name, 301);
  scanOnce(); // verify_processing → non-transient → escalate immediately
  expect(statusOf(name)).toBe("failed_api_nontransient");
  expect(stateField(name, "last_error")).toBe("400");
  expect(resumeCount()).toBe(0); // a 4xx is never retried
  expect(escalationEnvelopes().length).toBe(1);
});

test("(d) genuine logic stall: no isApiErrorMessage tail → unchanged failed_stuck, no retry", () => {
  const name = "2026-05-22_12-05_from-orchestrator_thread-302_consult.md";
  const sid = "d0000000-0000-4000-8000-000000000000";
  envelope(name, 302);
  // A normal assistant turn (real work, no API error) that just never archived.
  putJsonl(sid, [
    JSON.stringify({ type: "user", message: { role: "user", content: `inbox: ${name}` } }),
    JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "Reading the envelope…" }] } }),
  ].join("\n") + "\n");

  // T2=0 so the stuck gate trips immediately once maybe_enter declines (no error tail).
  driveToVerified(name, 302);
  scanOnce({ T2_PROCESSING_DEADLINE: "0" });
  expect(statusOf(name)).toBe("failed_stuck");
  expect(resumeCount()).toBe(0); // not an API stall → never auto-retried
  expect(escalationEnvelopes().length).toBe(0);
});
