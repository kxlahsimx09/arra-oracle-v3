// inbox-loop-closure-hook.sh — §11d reply-gap detection regression tests.
//
// Guards thread #159 (a recurrence of the #140 class). next-architect finished
// a `--resume` dispatch, archived the consult envelope stamping handled_by_inbox
// with the inbound envelope's OWN basename (not a reply path) plus a verbose
// handled_note, but never wrote the reply envelope to for-orchestrator/. The old
// Check 2 skipped the envelope on mere frontmatter-field presence, so the Stop
// hook passed and the orchestrator was never woken.
//
// The hook now verifies the reply-envelope ARTIFACT exists on disk and treats a
// missing reply as legitimate only when the thread is closed (§11g moot). This
// closes the hole for fresh and `--resume` sessions alike — the watcher records
// session_id identically for both, so oracle identification was never the gap.
//
// Hermetic: a stub Oracle API serves thread statuses; temp inbox + watcher state.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "bun";

const HOOK = join(import.meta.dir, "..", "..", "scripts", "inbox-loop-closure-hook.sh");
const SID = "test-session-0001";

let root: string;
let inboxBase: string;
let watcherState: string;
let hookState: string;
let api: Server;
let threadStatus: Record<string, string>;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ilc-hook-"));
  inboxBase = join(root, "inbox");
  watcherState = join(root, "watcher");
  hookState = join(root, "hookstate");
  mkdirSync(join(inboxBase, "for-next-architect", "handled", "2026-05"), { recursive: true });
  mkdirSync(join(inboxBase, "for-orchestrator"), { recursive: true });

  // Watcher state file so the hook reverse-maps SID → oracle "next-architect"
  // (the same `session_id=` capture the watcher writes for a `--resume` wake).
  const stDir = join(watcherState, "state", "next-architect");
  mkdirSync(stDir, { recursive: true });
  writeFileSync(
    join(stDir, "dispatch.state"),
    ["oracle=next-architect", `session_id=${SID}`, "status=completed"].join("\n") + "\n",
  );

  // Stub Oracle API: GET /api/thread/<id> → {"thread":{"status":...}}.
  // Unknown id → 404, which `curl -sf` reports as failure (empty status).
  threadStatus = { "148": "active" };
  api = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      const id = new URL(req.url).pathname.split("/").pop() ?? "";
      const status = threadStatus[id];
      return status
        ? Response.json({ thread: { status } })
        : new Response("not found", { status: 404 });
    },
  });
});

afterEach(() => {
  api.stop(true);
  rmSync(root, { recursive: true, force: true });
});

const apiUrl = () => `http://127.0.0.1:${api.port}/api`;

/** Write an archived consult envelope into for-next-architect/handled/2026-05/. */
function archivedConsult(opts: { thread: number; handledByInbox?: string; handledNote?: string }) {
  const lines = [
    "---",
    "from: orchestrator",
    "to: next-architect",
    "type: consult",
    `thread: ${opts.thread}`,
    `parent_thread: ${opts.thread}`,
    "parent_oracle: orchestrator",
    "needs_response: true",
    "created: 2026-05-17T20:41:07+07:00",
    "handled_at: 2026-05-17T21:01:04+07:00",
    "handled_by_thread: " + opts.thread,
  ];
  if (opts.handledByInbox) lines.push(`handled_by_inbox: ${opts.handledByInbox}`);
  if (opts.handledNote) lines.push(`handled_note: ${opts.handledNote}`);
  lines.push("---", "", "Phase C is GO. Reply in the thread.");
  writeFileSync(
    join(
      inboxBase, "for-next-architect", "handled", "2026-05",
      `2026-05-17_20-41_from-orchestrator_thread-${opts.thread}_consult.md`,
    ),
    lines.join("\n"),
  );
}

/** Write a reply envelope from next-architect for <thread> into a target dir. */
function replyEnvelope(thread: number, subdir: string[] = []) {
  const dir = join(inboxBase, "for-orchestrator", ...subdir);
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, `2026-05-17_21-00_from-next-architect_thread-${thread}_reply.md`),
    ["---", "from: next-architect", "to: orchestrator", "type: reply",
      `thread: ${thread}`, "created: 2026-05-17T21:00:00+07:00", "---", "", "done"].join("\n"),
  );
}

/**
 * Run the Stop hook with the temp env wired in; returns {code, stderr}.
 * Async (Bun.spawn) on purpose — a synchronous spawn would block the test
 * process's event loop and starve the in-process stub Oracle API, so the
 * hook's `curl` would hang until its timeout.
 */
