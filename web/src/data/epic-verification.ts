// Epic Verification ledger — single source of truth.
//
// This file collects the per-epic verification data. The /verify dashboard and
// the per-epic detail pages read from `epics` below. Only GENUINELY-COMPLETED
// epics (verified DONE on `main`) are listed here.
//
// HOW TO STAMP AN EPIC "PASSED":
//   1. Follow the E2E procedure on the epic's detail page (/verify/<slug>).
//   2. Open the epic's data file under src/data/epics/ (e.g. epic-1278.ts).
//   3. Set:  status: 'passed', verifiedBy: 'Your Name', verifiedDate: '2026-06-21'
//      (optionally tick individual `passed: true` flags on each feature).
//   4. Re-run `bun run build`; the dashboard badge updates automatically.

import type { Epic } from "./epics/types";
import { epic1278 } from "./epics/epic-1278";
import { epic1072 } from "./epics/epic-1072";
import { epic1369 } from "./epics/epic-1369";

export type { Epic, Feature, VerifyStatus } from "./epics/types";

/** The ordered list of epics under verification. */
export const epics: Epic[] = [epic1278, epic1072, epic1369];

/** Look up an epic by its URL slug (used by the dynamic detail route). */
export function epicBySlug(slug: string): Epic | undefined {
  return epics.find((e) => e.slug === slug);
}

/** Count of epics stamped PASSED. */
export function passedCount(): number {
  return epics.filter((e) => e.status === "passed").length;
}
