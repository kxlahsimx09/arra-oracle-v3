// Epic Verification — shared types.
//
// This file defines the shape of the verification ledger. The actual data
// lives in one file per epic (epic-1278.ts, epic-1072.ts, epic-1369.ts) and
// is collected by ../epic-verification.ts.
//
// A human "stamps" an epic PASSED by editing the epic's data file:
//   status: 'passed', verifiedBy: 'Your Name', verifiedDate: '2026-06-21'
// (optionally ticking individual feature `passed` flags as you go).

export type VerifyStatus = "pending" | "passed";

export interface Feature {
  /** Stable id, unique within the epic (used for anchors + checkboxes). */
  id: string;
  /** Short human-readable feature name. */
  name: string;
  /** Prerequisites or notes shown before the numbered steps (optional). */
  notes?: string;
  /** Numbered, end-to-end, copy-friendly steps. Plain strings; commands in `backticks` or as `$ cmd`. */
  steps: string[];
  /** The exact expected result after running the steps. */
  expected: string;
  /** Per-feature stamp. Tick to true once you have personally verified it. */
  passed?: boolean;
}

export interface Epic {
  /** Epic number from the tracker (e.g. 1278). */
  id: number;
  /** URL slug for the detail page, e.g. "1278-plugin-engine". */
  slug: string;
  title: string;
  /** One-line summary of what the epic delivers. */
  summary: string;
  /** Overall verification status. Set to 'passed' to stamp. */
  status: VerifyStatus;
  /** Who stamped it (fill in when status -> 'passed'). */
  verifiedBy: string;
  /** Date stamped, ISO yyyy-mm-dd (fill in when status -> 'passed'). */
  verifiedDate: string;
  /** How to start the server / prerequisites shared by all features. */
  prerequisites: string[];
  features: Feature[];
}
