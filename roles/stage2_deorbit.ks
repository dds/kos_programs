// ============================================================
// stage2_deorbit.ks - Autonomous second-stage return role
// (0:/roles/stage2_deorbit.ks)
//
// Set CORE:TAG = "stage2_deorbit" on the second-stage probe core
// in the VAB. The main mission CPU lives on the payload and flies
// the full mission. This role stays
// completely dormant - never touches STEERING or THROTTLE - while
// both cores are on the same vessel.
//
// Separation is detected by a >= 0.15 t mass drop once the orbit
// is above 220 km Pe; after 30 s of clearance it runs the standard
// KSC_DEORBIT + DESCENT return sequence for the spent stage.
//
// Manual override if auto-detection fails:
//   RUNPATH("0:/cmd/stage2deorbit.ks").
// ============================================================

SET DESCENT_DECOUPLER_TAG TO "none".

applyKnownMissionState().

GLOBAL FUNCTION bootVehicleLibs {
    RETURN LIST("deorbit_targeting", "descent", "solar").
}

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FR3C"
).

GLOBAL FUNCTION main {
    IF stateGet("stage2_deorbit_complete", "false") = "true" {
        mLog("Stage2: return complete. Idling.").
        WAIT UNTIL FALSE.
        RETURN.
    }

    IF stateGet("stage2_separation_detected", "false") = "true" {
        mLog("Stage2: resuming post-separation KSC return.").
        _doReturn().
        RETURN.
    }

    mLog("Stage2 deorbit CPU: standing by. Not touching controls.").
    mLog("Waiting for Pe > 220 km then a >= 0.15 t mass drop.").

    WAIT UNTIL SHIP:PERIAPSIS > 220000.

    LOCAL baseMass IS SHIP:MASS.
    mLogWarn("STATS stage2-deorbit setup baseMassT=" + ROUND(baseMass,3)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    mLog("Stage2: in target orbit. Baseline " + ROUND(baseMass,3) + " t.").

    WAIT UNTIL SHIP:MASS < baseMass - 0.15.

    mLogWarn("STATS stage2-deorbit separation-detected massT=" + ROUND(SHIP:MASS,3)
        + " dropT=" + ROUND(baseMass - SHIP:MASS,3)).
    mLog("Stage2: payload released - " + ROUND(baseMass - SHIP:MASS,3) + " t drop.").
    stateSet("stage2_separation_detected", "true").

    WAIT 30.
    _doReturn().
}

LOCAL FUNCTION _doReturn {
    LOCAL returnSeq IS LIST("KSC_DEORBIT", "DESCENT", "DONE").
    SET xferSeq TO returnSeq.
    SET launchSeq TO returnSeq.
    LOCAL ph IS stateGet("phase", "").
    IF ph <> "KSC_DEORBIT" AND ph <> "DESCENT" AND ph <> "DONE" {
        stateSet("phase", "KSC_DEORBIT").
    }
    mLog("Stage2: starting KSC return sequence.").
    runPhases(LEXICON()).
    IF stateGet("phase", "") = "DONE" {
        stateSet("stage2_deorbit_complete", "true").
        mLog("Stage2: KSC return sequence complete. Idling.").
        WAIT UNTIL FALSE.
    }
}
