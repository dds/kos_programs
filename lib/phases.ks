// ============================================================
// phases.ks  —  Generic phase machine  (0:/lib/phases.ks)
// ============================================================

GLOBAL phaseShouldYield IS FALSE.
GLOBAL launchSeq IS LIST().
GLOBAL xferSeq IS LIST().

GLOBAL FUNCTION yieldToPrompt {
    SET phaseShouldYield TO TRUE.
}

GLOBAL FUNCTION phaseMapSet {
    PARAMETER phaseMap.
    PARAMETER phaseName.
    PARAMETER handler.
    IF phaseMap:HASKEY(phaseName) { phaseMap:REMOVE(phaseName). }
    phaseMap:ADD(phaseName, handler).
}

GLOBAL FUNCTION phaseHandlerMap {
    IF NOT DEFINED dependencyPhaseHandlers AND DEFINED bootLibRun {
        bootLibRun("dependencies").
    }
    IF DEFINED dependencyPhaseHandlers {
        RETURN dependencyPhaseHandlers().
    }
    RETURN LEXICON().
}

GLOBAL FUNCTION runPhases {
    PARAMETER phaseMap.
    SET phaseShouldYield TO FALSE.

    UNTIL FALSE {
        LOCAL phase IS stateGet("phase", "DONE").
        mLogPhase(phase).
        _logPhaseStats(phase).
        IF phaseMap:HASKEY(phase) {
            phaseMap[phase]:CALL().
            IF phaseShouldYield { RETURN. }
        } ELSE IF phase = "DONE" {
            phaseDone().
            RETURN.
        } ELSE {
            stateSet("reload_required", "true").
            stateSet("reload_reason", "PHASE_BAND_CHANGE").
            stateSet("reload_next_phase", phase).
            IF DEFINED bootLibBandForPhase {
                stateSet("reload_next_band", bootLibBandForPhase(phase, "UNKNOWN")).
            } ELSE {
                stateSet("reload_next_band", "UNKNOWN").
            }
            mLog("Phase " + phase + " requires a different library band. Reboot to continue.").
            PRINT " ".
            PRINT "  PHASE READY: " + phase.
            PRINT "  Reboot this CPU to load the next mission library band.".
            yieldToPrompt().
            RETURN.
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
                archivePhaseLog().
                RETURN nxt.
            } ELSE {
                stateSet("phase", "DONE").
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
    IF HOMECONNECTION:ISCONNECTED {
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
