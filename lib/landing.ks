// ============================================================
// landing.ks  —  Powered descent + landing  (0:/lib/landing.ks)
//
// Suicide burn approach for airless bodies (Mun, Minmus).
// Does NOT handle atmospheric landings.
//
// Phases:
//   1. Deorbit burn — retrograde to drop Pe to ~5km above target
//   2. Coast — wait for descent
//   3. Suicide burn — continuous throttle to zero out velocity at surface
//   4. Final approach — slow vertical descent last 100m
//   5. Touchdown — detect landing, shutdown
//   6. Abort — at any point, full throttle + climb to safe alt
//
// Usage:
//   RUNPATH("1:/lib/landing.ks").
//   landingExecute().   -- runs full sequence from current orbit
//   landingAbort().     -- call from WHEN trigger for emergency abort
//
// Requires: maneuver.ks, orbit.ks, logs.ks loaded first.
// ============================================================

// ── Config ─────────────────────────────────────────────────
GLOBAL LANDING_CFG IS LEXICON(
    "DEORBIT_PE",       5000,   // m — deorbit Pe target above surface
    "FINAL_ALT",         100,   // m radar alt — switch to final approach
    "FINAL_SPEED",       5.0,   // m/s — target descent speed in final
    "TOUCHDOWN_SPEED",   1.5,   // m/s — acceptable touchdown vertical speed
    "ABORT_ALT",       10000,   // m — abort climb target altitude
    "HOVER_THROTTLE",    0.35,  // rough throttle for hover — tune per TWR
    "BURN_LEAD",         5.0,   // s — start suicide burn this many seconds early
    "MAX_TILT",         10.0    // degrees — max tilt during descent before abort
).

GLOBAL landingAbortFlag IS FALSE.

// ── Main entry ─────────────────────────────────────────────
GLOBAL FUNCTION landingExecute {
    mLogPhase("LANDING").
    SET landingAbortFlag TO FALSE.

    // Abort trigger — tilt monitor
    WHEN ABS(SHIP:FACING:PITCH) > LANDING_CFG["MAX_TILT"]
            OR ABS(SHIP:FACING:ROLL) > LANDING_CFG["MAX_TILT"] THEN {
        IF NOT landingAbortFlag {
            mLogWarn("Excessive tilt during descent — auto abort.").
            landingAbort().
        }
    }

    _landDeorbit().
    IF landingAbortFlag { RETURN. }
    _landCoast().
    IF landingAbortFlag { RETURN. }
    _landSuicideBurn().
    IF landingAbortFlag { RETURN. }
    _landFinal().
    IF landingAbortFlag { RETURN. }
    _landTouchdown().
}

GLOBAL FUNCTION landingAbort {
    SET landingAbortFlag TO TRUE.
    LOCK THROTTLE TO 1.0.
    LOCK STEERING TO SHIP:UP.
    mLogError("LANDING ABORT — climbing to " + ROUND(LANDING_CFG["ABORT_ALT"]/1000,0) + "km.").
    HUDTEXT("ABORT — CLIMBING!", 5, 2, 18, RED, FALSE).
    WAIT UNTIL SHIP:VERTICALSPEED > 0 AND ALT:RADAR > LANDING_CFG["ABORT_ALT"].
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLog("Abort climb complete. Alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
}

// ── Phase 1: Deorbit burn ──────────────────────────────────
LOCAL FUNCTION _landDeorbit {
    mLog("Planning deorbit burn. Target Pe=" + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + "km.").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planLowerPe(LANDING_CFG["DEORBIT_PE"]).
    executeManeuver().
    orbitSummary().
}

// ── Phase 2: Coast to suicide burn point ──────────────────
LOCAL FUNCTION _landCoast {
    SET SAS TO TRUE.
    UNLOCK STEERING.
    mLog("Coasting to suicide burn point...").
    HUDTEXT("Coasting — descent in progress", 3, 2, 13, WHITE, FALSE).

    // Point retrograde during coast to prep for burn
    LOCK STEERING TO SHIP:RETROGRADE.

    // Wait until we need to start braking
    // Burn start: time when we need full throttle to stop before surface
    WAIT UNTIL _suicideBurnAlt() >= ALT:RADAR - (LANDING_CFG["BURN_LEAD"] * ABS(SHIP:VERTICALSPEED)).
    mLog("Suicide burn point reached. Alt=" + ROUND(ALT:RADAR,0) + "m"
        + "  vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s").
}

// ── Phase 3: Suicide burn ──────────────────────────────────
LOCAL FUNCTION _landSuicideBurn {
    mLog("Suicide burn start.").
    HUDTEXT("SUICIDE BURN", 3, 2, 16, YELLOW, FALSE).
    LOCK STEERING TO SHIP:RETROGRADE.

    UNTIL ALT:RADAR <= LANDING_CFG["FINAL_ALT"] OR landingAbortFlag {
        LOCAL maxAcc IS SHIP:MAXTHRUST / SHIP:MASS.
        IF maxAcc > 0 {
            // Throttle to cancel vertical speed, targeting zero at surface
            LOCAL targetDecel IS (SHIP:VERTICALSPEED^2) / (2 * ALT:RADAR).
            LOCAL throttle IS targetDecel / maxAcc.
            LOCK THROTTLE TO MAX(0.05, MIN(1.0, throttle)).
        }

        // Staging if needed
        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
        }

        WAIT 0.05.
    }

    mLog("Suicide burn complete. Alt=" + ROUND(ALT:RADAR,0) + "m"
        + "  vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s").
}

// ── Phase 4: Final approach ────────────────────────────────
LOCAL FUNCTION _landFinal {
    mLog("Final approach. Target descent " + LANDING_CFG["FINAL_SPEED"] + "m/s.").
    HUDTEXT("Final approach", 3, 2, 14, GREEN, FALSE).
    LOCK STEERING TO SHIP:UP.

    UNTIL ALT:RADAR < 5 OR landingAbortFlag {
        // Cancel horizontal velocity
        LOCAL hVel IS SHIP:VELOCITY:SURFACE - (VDOT(SHIP:VELOCITY:SURFACE, SHIP:UP) * SHIP:UP).
        IF hVel:MAG > 0.5 {
            LOCK STEERING TO (-hVel):NORMALIZED.
        } ELSE {
            LOCK STEERING TO SHIP:UP.
        }

        // Throttle to hold target descent speed
        LOCAL vspd IS SHIP:VERTICALSPEED.
        LOCAL error IS -LANDING_CFG["FINAL_SPEED"] - vspd.  // want -FINAL_SPEED (descending)
        LOCAL maxAcc IS SHIP:MAXTHRUST / SHIP:MASS.
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
    mLog("Touchdown imminent.").
    // Cut throttle just before surface
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    // Wait for gear contact
    WAIT UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" OR landingAbortFlag.
    IF NOT landingAbortFlag {
        mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
            + "  lat=" + ROUND(SHIP:LATITUDE,4)
            + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
        HUDTEXT("TOUCHDOWN!", 8, 2, 20, GREEN, FALSE).
        stateSet("landing_lat", SHIP:LATITUDE).
        stateSet("landing_lng", SHIP:LONGITUDE).
    }
}

// ── Helpers ────────────────────────────────────────────────
LOCAL FUNCTION _suicideBurnAlt {
    // Minimum altitude needed to decelerate from current speed to zero
    LOCAL maxAcc IS SHIP:MAXTHRUST / SHIP:MASS.
    IF maxAcc <= 0 { RETURN 0. }
    LOCAL vspd IS ABS(SHIP:VERTICALSPEED).
    RETURN (vspd^2) / (2 * maxAcc).
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}
