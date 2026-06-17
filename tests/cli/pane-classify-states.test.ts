// pane-classify.sh — classify_pane_state state-machine regression tests.
//
// Guards the L2 teammate-liveness fix: the orchestrator used to infer "done"
// from the ABSENCE of `esc to interrupt` — one bit that conflated done-OK,
// API-errored, and crashed (the liverun idle/quota-leak + lost-API-error bugs).
// classify_pane_state must return exactly one distinct state per situation.
//
// Hermetic + pure: classify_pane_state makes no tmux/ps calls, so each case is a
// fixed pane capture + pid-alive bit → expected state. No processes are touched.

import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "brew-ops-bot", "pane-classify.sh");

// Run classify_pane_state("<pane>", "<pidAlive>") in a fresh bash and return its
// trimmed stdout. Args are passed positionally (never interpolated into source)
// so newlines/quotes/emoji in fixtures can't break the shell.
function classify(pane: string, pidAlive: "0" | "1" = "1"): string {
  const r = spawnSync(
    "bash",
    ["-c", `source "$0"; classify_pane_state "$1" "$2"`, SCRIPT, pane, pidAlive],
    { encoding: "utf8" },
  );
  expect(r.status).toBe(0);
  return r.stdout.trim();
}

const ESC = "esc to interrupt";
const HINT = "? for shortcuts";

test("working: esc-to-interrupt up", () => {
  expect(classify(`✻ Forging… (12s · ${ESC})`)).toBe("working");
});

test("working outranks a visible error line (claude is retrying a transient 529)", () => {
  expect(
    classify(`✻ Retrying… (${ESC})\nAPI Error: 529 overloaded_error — Retrying in 4s`),
  ).toBe("working");
});

test("menu: a numbered ❯ N. selection menu is waiting", () => {
  expect(classify(`Pick one:\n  ❯ 1. Yes\n    2. No\n${HINT}`)).toBe("menu");
});

test("api_error: API Error parked at the prompt (no esc-to-interrupt)", () => {
  expect(
    classify(`API Error: 500 {"type":"error","error":{"type":"api_error"}}\n\n> \n${HINT}`),
  ).toBe("api_error");
});

test("api_error: request timed out", () => {
  expect(classify(`⎿ Request timed out\n\n> \n  ⏵⏵ accept edits on`)).toBe("api_error");
});

test("api_error: usage limit reached", () => {
  expect(
    classify(`Claude usage limit reached. Your limit will reset at 9pm.\n> \n${HINT}`),
  ).toBe("api_error");
});

test("crashed: dead pid overrides a stale on-screen frame", () => {
  // Screen still shows a working frame, but the process is gone → crashed.
  expect(classify(`✻ Forging… (${ESC})`, "0")).toBe("crashed");
});

test("crashed: pane fell back to a bare shell prompt (no claude TUI marker)", () => {
  expect(classify(`ubuntu@host:~/Code/x$ \nubuntu@host:~/Code/x$ `)).toBe("crashed");
});

test("idle_done: claude TUI at the prompt, no error → finished its turn", () => {
  expect(
    classify(
      `I have completed the task and pushed the PR.\n\n> \n${HINT}            Context left: 42%`,
    ),
  ).toBe("idle_done");
});

test("api_error FALSE-POSITIVE regression: error words in SCROLLBACK prose, idle at bottom → idle_done", () => {
  // The 2026-06-17 self-watch FP: the watcher read a brew-ops dev session whose
  // own conversation discussed the feature ("auto-resume 529", "api_error",
  // "crashed"), with an idle prompt at the bottom. Must NOT classify api_error.
  const pane = [
    "  - agent API error เงียบ → L2 classify api_error distinct → alert owner",
    "  ค้างเดียว — L3 (auto-action): auto-resume 529 / opt-in auto-close idle / crashed",
    "  salvage-hint groundwork อยู่ใน git stash",
    "  จะให้ทำ L3 ต่อ ไหมครับ หรือพอแค่นี้?",
    "✻ Brewed for 1m 41s",
    "─────────────────────────────────────────────",
    "❯                                            ",
    "─────────────────────────────────────────────",
    "  ⏵⏵ bypass permissions on            ? for shortcuts",
  ].join("\n");
  expect(classify(pane)).toBe("idle_done");
});

test("api_error still fires when a REAL banner sits in the bottom region", () => {
  const pane = [
    "  I'll run the deposit journey now.",
    "  (lots of earlier work scrolled above)",
    "⎿  API Error: 529 overloaded_error — giving up after retries",
    "─────────────────────────────────────────────",
    "❯ ",
    "  ? for shortcuts",
  ].join("\n");
  expect(classify(pane)).toBe("api_error");
});

test("unknown: empty capture (transient tmux failure) — never guess", () => {
  expect(classify("")).toBe("unknown");
});

test("unknown: whitespace-only capture", () => {
  expect(classify("   \n  \n")).toBe("unknown");
});

test("crashed beats unknown: empty capture but a dead pid is still definitive", () => {
  expect(classify("", "0")).toBe("crashed");
});
