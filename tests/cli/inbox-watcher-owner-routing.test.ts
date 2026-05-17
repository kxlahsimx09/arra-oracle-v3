// inbox-watcher.sh — sticky reply-routing (thread #151) regression tests.
//
// A campaign's reply must wake the session that OPENED the thread (the
// "owner"), not a fresh sibling. The watcher learns ownership from the
// dispatch envelope's `parent_session` field, records it in a `.owner` map,
// and routes replies back: send-keys into a live-idle owner, --resume an idle
// owner, defer a mid-turn owner, --fresh + transfer when the owner is gone.
//
// Hermetic where possible: a stub `maw` records every call; a stub `tmux`
// feeds resolve_tmux_target. The send-keys / busy cases need a live process
// at the owner cwd — those spawn a throwaway `sleep` masquerading as claude.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, utimesSync, existsSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");

let root: string, inboxBase: string, stateDir: string, claudeProjects: string;
let mawLog: string, mawStub: string, tmuxStub: string;
const kids: ChildProcess[] = [];

beforeEach(() => {
  // realpathSync: macOS /tmp → /private/tmp firmlink. lsof reports the real
  // path, so owner_route_decision's cwd comparison only matches if our paths
  // are real too (the watcher compares the path as passed, like claude_alive_at).
  root = realpathSync(mkdtempSync(join(tmpdir(), "iw-owner-")));
  inboxBase = join(root, "inbox");
  stateDir = join(root, "state");
  claudeProjects = join(root, "claude-projects");
  mawLog = join(root, "maw-calls.log");
  mkdirSync(join(inboxBase, "for-orchestrator"), { recursive: true });
  mkdirSync(join(inboxBase, "for-brew-ops"), { recursive: true });
  mkdirSync(stateDir, { recursive: true });
  mkdirSync(claudeProjects, { recursive: true });

  mawStub = join(root, "maw-stub.sh");
  writeFileSync(
    mawStub,
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${mawLog}"\n` +
      `echo "+ worktree: ${root}/fake.wt-1-stub (branch)"\nexit 0\n`,
    { mode: 0o755 },
  );
  writeFileSync(mawLog, "");

  // tmux stub — overwritten per-test with the canned list-windows line.
  tmuxStub = join(root, "tmux-stub.sh");
  writeFileSync(tmuxStub, `#!/usr/bin/env bash\nexit 0\n`, { mode: 0o755 });
});

afterEach(() => {
  for (const k of kids) { try { if (k.pid) process.kill(k.pid, "SIGKILL"); } catch {} }
  kids.length = 0;
  rmSync(root, { recursive: true, force: true });
});

/** claude encodes cwd by replacing / and . with - (encode_cwd in the script). */
const encodeCwd = (p: string) => p.replace(/[/.]/g, "-");

/** Run one scan pass with the temp env wired in. */
function scanOnce(extraEnv: Record<string, string> = {}) {
  return spawnSync("bash", [SCRIPT, "scan-once"], {
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      STATE_DIR: stateDir,
      CLAUDE_PROJECTS: claudeProjects,
      MAW_BIN: `bash ${mawStub}`,
      TMUX_BIN: `bash ${tmuxStub}`,
      INBOX_POLL_INTERVAL: "1",
      INBOX_AUTO_CLEAN: "0",
      ...extraEnv,
    },
    encoding: "utf8",
  });
}

/** Write an envelope into for-<oracle>/. */
function envelope(oracle: string, name: string, fields: Record<string, string | number>) {
  const lines = ["---", "from: next-impl", `to: ${oracle}`, "type: reply"];
  for (const [k, v] of Object.entries(fields)) lines.push(`${k}: ${v}`);
  lines.push("created: 2026-05-17T19:00:00+07:00", "---", "", "body");
  writeFileSync(join(inboxBase, `for-${oracle}`, name), lines.join("\n"));
}

/** Pre-seed the owner map for (oracle, campaign). */
function seedOwner(oracle: string, campaign: number, wt: string) {
  const dir = join(stateDir, "sessions", oracle);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `thread-${campaign}.owner`), wt + "\n");
}

const ownerOf = (oracle: string, campaign: number) =>
  readFileSync(join(stateDir, "sessions", oracle, `thread-${campaign}.owner`), "utf8").trim();

/** status= field of the single state file in for-<oracle>/. */
function onlyStatus(oracle: string): string {
  const dir = join(stateDir, "state", oracle);
  const f = require("node:fs").readdirSync(dir).find((x: string) => x.endsWith(".state"))!;
  return readFileSync(join(dir, f), "utf8").match(/^status=(.*)$/m)![1];
}

/** A claude-named worktree dir with a JSONL session file aged `ageSec`. */
function ownerWorktree(name: string, sid: string, ageSec: number): string {
  const wt = join(root, name);
  mkdirSync(wt, { recursive: true });
  const proj = join(claudeProjects, encodeCwd(wt));
  mkdirSync(proj, { recursive: true });
  const jsonl = join(proj, `${sid}.jsonl`);
  writeFileSync(jsonl, "{}\n");
  const mt = Date.now() / 1000 - ageSec;
  utimesSync(jsonl, mt, mt);
  return wt;
}