async function runHook(oracleApi: string) {
  const proc = Bun.spawn(["bash", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ session_id: SID })),
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      INBOX_WATCHER_STATE: watcherState,
      INBOX_LOOP_HOOK_STATE: hookState,
      ORACLE_API: oracleApi,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const stderr = await new Response(proc.stderr).text();
  const code = await proc.exited;
  return { code, stderr };
}

test("bogus handled_by_inbox + verbose handled_note, no reply envelope, thread active → BLOCKS", async () => {
  // The exact thread #159 shape: handled_by_inbox carries the inbound
  // envelope's OWN basename, handled_note is a verbose work summary, and no
  // reply envelope was ever written.
  archivedConsult({
    thread: 148,
    handledByInbox: "2026-05-17_20-41_from-orchestrator_thread-148_consult",
    handledNote: "Phase C drafted, PR #4 pushed, replied on thread #148 msg 456.",
  });
  const r = await runHook(apiUrl());
  expect(r.code).toBe(2);
  expect(r.stderr).toContain("INBOX LOOP NOT CLOSED");
  expect(r.stderr).toContain("thread-148_consult.md");
});

test("reply envelope present in for-orchestrator/ root → ALLOWS", async () => {
  archivedConsult({
    thread: 148,
    handledByInbox: "2026-05-17_21-00_from-next-architect_thread-148_reply.md",
  });
  replyEnvelope(148);
  expect((await runHook(apiUrl())).code).toBe(0);
});

test("reply envelope already archived under handled/ → ALLOWS", async () => {
  archivedConsult({ thread: 148 });
  replyEnvelope(148, ["handled", "2026-05"]);
  expect((await runHook(apiUrl())).code).toBe(0);
});

test("no reply envelope but thread is CLOSED → §11g moot, ALLOWS", async () => {
  threadStatus = { "149": "closed" };
  archivedConsult({ thread: 149, handledNote: "thread 149 already closed at msg 12" });
  expect((await runHook(apiUrl())).code).toBe(0);
});

test("no reply envelope, thread active, no close-out frontmatter at all → BLOCKS", async () => {
  archivedConsult({ thread: 148 });
  const r = await runHook(apiUrl());
  expect(r.code).toBe(2);
  expect(r.stderr).toContain("thread-148");
});

test("API unreachable + handled_note present → degraded moot escape, ALLOWS", async () => {
  // A transient API outage must not wedge a session on a legitimately-mooted
  // envelope: with no status obtainable, handled_note is honored as before.
  archivedConsult({ thread: 148, handledNote: "moot — thread closed out of band" });
  expect((await runHook("http://127.0.0.1:9/api")).code).toBe(0);
});

test("API unreachable + no handled_note → BLOCKS (cannot confirm moot)", async () => {
  archivedConsult({ thread: 148 });
  expect((await runHook("http://127.0.0.1:9/api")).code).toBe(2);
});

// --- thread #238: orchestrator gate is scoped by §151 OWNERSHIP, not whole-dir
//
// The orchestrator is the multi-campaign hub: ONE session spans many wake_keys,
// so §214's single-wake_key scoping cannot apply. Pre-#238 it stayed whole-dir,
// which false-blocked CONCURRENT orchestrator sessions (#181) on envelopes owned
// by a sibling session. The hook now scopes the orchestrator by the inbox-watcher
// §151 owner map: an envelope is this session's iff
// sessions/orchestrator/thread-<wake_key>.owner == this session's worktree.
// Unattributable scope (no owner record / no wake_key) falls back to gating.

const ORCH_SID = "test-orch-0002";
const MY_WT = "/wt/orch-mine";
const SIBLING_WT = "/wt/orch-sibling";

/** Reverse-map ORCH_SID → oracle "orchestrator" (the watcher's session_id capture). */
function orchState(sid: string) {
  const d = join(watcherState, "state", "orchestrator");
  mkdirSync(d, { recursive: true });
  writeFileSync(
    join(d, "dispatch.state"),
    ["oracle=orchestrator", `session_id=${sid}`, "status=verified"].join("\n") + "\n",
  );
}

/** Ensure sessions/orchestrator/ exists so scope_owner engages (even with no .owner). */
function orchSessionsDir() {
  mkdirSync(join(watcherState, "sessions", "orchestrator"), { recursive: true });
}

