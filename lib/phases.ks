// ============================================================
// phases.ks  —  Generic phase machine  (0:/lib/phases.ks)
// ============================================================

GLOBAL FUNCTION runPhases {
    PARAMETER phaseMap.

    UNTIL FALSE {
        LOCAL phase IS stateGet("phase", "DONE").
        mLogPhase(phase).
        IF phaseMap:HASKEY(phase) {
            phaseMap[phase]:CALL().
        } ELSE IF phase = "DONE" {
            phaseDone().
            RETURN.
        } ELSE IF CFG:HASKEY("PROGRESSIVE_RELOAD") AND CFG["PROGRESSIVE_RELOAD"] > 0 {
            mLog("Phase " + phase + " requires a different library band. Reboot to continue.").
            PRINT " ".
            PRINT "  PHASE READY: " + phase.
            PRINT "  Reboot this CPU to load the next mission library band.".
            WAIT UNTIL FALSE.
        } ELSE {
            mLogError("Unknown phase: " + phase + " — halting.").
            stateSet("phase", "DONE").
        }
    }
}

GLOBAL FUNCTION nextPhase {
    PARAMETER seq.

    LOCAL current IS stateGet("phase", seq[0]).
    LOCAL i IS 0.
    UNTIL i >= seq:LENGTH {
        IF seq[i] = current {
            IF i + 1 < seq:LENGTH {
                LOCAL nxt IS seq[i + 1].
                stateSet("phase", nxt).
                mLog("Phase: " + current + " -> " + nxt).
                RETURN nxt.
            } ELSE {
                stateSet("phase", "DONE").
                RETURN "DONE".
            }
        }
        SET i TO i + 1.
    }
    mLogWarn("Phase " + current + " not in sequence — advancing to DONE.").
    stateSet("phase", "DONE").
    RETURN "DONE".
}

GLOBAL FUNCTION phaseDone {
    UNLOCK ALL.
    SET SAS TO TRUE.
    mLog("Mission complete: " + SHIP:NAME).
    HUDTEXT("Mission Complete", 10, 2, 20, GREEN, FALSE).
}
