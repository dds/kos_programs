// ============================================================
// cmd/solarhold.ks  —  Re-find the best solar attitude and HOLD
// (0:/cmd/solarhold.ks)
//
// Runs the full measured search (six axes + refinement), keeps
// the steering locked on the result — on craft with no SAS
// source (no pilot, no SAS core) the hold lives exactly as long
// as this program does — and maintains it warp-aware: when panel
// flow sags below SOLAR_HOLD_RATIO (0.92) of its reference, it
// drops out of warp (waiting for the rails release to actually
// settle), re-aims, and restores your warp factor.
//
// Usage:
//   RUNPATH("1:/cmd/solarhold.ks").           // hold indefinitely
//   RUNPATH("1:/cmd/solarhold.ks", 86400).    // hold N seconds
//   RUNPATH("1:/cmd/solarhold.ks", 0, FALSE). // skip the search,
//                                             // quick cached aim
// ============================================================

PARAMETER holdFor IS 0.
PARAMETER research IS TRUE.

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("solar").

orientForSolar(research, TRUE).
solarMaintainHold(CHOOSE TIME:SECONDS + holdFor IF holdFor > 0 ELSE 0).
