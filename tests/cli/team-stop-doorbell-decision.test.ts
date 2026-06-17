// team-doorbell-lib.sh — Stop-hook doorbell decision helpers.
//
// The team-stop-doorbell-hook rings the orchestrator's pane when a teammate
// finishes a turn (PRIMARY completion signal in the workflow-2 team-dispatch
// model, where the leader otherwise only learns by polling). These pure helpers
// decide (a) is this even a dispatched team teammate, (b) which orchestrator
// worktree spawned it, and (c) is this Stop a throwaway keepalive reply (skip) —
// so the impure hook stays a thin I/O shell around tested logic.

import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const LIB = join(import.meta.dir, "..", "..", "scripts", "team-doorbell-lib.sh");

// Run `<fn> "<arg>"` in a bash that sourced the lib; return {ok, out}. `ok` is
// the function's exit status === 0 (for predicate helpers); `out` is stdout (for
// extractors). Arg passed positionally so paths/quotes can't break the shell.
function call(fn: string, arg: string): { ok: boolean; out: string } {
  const r = spawnSync("bash", ["-c", `source "$0"; ${fn} "$1"`, LIB, arg], {
    encoding: "utf8",
  });
  return { ok: r.status === 0, out: r.stdout.trim() };
}

const TEAM_SPF =
  "/home/ubuntu/Code/github.com/Soul-Brews-Studio/arra-oracle-v3.wt-10-liverun/ψ/memory/mailbox/teams/botscrape/next-live-tester-spawn-prompt.md";

test("is_team_spf: a teammate's mailbox/teams prompt file gates IN", () => {
  expect(call("doorbell_is_team_spf", TEAM_SPF).ok).toBe(true);
});

test("is_team_spf: a regular oracle/dev prompt file gates OUT (no-op)", () => {
  expect(call("doorbell_is_team_spf", "/home/ubuntu/.claude/some-system-prompt.md").ok).toBe(false);
  expect(call("doorbell_is_team_spf", "/repo/ψ/memory/retrospectives/x.md").ok).toBe(false);
});

test("owt_from_spf: extracts the orchestrator worktree up to /ψ/", () => {
  expect(call("doorbell_owt_from_spf", TEAM_SPF).out).toBe(
    "/home/ubuntu/Code/github.com/Soul-Brews-Studio/arra-oracle-v3.wt-10-liverun",
  );
});

test("owt_from_spf: a path without a /ψ/ segment fails (no worktree)", () => {
  const r = call("doorbell_owt_from_spf", "/no/psi/segment/here.md");
  expect(r.ok).toBe(false);
  expect(r.out).toBe("");
});

test("is_keepalive: an idle_notification user turn is a throwaway → skip", () => {
  expect(
    call("doorbell_is_keepalive", '{"type":"user","message":{"content":"idle_notification: poll"}}').ok,
  ).toBe(true);
});

test("is_keepalive: a real task/work user turn is NOT keepalive → ring", () => {
  expect(
    call("doorbell_is_keepalive", '{"type":"user","message":{"content":"run the deposit journey"}}').ok,
  ).toBe(false);
});

test("agentid split: role before @, campaign after @", () => {
  expect(call("doorbell_agentid_role", "next-live-tester@botscrape").out).toBe("next-live-tester");
  expect(call("doorbell_agentid_campaign", "next-live-tester@botscrape").out).toBe("botscrape");
});
