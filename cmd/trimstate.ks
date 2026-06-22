// ============================================================
// cmd/trimstate.ks  —  Prune deprecated keys from mission state
// (0:/cmd/trimstate.ks)
//
// Archive-only operator command (run when linked). State accretes
// keys over a project's life that the current code no longer reads;
// this removes them. Safe to re-run and safe when a key is already
// absent (stateRemove no-ops rather than erroring).
//
// Usage:
//   RUNONCEPATH("0:/cmd/trimstate.ks").                      // deprecated only
//   RUNONCEPATH("0:/cmd/trimstate.ks", LEX("stale", TRUE)).  // + phase scratch
//
// "stale" mode also drops transient per-phase scratch keys. Those
// are still READ by their phases (with safe defaults), so only run
// stale mode while parked between phases / on the ground — not in
// the middle of the phase that owns them.
// ============================================================

PARAMETER opts IS LEXICON().
LOCAL dropStale IS FALSE.
IF opts:HASKEY("stale") { SET dropStale TO opts["stale"]. }

// Keys/prefixes the current codebase no longer reads or writes.
// Extend these lists as more state is retired (git blame is the record).
LOCAL DEAD_KEYS IS LIST(
    "lib_band_libs"          // cached band libs — never persist derived libs
).
LOCAL DEAD_PREFIXES IS LIST(
    "mission_cfg_"           // mission config moved out of state (5e07071)
).

// Transient per-phase scratch: live keys, but disposable once their
// phase is behind you (readers fall back to defaults). Only cleared
// in "stale" mode.
LOCAL STALE_KEYS IS LIST(
    "prelaunch_plane_lan", "prelaunch_plane_inc",
    "prelaunch_plane_target", "prelaunch_plane_ut",
    "xing_arrival_ut", "xing_arrival_target",
    "midcourse_refine_method", "midcourse_refine_fraction",
    "midcourse_refine_arrival_ut", "midcourse_refine_ut",
    "launch_vs_nonpos_logged"
).

LOCAL loaded IS FALSE.
IF EXISTS("1:/lib/state.ksm") {
    RUNONCEPATH("1:/lib/state.ksm").
    SET loaded TO TRUE.
} ELSE IF EXISTS("1:/lib/state.ks") {
    RUNONCEPATH("1:/lib/state.ks").
    SET loaded TO TRUE.
} ELSE {
    PRINT "ERROR: cached state library not found.".
    PRINT "Boot the vessel once with a link, then re-run.".
}

IF loaded {
    stateInit().
    LOCAL before IS stateKeys():LENGTH.
    LOCAL removed IS 0.
    PRINT "trimstate: " + before + " state keys.".

    FOR k IN DEAD_KEYS {
        IF stateRemove(k) {
            PRINT "  removed deprecated: " + k.
            SET removed TO removed + 1.
        }
    }
    FOR pfx IN DEAD_PREFIXES {
        LOCAL n IS stateRemovePrefix(pfx).
        IF n > 0 {
            PRINT "  removed " + n + " deprecated '" + pfx + "*' key(s).".
            SET removed TO removed + n.
        }
    }

    IF dropStale {
        PRINT "  (stale mode: clearing finished-phase scratch)".
        FOR k IN STALE_KEYS {
            IF stateRemove(k) {
                PRINT "  removed stale: " + k.
                SET removed TO removed + 1.
            }
        }
    }

    IF removed = 0 {
        PRINT "trimstate: nothing to remove — state is clean.".
    } ELSE {
        PRINT "trimstate: removed " + removed + " key(s); "
            + stateKeys():LENGTH + " remain.".
    }
}