/** Spawn a throwaway process at `wt` whose argv matches pgrep -f "claude ". */
function spawnFakeClaude(wt: string) {
  const sh = join(root, "fake-claude.sh");
  writeFileSync(sh, `#!/usr/bin/env bash\ncd "$1" || exit 1\nexec -a "claude --probe owner" sleep 120\n`, { mode: 0o755 });
  const p = spawn("bash", [sh, wt], { detached: true, stdio: "ignore" });
  p.unref();
  kids.push(p);
  spawnSync("sleep", ["0.6"]); // let cd + exec settle so lsof sees the cwd
  return p;
}

test("record_owner_from_dispatch writes the owner map from a dispatch envelope", () => {
  // A dispatch to a worker carrying parent_session — the orchestrator stamp.
  envelope("brew-ops", "2026-05-17_15-22_from-orchestrator_thread-201_dispatch.md", {
    thread: 201, parent_thread: 200, parent_oracle: "orchestrator",
    parent_session: "/Users/dev01/Code/arra.wt-9-inbox-owner",
  });
  // A dispatch with NO parent_session — must NOT create an owner record.
  envelope("brew-ops", "2026-05-17_15-23_from-orchestrator_thread-211_dispatch.md", {
    thread: 211, parent_thread: 210, parent_oracle: "orchestrator",
  });

  const r = scanOnce();
  expect(r.status).toBe(0);
  expect(ownerOf("orchestrator", 200)).toBe("/Users/dev01/Code/arra.wt-9-inbox-owner");
  expect(existsSync(join(stateDir, "sessions", "orchestrator", "thread-210.owner"))).toBe(false);
});

test("owner record is write-once — a re-scanned dispatch never clobbers a transfer", () => {
  envelope("brew-ops", "2026-05-17_15-22_from-orchestrator_thread-301_dispatch.md", {
    thread: 301, parent_thread: 300, parent_oracle: "orchestrator",
    parent_session: "/Users/dev01/Code/arra.wt-9-inbox-owner",
  });
  scanOnce();
  // Ownership transferred elsewhere (simulating route_to_owner's gone path).
  seedOwner("orchestrator", 300, "/Users/dev01/Code/arra.wt-99-inbox-new");
  scanOnce(); // dispatch envelope still present — must not overwrite
  expect(ownerOf("orchestrator", 300)).toBe("/Users/dev01/Code/arra.wt-99-inbox-new");
});

test("dead owner (worktree gone) → --fresh spawn + ownership transfers to it", () => {
  seedOwner("orchestrator", 400, join(root, "arra.wt-9-inbox-gone")); // never created
  envelope("orchestrator", "2026-05-17_20-00_from-next-impl_thread-401_reply.md", {
    thread: 401, parent_thread: 400,
  });

  const r = scanOnce();
  expect(r.status).toBe(0);
  // Fresh spawn fired, and the new worktree is now the campaign owner.
  expect(readFileSync(mawLog, "utf8")).toContain("--fresh");
  expect(ownerOf("orchestrator", 400)).toBe(`${root}/fake.wt-1-stub`);
});

test("idle owner (worktree present, no claude) → --resume the owner session", () => {
  const wt = ownerWorktree("arra.wt-9-inbox-owner", "OWNER-SID-XYZ", 9999);
  seedOwner("orchestrator", 500, wt);
  envelope("orchestrator", "2026-05-17_20-00_from-next-impl_thread-501_reply.md", {
    thread: 501, parent_thread: 500,
  });

  const r = scanOnce();
  expect(r.status).toBe(0);
  // session-id derived from the owner worktree's newest JSONL, resumed.
  expect(readFileSync(mawLog, "utf8")).toContain("--resume OWNER-SID-XYZ");
  expect(onlyStatus("orchestrator")).toBe("fired");
});

test("live + idle owner → send-keys delivery via maw hey (status delivered_to_owner)", () => {
  const wt = ownerWorktree("arra.wt-9-inbox-owner", "OWNER-SID-LIVE", 600); // JSONL stale
  spawnFakeClaude(wt);
  seedOwner("orchestrator", 600, wt);
  // tmux stub maps the owner worktree → a session:window target.
  writeFileSync(tmuxStub,
    `#!/usr/bin/env bash\nprintf '%s\\n' "${wt}|01-soul-brews|orchestrator-inbox-owner"\nexit 0\n`,
    { mode: 0o755 });
  envelope("orchestrator", "2026-05-17_20-00_from-next-impl_thread-601_reply.md", {
    thread: 601, parent_thread: 600,
  });

  const r = scanOnce({ OWNER_IDLE_GRACE: "2" });
  expect(r.status).toBe(0);
  expect(onlyStatus("orchestrator")).toBe("delivered_to_owner");
  expect(readFileSync(mawLog, "utf8")).toContain("hey local:01-soul-brews:orchestrator-inbox-owner");
});

test("live + busy owner (JSONL fresh) → deferred, no send-keys collision", () => {
  const wt = ownerWorktree("arra.wt-9-inbox-owner", "OWNER-SID-BUSY", 0); // JSONL just touched
  spawnFakeClaude(wt);
  seedOwner("orchestrator", 700, wt);
  envelope("orchestrator", "2026-05-17_20-00_from-next-impl_thread-701_reply.md", {
    thread: 701, parent_thread: 700,
  });

  const r = scanOnce({ OWNER_IDLE_GRACE: "45" });
  expect(r.status).toBe(0);
  expect(onlyStatus("orchestrator")).toBe("deferred");
  // mid-turn owner: nothing sent — neither a wake nor a hey.
  expect(readFileSync(mawLog, "utf8").trim()).toBe("");
});
