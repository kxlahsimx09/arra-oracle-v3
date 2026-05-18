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
