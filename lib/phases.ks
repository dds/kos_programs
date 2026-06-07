// ============================================================
// phases.ks  —  Generic phase machine  (0:/lib/phases.ks)
// ============================================================

GLOBAL FUNCTION runPhases {
    PARAMETER phaseMap.

    UNTIL FALSE {
        LOCAL phase IS stateGet("phase", "DONE").
        mLogPhase(phase).
        _logPhaseStats(phase).
        IF phaseMap:HASKEY(phase) {
            phaseMap[phase]:CALL().
        } ELSE IF phase = "DONE" {
            phaseDone().
            RETURN.
        } ELSE IF CFG:HASKEY("PROGRESSIVE_RELOAD") AND CFG["PROGRESSIVE_RELOAD"] > 0 {
            stateSet("reload_required", "true").
            stateSet("reload_reason", "PHASE_BAND_CHANGE").
            stateSet("reload_next_phase", phase).
            stateSet("reload_next_band", "UNKNOWN").
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

LOCAL FUNCTION _logPhaseStats {
    PARAMETER phase.
    mLogWarn("STATS phase entry phase=" + phase
        + " body=" + SHIP:BODY:NAME
        + " status=" + SHIP:STATUS
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)
        + " band=" + stateGet("lib_band", "")
        + " free=" + ROUND(CORE:VOLUME:FREESPACE,0)).
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
                mLogWarn("STATS phase transition from=" + current + " to=" + nxt).
                archivePhaseLog().
                RETURN nxt.
            } ELSE {
                stateSet("phase", "DONE").
                mLogWarn("STATS phase transition from=" + current + " to=DONE").
                archivePhaseLog().
                RETURN "DONE".
            }
        }
        SET i TO i + 1.
    }
    mLogWarn("Phase " + current + " not in sequence — advancing to DONE.").
    stateSet("phase", "DONE").
    archivePhaseLog().
    RETURN "DONE".
}

GLOBAL FUNCTION archivePhaseLog {
    IF HAS_LINK {
        archiveLog().
        mLog("Phase log archived.").
    } ELSE {
        mLog("Phase log archive skipped: no KSC link.").
    }
}

GLOBAL FUNCTION phaseDone {
    UNLOCK ALL.
    SET SAS TO TRUE.
    mLog("Mission complete: " + SHIP:NAME).
    HUDTEXT("Mission Complete", 10, 2, 20, GREEN, FALSE).
}
