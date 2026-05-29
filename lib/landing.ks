// ============================================================
// landing.ks  —  Powered descent + landing  (0:/lib/landing.ks)
//
// Suicide burn approach for airless bodies (Mun, Minmus).
// Uses KerbalEngineer addon for accurate suicide burn timing
// if available, falls back to manual calculation otherwise.
//
// Does NOT handle atmospheric landings.
//
// Phases:
//   1. Deorbit burn — retrograde to drop Pe to ~5km above target
//   2. Coast — wait for suicide burn countdown
//   3. Suicide burn — continuous throttle to zero velocity at surface
//   4. Final approach — slow vertical descent last 100m
//   5. Touchdown — detect landing, shutdown
//   6. Abort — full throttle + climb to safe alt
//
// Usage:
//   RUNPATH("1:/lib/landing.ks").
//   landingExecute().
//   landingAbort().   -- call anytime for emergency abort
//
// Requires: maneuver.ks, orbit.ks, logs.ks loaded first.
// ============================================================

// ── Config ─────────────────────────────────────────────────
GLOBAL LANDING_CFG IS LEXICON(
    "DEORBIT_PE",        5000,  // m — deorbit Pe target above surface
    "FINAL_ALT",          100,  // m radar alt — switch to final approach
    "FINAL_SPEED",        5.0,  // m/s — target descent speed in final
    "TOUCHDOWN_SPEED",    1.5,  // m/s — acceptable touchdown vertical speed
    "ABORT_ALT",        10000,  // m — abort climb target altitude
    "HOVER_THROTTLE",    0.35,  // rough throttle for hover — tune per TWR
    "BURN_LEAD",          3.0,  // s — start burn this many seconds before KE countdown
    "MAX_TILT",          10.0,  // degrees — max tilt during descent before abort
    "USE_KE",            TRUE   // use KerbalEngineer addon if available
).

GLOBAL landingAbortFlag IS FALSE.

// ── Main entry ─────────────────────────────────────────────
GLOBAL FUNCTION landingExecute {
    mLogPhase("LANDING").
    SET landingAbortFlag TO FALSE.

    LOCAL useKE IS LANDING_CFG["USE_KE"] AND ADDONS:KE:AVAILABLE.
    LOCAL landingSystem IS "".
    IF useKE { 
        SET landingSystem TO "KerbalEngineer".
    } ELSE {
        SET landingSystem TO "manual calculation".
    }
    mLog("Landing system: " + landingSystem).

    // Tilt abort trigger
    WHEN (ABS(SHIP:FACING:PITCH) > LANDING_CFG["MAX_TILT"]
            OR ABS(SHIP:FACING:ROLL) > LANDING_CFG["MAX_TILT"])
            AND SHIP:ALTITUDE < 50000 THEN {
        IF NOT landingAbortFlag {
            mLogWarn("Excessive tilt — auto abort.").
            landingAbort().
        }
    }

    _landDeorbit().
    IF landingAbortFlag { RETURN. }
    _landCoast(useKE).
    IF landingAbortFlag { RETURN. }
    _landSuicideBurn(useKE).
    IF landingAbortFlag { RETURN. }
    _landFinal().
    IF landingAbortFlag { RETURN. }
    _landTouchdown().
}

