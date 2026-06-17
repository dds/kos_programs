// ============================================================
// phases.ks  —  Generic phase machine  (0:/lib/phases.ks)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL KEEP_WARP IS 0.
GLOBAL EVA_BIOMES IS "".
GLOBAL COAST_AUTO_WARP IS 0.
GLOBAL COAST_AUTO_WARP_MIN IS 60.
GLOBAL COAST_HIBERNATE IS 0.
GLOBAL COAST_HIBERNATE_MIN IS 600.
GLOBAL COAST_WARP_5M_LIMIT IS 300.
GLOBAL COAST_WARP_5H_LIMIT IS 18000.
GLOBAL COAST_WARP_3D_LIMIT IS 64800.
GLOBAL COAST_WARP_10D_LIMIT IS 216000.
GLOBAL COAST_WARP_50D_LIMIT IS 1080000.
GLOBAL COAST_WARP_MAX_RATE IS 6.

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
    RETURN LEXICON().
}

GLOBAL FUNCTION phaseBandForPhase {
    PARAMETER phaseName.
    LOCAL phase IS phaseName.
    LOCAL defaultBand IS "".
    IF phase = "" OR phase:CONTAINS("MAIN") {
        SET defaultBand TO "LAUNCH".
    }
    RETURN bootLibBandForPhase(phase, defaultBand).
}

GLOBAL FUNCTION phaseBand {
    RETURN phaseBandForPhase(stateGet("phase", "")).
}

GLOBAL FUNCTION phaseInLoadedBand {
    PARAMETER phaseName.
    LOCAL requiredBand IS phaseBandForPhase(phaseName).
    RETURN requiredBand <> "" AND requiredBand = stateGet("lib_band", "").
}

