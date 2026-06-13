// ============================================================
// stage2_deorbit.ks — Autonomous second-stage deorbit role
// (0:/roles/stage2_deorbit.ks)
//
// Set CORE:TAG = "stage2_deorbit" on the second-stage probe core
// in the VAB. The main mission CPU (CORE:TAG = "") lives on the
// SCANsat payload and flies the full mission. This role stays
// completely dormant — never touches STEERING or THROTTLE — while
// both cores are on the same vessel.
//
// Separation is detected by a ≥ 0.15 t mass drop once the orbit
// is above 220 km Pe; after 30 s of clearance it burns retrograde
// until Pe < 30 km, then idles until re-entry.
//
// Manual override if auto-detection fails:
//   RUNPATH("0:/cmd/stage2deorbit.ks").
// ============================================================

GLOBAL CFG IS LEXICON().

GLOBAL FUNCTION bootVehicleLibs {
    RETURN LIST("logs", "state", "solar").
}

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FR3C",
    "keepCmds", LIST("DUMP", "SETPHASE")
).

GLOBAL FUNCTION main {
    IF stateGet("stage2_deorbit_complete", "false") = "true" {
        mLog("Stage2: deorbit complete. Idling until re-entry.").
        WAIT UNTIL FALSE.
        RETURN.
    }

    IF stateGet("stage2_separation_detected", "false") = "true" {
        mLog("Stage2: resuming post-separation deorbit.").
        _doDeorbit().
        RETURN.
    }

    mLog("Stage2 deorbit CPU: standing by. Not touching controls.").
    mLog("Waiting for Pe > 220 km then a ≥ 0.15 t mass drop.").

    WAIT UNTIL SHIP:PERIAPSIS > 220000.

    LOCAL baseMass IS SHIP:MASS.
    mLogWarn("STATS stage2-deorbit setup baseMassT=" + ROUND(baseMass,3)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    mLog("Stage2: in target orbit. Baseline " + ROUND(baseMass,3) + " t.").

    WAIT UNTIL SHIP:MASS < baseMass - 0.15.

    mLogWarn("STATS stage2-deorbit separation-detected massT=" + ROUND(SHIP:MASS,3)
        + " dropT=" + ROUND(baseMass - SHIP:MASS,3)).
    mLog("Stage2: payload released — " + ROUND(baseMass - SHIP:MASS,3) + " t drop.").
    stateSet("stage2_separation_detected", "true").

    WAIT 30.
    _doDeorbit().
}

LOCAL FUNCTION _doDeorbit {
    IF SHIP:PERIAPSIS < 30000 {
        mLog("Stage2: already on deorbit trajectory (Pe="
            + ROUND(SHIP:PERIAPSIS/1000,1) + " km). Idling.").
        stateSet("stage2_deorbit_complete", "true").
        orientForSolar().
        WAIT UNTIL FALSE.
        RETURN.
    }

    mLogWarn("STATS stage2-deorbit burn-setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " availThrustKN=" + ROUND(SHIP:AVAILABLETHRUST,1)).

    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogError("Stage2: no thrust — cannot deorbit. Run cmd/stage2deorbit manually.").
        WAIT UNTIL FALSE.
        RETURN.
    }

    SET SAS TO FALSE.
    LOCK STEERING TO RETROGRADE.
    LOCAL startT IS TIME:SECONDS.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, SHIP:RETROGRADE:FOREVECTOR) < 5
            OR TIME:SECONDS - startT > 60 {
        WAIT 0.1.
    }
    mLog("Stage2: aligned (" + ROUND(VANG(SHIP:FACING:FOREVECTOR, SHIP:RETROGRADE:FOREVECTOR),1) + "° off). Burning.").

    LOCK THROTTLE TO 1.
    UNTIL SHIP:PERIAPSIS < 30000
            OR SHIP:AVAILABLETHRUST <= 0
            OR TIME:SECONDS - startT > 600 {
        LOCK STEERING TO RETROGRADE.
        WAIT 0.1.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    LOCAL finalStatus IS "complete".
    IF SHIP:PERIAPSIS >= 30000 AND SHIP:AVAILABLETHRUST <= 0 {
        SET finalStatus TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS >= 30000 {
        SET finalStatus TO "timeout".
    }

    mLogWarn("STATS stage2-deorbit result status=" + finalStatus
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " durationS=" + ROUND(TIME:SECONDS - startT,1)).

    stateSet("stage2_deorbit_complete", "true").
    orientForSolar().
    mLog("Stage2: deorbit complete. Idling until re-entry.").
    WAIT UNTIL FALSE.
}
