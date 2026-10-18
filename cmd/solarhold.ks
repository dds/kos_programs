// ============================================================
// cmd/solarhold.ks  —  Validate/find the best solar attitude and HOLD
// (0:/cmd/solarhold.ks)
//
// Tries the saved axis and validates measured flow before searching; keeps
// the steering locked on the result — on craft with no SAS
// source (no pilot, no SAS core) the hold lives exactly as long
// as this program does — and maintains it warp-aware: when panel
// flow sags below SOLAR_HOLD_RATIO (0.92) of its reference, it
// drops out of warp (waiting for the rails release to actually
// settle), re-aims, and restores your warp factor.
//
// Usage:
//   RUNPATH("0:/cmd/solarhold.ks").           // hold indefinitely
//   RUNPATH("0:/cmd/solarhold.ks", 86400).    // hold N seconds
//   RUNPATH("0:/cmd/solarhold.ks", 0, TRUE). // force a new search
// ============================================================

PARAMETER holdFor IS 0.
PARAMETER research IS FALSE.

LOCAL FUNCTION _cmdSolarhold {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("solar").

    IF NOT orientForSolar(research, TRUE, TRUE) {
        PRINT "Solar search failed; hold not started. Use cmd/solarreport.ks for the diagnostic path.".
        RETURN.
    }
    solarMaintainHold(CHOOSE TIME:SECONDS + holdFor IF holdFor > 0 ELSE 0).
}

_cmdSolarhold().