GLOBAL FUNCTION phaseParkingReload {
    phaseParking().
    LOCAL nxt IS stateGet("phase", "").
    IF phaseInLoadedBand(nxt) {
        mLog("Parking checkpoint: " + nxt + " already loaded - continuing.").
        RETURN.
    }
    LOCAL requiredBand IS phaseBandForPhase(nxt).
    stateSaveReloadState("PARKING_ORBIT", nxt, requiredBand).
    mLog("Parking orbit reload point - auto-rebooting for " + nxt + ".").
    HUDTEXT("Parking orbit: rebooting for " + nxt + "...",
        5, 2, 15, CYAN, FALSE).
    WAIT 5.
    REBOOT.
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
                dependencyBindPhase(phaseMap, phase).
                IF phaseMap:HASKEY(phase) {
                    phaseMap[phase]:CALL().
                    IF phaseShouldYield { RETURN. }
                } ELSE {
                    mLogError("Phase " + phase + " handler missing in loaded band " + loadedBand + ".").
                    PRINT " ".
                    PRINT "  PHASE HANDLER MISSING: " + phase.
                    PRINT "  Loaded band: " + loadedBand + ".".
                    PRINT "  Check dependencies.ks and loaded libraries.".
                    yieldToPrompt().
                    RETURN.
                }
            } ELSE {
                stateSaveReloadState("PHASE_BAND_CHANGE", phase, requiredBand).
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

GLOBAL FUNCTION maneuverEnsureBurnAlarm {
    PARAMETER burnStartUt.
    PARAMETER burnDv.
    PARAMETER label.
    PARAMETER leadSeconds IS 60.
    LOCAL alarmUt IS burnStartUt - leadSeconds.
    IF alarmUt <= TIME:SECONDS { RETURN "". }
    LOCAL alarmId IS kacEnsureAlarm(label + ": " + SHIP:NAME,
        alarmUt,
        "dV " + ROUND(burnDv,1) + "m/s. Auto-created by maneuver planner.").
    IF alarmId <> "" {
        mLog("KAC alarm set for " + label + " in "
            + ROUND(alarmUt - TIME:SECONDS, 0) + "s.").
    }
    RETURN alarmId.
}

GLOBAL FUNCTION warpHoldEnabled {
    RETURN KEEP_WARP > 0.
}

GLOBAL FUNCTION warpKacGuarded {
    PARAMETER alarmId IS "".
    PARAMETER label IS "warp".

    IF NOT ADDONS:KAC:AVAILABLE {
        mLogWarn(label + ": warp skipped; KAC unavailable.").
        RETURN FALSE.
    }
    IF alarmId <> "" {
        FOR a IN LISTALARMS("All") {
            IF a:ID = alarmId { RETURN TRUE. }
        }
        mLogWarn(label + ": warp skipped; KAC alarm missing.").
        RETURN FALSE.
    }
    FOR a IN LISTALARMS("All") {
        IF a:TIME > TIME:SECONDS { RETURN TRUE. }
    }
    mLogWarn(label + ": warp skipped; no future KAC alarm set.").
    RETURN FALSE.
}

GLOBAL FUNCTION setWarpWithKac {
    PARAMETER warpRate.
    PARAMETER label IS "warp".
    PARAMETER alarmId IS "".

    IF warpRate <= 0 {
        SET WARP TO 0.
        RETURN TRUE.
    }
    IF NOT warpKacGuarded(alarmId, label) { RETURN FALSE. }
    SET WARP TO warpRate.
    RETURN TRUE.
}

GLOBAL FUNCTION idealCoastWarpRate {
    PARAMETER waitSeconds.
    LOCAL remaining IS MAX(0, waitSeconds).
    LOCAL maxRate IS MIN(6, MAX(0, COAST_WARP_MAX_RATE)).

    IF remaining < COAST_AUTO_WARP_MIN { RETURN 0. }
    IF remaining < COAST_WARP_5M_LIMIT { RETURN MIN(maxRate, 2). }
    IF remaining <= COAST_WARP_5H_LIMIT { RETURN MIN(maxRate, 3). }
    IF remaining < COAST_WARP_3D_LIMIT { RETURN MIN(maxRate, 4). }
    IF remaining < COAST_WARP_10D_LIMIT { RETURN MIN(maxRate, 5). }
    IF remaining < COAST_WARP_50D_LIMIT { RETURN MIN(maxRate, 6). }
    RETURN MIN(maxRate, 6).
}

GLOBAL FUNCTION coastAutoWarp {
    PARAMETER endUt.
    PARAMETER label IS "coast".
    PARAMETER alarmId IS "".

    LOCAL waitSeconds IS MAX(0, endUt - TIME:SECONDS).
    IF COAST_AUTO_WARP > 0 AND waitSeconds >= COAST_AUTO_WARP_MIN {
        LOCAL warpRate IS idealCoastWarpRate(waitSeconds).
        IF warpRate > 0
                AND setWarpWithKac(warpRate, label + " auto-warp", alarmId) {
            mLog(label + ": auto-warp " + warpRate
                + " for " + ROUND(waitSeconds, 0) + "s.").
        }
    }
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

GLOBAL FUNCTION tryCommandCoreHibernate {
    PARAMETER enabled.
    IF (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING"
            OR SHIP:STATUS = "SUB_ORBITAL")
            AND DEFINED BOOT_LIB_RAN
            AND BOOT_LIB_RAN:CONTAINS("solar") {
        commandCoresHibernate(enabled).
    }
}

GLOBAL FUNCTION phaseDone {
    UNLOCK ALL.
    mLog("Mission complete: " + SHIP:NAME).
    HUDTEXT("Mission Complete", 10, 2, 20, GREEN, FALSE).
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        SAS OFF.
        mLog("DONE: surface state detected (" + SHIP:STATUS
            + ") — leaving attitude control idle.").
        yieldToPrompt().
        RETURN.
    }

    SET SAS TO TRUE.
    // On-station ships hold their best solar attitude through
    // DONE (cached axis makes this a quick aim, not a search).
    // PHASE DONE = solar brings the lib along at DONE boots.
    trySolarOrient().
    yieldToPrompt().
}