/** Record §151 campaign ownership: sessions/orchestrator/thread-<wakeKey>.owner = wt. */
function orchOwner(wakeKey: number, wt: string) {
  orchSessionsDir();
  writeFileSync(join(watcherState, "sessions", "orchestrator", `thread-${wakeKey}.owner`), wt + "\n");
}

/** Unhandled inbound reply envelope in for-orchestrator/ root (Check 1: archive-gap). */
function unhandledOrchReply(opts: { from: string; thread: number; parentThread: number }) {
  writeFileSync(
    join(inboxBase, "for-orchestrator", `2026-05-26_10-00_from-${opts.from}_thread-${opts.thread}_reply.md`),
    ["---", `from: ${opts.from}`, "to: orchestrator", "type: notify",
      `thread: ${opts.thread}`, `parent_thread: ${opts.parentThread}`, "parent_oracle: orchestrator",
      "needs_response: false", "created: 2026-05-26T10:00:00+07:00", "---", "", "sub-task done"].join("\n"),
  );
}

/** Archived needs_response envelope in for-orchestrator/handled/ (Check 2: reply-gap). */
function archivedOrchConsult(opts: { from: string; thread: number; parentThread: number }) {
  const dir = join(inboxBase, "for-orchestrator", "handled", "2026-05");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, `2026-05-26_09-00_from-${opts.from}_thread-${opts.thread}_consult.md`),
    ["---", `from: ${opts.from}`, "to: orchestrator", "type: consult",
      `thread: ${opts.thread}`, `parent_thread: ${opts.parentThread}`,
      "needs_response: true", "created: 2026-05-26T09:00:00+07:00",
      "handled_at: 2026-05-26T09:30:00+07:00", `handled_by_thread: ${opts.thread}`,
      "---", "", "needs a reply"].join("\n"),
  );
}

/** Run the hook as the orchestrator session, passing cwd (= this session's worktree). */
async function runOrchHook(cwd: string, oracleApi: string) {
  const proc = Bun.spawn(["bash", HOOK], {
    stdin: new TextEncoder().encode(JSON.stringify({ session_id: ORCH_SID, cwd })),
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      INBOX_WATCHER_STATE: watcherState,
      INBOX_LOOP_HOOK_STATE: hookState,
      ORACLE_API: oracleApi,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const stderr = await new Response(proc.stderr).text();
  const code = await proc.exited;
  return { code, stderr };
}

test("orchestrator: unhandled envelope for a campaign THIS session owns → BLOCKS", async () => {
  orchState(ORCH_SID);
  orchOwner(300, MY_WT);
  unhandledOrchReply({ from: "pg-writer", thread: 3001, parentThread: 300 });
  const r = await runOrchHook(MY_WT, apiUrl());
  expect(r.code).toBe(2);
  expect(r.stderr).toContain("INBOX LOOP NOT CLOSED");
  expect(r.stderr).toContain("thread-3001_reply.md");
});

test("orchestrator: unhandled envelope for a SIBLING session's campaign → ALLOWS", async () => {
  orchState(ORCH_SID);
  orchOwner(301, SIBLING_WT);            // owned by a different orchestrator worktree
  unhandledOrchReply({ from: "pg-tester", thread: 3011, parentThread: 301 });
  expect((await runOrchHook(MY_WT, apiUrl())).code).toBe(0);
});

test("orchestrator: unhandled envelope with NO owner record → BLOCKS (safe fallback)", async () => {
  orchState(ORCH_SID);
  orchSessionsDir();                     // scope_owner engages, but no .owner for 302
  unhandledOrchReply({ from: "next-impl", thread: 3021, parentThread: 302 });
  expect((await runOrchHook(MY_WT, apiUrl())).code).toBe(2);
});

test("orchestrator: needs_response archived w/o reply for an OWNED campaign → BLOCKS", async () => {
  threadStatus = { "5002": "active" };
  orchState(ORCH_SID);
  orchOwner(304, MY_WT);
  archivedOrchConsult({ from: "pg-writer", thread: 5002, parentThread: 304 });
  expect((await runOrchHook(MY_WT, apiUrl())).code).toBe(2);
});

test("orchestrator: needs_response archived w/o reply for a SIBLING campaign → ALLOWS", async () => {
  threadStatus = { "5003": "active" };
  orchState(ORCH_SID);
  orchOwner(305, SIBLING_WT);
  archivedOrchConsult({ from: "pg-writer", thread: 5003, parentThread: 305 });
  expect((await runOrchHook(MY_WT, apiUrl())).code).toBe(0);
});
