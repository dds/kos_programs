// ============================================================
// scansat.ks  —  SCANsat payload CPU role  (0:/roles/scansat.ks)
//
// Set CORE:TAG = "scansat" on the SCANsat probe core in the VAB.
// The stage2 core (CORE:TAG = "stage2", no matching roles/ script)
// falls back to craft/FR3C.ks and flies the full mission.
//
// Pre-separation: this role stays completely dormant — no STEERING
// or THROTTLE — while both cores are on the same vessel. Separation
// is detected by the "scansat_decoupler" part tag disappearing from
// SHIP:PARTS (it stays with the stage side after decouple).
//
// Post-separation: starts the SCANsat scanners, holds best measured
// solar attitude, and waits for the operator deorbit signal. When
// cmd/scansatdeorbit.ks is run (which sets scansat_deorbit_requested),
// burns retrograde to Pe < 40 km and idles until re-entry.
// ============================================================

GLOBAL CFG IS LEXICON().

GLOBAL FUNCTION bootVehicleLibs {
    RETURN LIST("logs", "state", "solar", "science").
}

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FR3C",
    "keepCmds", LIST("DUMP", "SETPHASE")
).

GLOBAL FUNCTION main {
    IF stateGet("scansat_deorbit_complete", "false") = "true" {
        mLog("Scansat: deorbit complete. Idling.").
        WAIT UNTIL FALSE.
        RETURN.
    }

    // Dormant while on the combined vessel; decoupler tag on stage side
    // disappears from our SHIP:PARTS the moment the stage separates.
    IF SHIP:PARTSTAGGED("scansat_decoupler"):LENGTH > 0 {
        mLog("Scansat CPU: standing by. Waiting for stage separation.").
        WAIT UNTIL SHIP:PARTSTAGGED("scansat_decoupler"):LENGTH = 0.
        mLog("Scansat: stage separated. Taking control.").
        WAIT 2.
    }

    // On-station setup (idempotent across reboots while scanning).
    scienceStartScanners().
    WAIT 1.
    scienceScanStatus().
    orientForSolar().
    mLogWarn("STATS scansat on-station PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " incDeg=" + ROUND(SHIP:ORBIT:INCLINATION,1)).
    HUDTEXT("SCANsat on station. Run cmd/scansatdeorbit when done.", 10, 2, 14, GREEN, FALSE).

    IF stateGet("scansat_deorbit_requested", "false") <> "true" {
        mLog("Scansat: scanning. Waiting for scansat_deorbit_requested state.").
        UNTIL stateGet("scansat_deorbit_requested", "false") = "true" {
            orientForSolar().
            WAIT 300.
        }
    }

    mLog("Scansat: deorbit requested. Starting deorbit.").
    _doDeorbit().
}

LOCAL FUNCTION _doDeorbit {
    IF SHIP:PERIAPSIS < 40000 {
        mLog("Scansat: already below 40 km Pe (" + ROUND(SHIP:PERIAPSIS/1000,1) + " km). Idling.").
        stateSet("scansat_deorbit_complete", "true").
        WAIT UNTIL FALSE.
        RETURN.
    }

    mLogWarn("STATS scansat-deorbit setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " availThrustKN=" + ROUND(SHIP:AVAILABLETHRUST,1)).

    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogError("Scansat: no thrust — cannot deorbit. Check engines/RCS.").
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
    mLog("Scansat: aligned (" + ROUND(VANG(SHIP:FACING:FOREVECTOR, SHIP:RETROGRADE:FOREVECTOR),1) + " deg). Burning.").

    LOCK THROTTLE TO 1.
    LOCAL maxTime IS 300.
    UNTIL SHIP:PERIAPSIS < 40000
            OR SHIP:AVAILABLETHRUST <= 0
            OR TIME:SECONDS - startT > maxTime {
        LOCK STEERING TO RETROGRADE.
        WAIT 0.1.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    LOCAL finalStatus IS "complete".
    IF SHIP:PERIAPSIS >= 40000 AND SHIP:AVAILABLETHRUST <= 0 {
        SET finalStatus TO "out-of-thrust".
    } ELSE IF SHIP:PERIAPSIS >= 40000 {
        SET finalStatus TO "timeout".
    }

    mLogWarn("STATS scansat-deorbit result status=" + finalStatus
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " durationS=" + ROUND(TIME:SECONDS - startT,1)).

    stateSet("scansat_deorbit_complete", "true").
    mLog("Scansat: deorbit burn complete. Idling until re-entry.").
    WAIT UNTIL FALSE.
}
