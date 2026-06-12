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
    bootLibRun("dependencies").
    LOCAL phaseMap IS LEXICON().
    // Try every known phase: each binding is guarded on its libs
    // having run this boot, so phases brought in via LIBS_EXTRA
    // bind too and the mission avoids band-change reboots.
    FOR phaseName IN dependencyAllPhases() {
        dependencyBindPhase(phaseMap, phaseName).
    }
    RETURN phaseMap.
}

GLOBAL FUNCTION runPhases {
    PARAMETER phaseMap.
    SET phaseShouldYield TO FALSE.
    LOCAL lastPhase IS "".
    LOCAL repeats IS 0.

    UNTIL FALSE {
        LOCAL phase IS stateGet("phase", "DONE").
        // A handler returning without advancing, yielding, or
        // rebooting would spin here silently (e.g. a sticky ABORT
        // flag making early-returns). Three strikes -> hold.
        IF phase = lastPhase {
            SET repeats TO repeats + 1.
            IF repeats >= 3 {
                mLogError("Phase " + phase + " returned " + repeats
                    + "x without progress — holding. (Sticky ABORT?"
                    + " Clear with SET ABORT TO FALSE.)").
                yieldToPrompt().
                RETURN.
            }
        } ELSE {
            SET lastPhase TO phase.
            SET repeats TO 0.
        }
        mLogPhase(phase).
        _logPhaseStats(phase).
        IF phaseMap:HASKEY(phase) {
            phaseMap[phase]:CALL().
            IF phaseShouldYield { RETURN. }
        } ELSE IF phase = "DONE" {
            phaseDone().
            RETURN.
        } ELSE {
            LOCAL loadedBand IS stateGet("lib_band", "").
            LOCAL requiredBand IS bootLibBandForPhase(phase, "").
            IF requiredBand = loadedBand {
                // Offline, the libs simply could not sync: keep
                // retrying on a 60s pace until the link returns —
                // the operator-blessed self-healing loop. Linked,
                // a missing handler is a real error: hold.
                IF NOT HOMECONNECTION:ISCONNECTED {
                    mLogWarn("Phase " + phase + " libs unavailable"
                        + " offline — reboot retry in 60s"
                        + " (waiting for a link).").
                    HUDTEXT("No link: retrying " + phase
                        + " in 60s", 10, 2, 15, YELLOW, FALSE).
                    WAIT 60.
                    REBOOT.
                }
                mLogError("Phase " + phase + " handler missing in loaded band " + loadedBand + ".").
                PRINT " ".
                PRINT "  PHASE HANDLER MISSING: " + phase.
                PRINT "  Loaded band: " + loadedBand + ".".
                PRINT "  Check generated dependencies.ks and loaded libraries.".
                yieldToPrompt().
                RETURN.
            }
            stateSet("reload_required", "true").
            stateSet("reload_reason", "PHASE_BAND_CHANGE").
            stateSet("reload_next_phase", phase).
            stateSet("reload_next_band", requiredBand).
            mLog("Phase " + phase + " requires a different library band. Reboot to continue.").
            // Band changes auto-reboot: reboots are the system's
            // resumable primitive, and waiting on an operator was
            // flight-found fatal in atmosphere and merely annoying
            // everywhere else. The 5s notice gives a watching
            // operator time to react.
            HUDTEXT("Band change: rebooting for " + phase + "...",
                5, 2, 15, CYAN, FALSE).
            mLogWarn("Auto-rebooting into band " + requiredBand
                + " for phase " + phase + ".").
            WAIT 5.
            REBOOT.
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

// Guarded solar orient for coasts: a no-op unless the solar lib
// loaded this boot and the ship is on a stable trajectory in
// space. Safe to call from anywhere in the preamble's reach.
// KEEP_WARP = 1: do not drop out of warp for BIOME crossings
// during orbit stays (EVA_BIOMES announcements become HUD-only).
// Mission-critical warp stops — burn windows, alarms, reentry —
// are always unconditional.
// Reboot-safe KAC alarm: reuse a same-name alarm if its time is
// already right, replace it if stale, create it otherwise —
// phase re-entry after a reboot must not mint duplicates
// (flight-found: a stack of 'Return window' alarms).
GLOBAL FUNCTION kacEnsureAlarm {
    PARAMETER almName.
    PARAMETER almUt.
    PARAMETER almNote.
    IF NOT ADDONS:KAC:AVAILABLE { RETURN "". }
    FOR a IN LISTALARMS("All") {
        IF a:NAME = almName {
            IF ABS(a:TIME - almUt) < 60 { RETURN a:ID. }
            DELETEALARM(a:ID).
        }
    }
    LOCAL alm IS ADDALARM("Raw", almUt, almName, almNote).
    SET alm:ACTION TO "KillWarp".
    RETURN alm:ID.
}

GLOBAL FUNCTION warpHoldEnabled {
    IF DEFINED CFG AND CFG:HASKEY("KEEP_WARP") {
        RETURN CFG["KEEP_WARP"] > 0.
    }
    RETURN stateGetNum("mission_cfg_KEEP_WARP", 0) > 0.
}

GLOBAL FUNCTION trySolarOrient {
    IF (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING"
            OR SHIP:STATUS = "SUB_ORBITAL")
            AND DEFINED BOOT_LIB_RAN
            AND BOOT_LIB_RAN:CONTAINS("solar") {
        orientForSolar().
    }
}

// Guarded solar-hold tick for long coasts: maintains the solar
// attitude (warp-aware re-aims when panel flow sags) wherever
// the solar lib is aboard; a no-op pass-through otherwise.
GLOBAL FUNCTION trySolarHoldTick {
    PARAMETER refFlow.
    IF (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING"
            OR SHIP:STATUS = "SUB_ORBITAL")
            AND DEFINED BOOT_LIB_RAN
            AND BOOT_LIB_RAN:CONTAINS("solar") {
        RETURN solarHoldTick(refFlow).
    }
    RETURN refFlow.
}

GLOBAL FUNCTION phaseDone {
    UNLOCK ALL.
    SET SAS TO TRUE.
    mLog("Mission complete: " + SHIP:NAME).
    HUDTEXT("Mission Complete", 10, 2, 20, GREEN, FALSE).
    // On-station ships hold their best solar attitude through
    // DONE (cached axis makes this a quick aim, not a search).
    // PHASE DONE = solar brings the lib along at DONE boots.
    trySolarOrient().
    yieldToPrompt().
}