GLOBAL FUNCTION landingAbort {
    SET landingAbortFlag TO TRUE.
    LOCK THROTTLE TO 1.0.
    LOCK STEERING TO SHIP:UP.
    mLogError("LANDING ABORT — climbing to "
        + ROUND(LANDING_CFG["ABORT_ALT"]/1000,0) + "km.").
    HUDTEXT("ABORT — CLIMBING!", 5, 2, 18, RED, FALSE).
    WAIT UNTIL SHIP:VERTICALSPEED > 0
            AND ALT:RADAR > LANDING_CFG["ABORT_ALT"].
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLog("Abort complete. Alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
}

// ── Phase 1: Deorbit ───────────────────────────────────────
LOCAL FUNCTION _landDeorbit {
    mLog("Planning deorbit. Target Pe="
        + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + "km.").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planLowerPe(LANDING_CFG["DEORBIT_PE"]).
    executeManeuver().
    orbitSummary().
}

// ── Phase 2: Coast to burn point ───────────────────────────
LOCAL FUNCTION _landCoast {
    PARAMETER useKE.

    SET SAS TO TRUE.
    LOCK STEERING TO SHIP:RETROGRADE.
    mLog("Coasting to suicide burn point...").
    HUDTEXT("Coasting to burn point", 3, 2, 13, WHITE, FALSE).

    IF useKE {
        // KE gives us exact countdown — wait until it hits BURN_LEAD seconds
        mLog("Using KerbalEngineer suicide burn countdown.").
        WAIT UNTIL ADDONS:KE:SUICIDEBURNCOUNTDOWN <= LANDING_CFG["BURN_LEAD"]
                OR landingAbortFlag.
        mLog("KE burn countdown reached. Alt=" + ROUND(ALT:RADAR,0)
            + "m  countdown=" + ROUND(ADDONS:KE:SUICIDEBURNCOUNTDOWN,1) + "s"
            + "  burnLength=" + ROUND(ADDONS:KE:SUICIDEBURNLENGTH,1) + "s"
            + "  burnDv=" + ROUND(ADDONS:KE:SUICIDEBURNDELTAV,1) + "m/s").
    } ELSE {
        // Manual: wait until altitude matches calculated burn start altitude
        mLog("Using manual suicide burn calculation.").
        WAIT UNTIL ALT:RADAR <= _manualBurnAlt()
                OR landingAbortFlag.
        mLog("Manual burn point reached. Alt=" + ROUND(ALT:RADAR,0) + "m").
    }
}

// ── Phase 3: Suicide burn ──────────────────────────────────
LOCAL FUNCTION _landSuicideBurn {
    PARAMETER useKE.

    mLog("Suicide burn start.").
    HUDTEXT("SUICIDE BURN", 3, 2, 16, YELLOW, FALSE).
    LOCK STEERING TO SHIP:RETROGRADE.

    UNTIL ALT:RADAR <= LANDING_CFG["FINAL_ALT"] OR landingAbortFlag {

        // Staging check
        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
        }

        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            IF useKE AND ADDONS:KE:AVAILABLE {
                // Use KE suicide burn dV to drive throttle
                LOCAL remaining IS ADDONS:KE:SUICIDEBURNDELTAV.
                LOCAL ratio     IS remaining / (maxAcc * ADDONS:KE:SUICIDEBURNLENGTH).
                LOCK THROTTLE TO MAX(0.05, MIN(1.0, ratio)).
            } ELSE {
                // Manual throttle based on velocity vs altitude
                LOCAL targetDecel IS (SHIP:VERTICALSPEED^2) / (2 * ALT:RADAR).
                LOCK THROTTLE TO MAX(0.05, MIN(1.0, targetDecel / maxAcc)).
            }
        }

        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
            + (IF useKE AND ADDONS:KE:AVAILABLE
                THEN "  dV:" + ROUND(ADDONS:KE:SUICIDEBURNDELTAV,1)
                ELSE ""),
            1, 2, 13, YELLOW, FALSE).

        WAIT 0.05.
    }

    mLog("Suicide burn complete. Alt=" + ROUND(ALT:RADAR,0)
        + "m  vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s").
}

// ── Phase 4: Final approach ────────────────────────────────
LOCAL FUNCTION _landFinal {
    mLog("Final approach. Target descent "
        + LANDING_CFG["FINAL_SPEED"] + "m/s.").
    HUDTEXT("Final approach", 3, 2, 14, GREEN, FALSE).

    UNTIL ALT:RADAR < 5 OR landingAbortFlag {
        // Cancel horizontal velocity
        LOCAL hVel IS SHIP:VELOCITY:SURFACE
            - (VDOT(SHIP:VELOCITY:SURFACE, SHIP:UP) * SHIP:UP).
        IF hVel:MAG > 0.5 {
            LOCK STEERING TO (-hVel):NORMALIZED.
        } ELSE {
            LOCK STEERING TO SHIP:UP.
        }

        // Hold target descent speed
        LOCAL vspd  IS SHIP:VERTICALSPEED.
        LOCAL error IS -LANDING_CFG["FINAL_SPEED"] - vspd.
        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            LOCAL throttle IS LANDING_CFG["HOVER_THROTTLE"] + (error * 0.1).
            LOCK THROTTLE TO MAX(0, MIN(1.0, throttle)).
        }

        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s", 1, 2, 13, GREEN, FALSE).
        WAIT 0.05.
    }
}

// ── Phase 5: Touchdown ─────────────────────────────────────
LOCAL FUNCTION _landTouchdown {
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    WAIT UNTIL SHIP:STATUS = "LANDED"
            OR SHIP:STATUS = "SPLASHED"
            OR landingAbortFlag.

    IF NOT landingAbortFlag {
        mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
            + "  lat=" + ROUND(SHIP:LATITUDE,4)
            + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
        HUDTEXT("TOUCHDOWN!", 8, 2, 20, GREEN, FALSE).
        stateSet("landing_lat",  SHIP:LATITUDE).
        stateSet("landing_lng",  SHIP:LONGITUDE).
        stateSet("landing_time", TIME:SECONDS).
    }
}

// ── Private helpers ────────────────────────────────────────
LOCAL FUNCTION _manualBurnAlt {
    LOCAL maxAcc IS _safeMaxAcc().
    IF maxAcc <= 0 { RETURN 0. }
    RETURN (SHIP:VERTICALSPEED^2) / (2 * maxAcc).
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}
