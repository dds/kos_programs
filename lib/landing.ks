// ============================================================
// landing.ks  —  Powered descent + landing  (0:/lib/landing.ks)
// ============================================================

GLOBAL LANDING_CFG IS LEXICON(
    "DEORBIT_PE",        5000,
    "FINAL_ALT",          100,
    "FINAL_SPEED",        5.0,
    "TOUCHDOWN_SPEED",    1.5,
    "ABORT_ALT",        10000,
    "HOVER_THROTTLE",    0.35,
    "BURN_LEAD",          3.0,
    "MAX_TILT",          10.0,
    "USE_KE",            TRUE,
    "TARGET_LAT",           0,
    "TARGET_LNG",           0,
    "TARGET_BODY",         "",
    "ASSIST_TARGET_SPEED", 80.0,
    "ASSIST_MIN_ALT",      800,
    "ASSIST_THROTTLE",       1,
    "ASSIST_DECOUPLER_TAG", "landing_assist_decoupler",
    "ASSIST_FLYAWAY",     FALSE,
    "ASSIST_FLYAWAY_TIME", 4.0,
    "ASSIST_FLYAWAY_THROTTLE", 0.6
).

GLOBAL landingAbortFlag IS FALSE.

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

    WHEN (ABS(SHIP:FACING:PITCH) > LANDING_CFG["MAX_TILT"]
            OR ABS(SHIP:FACING:ROLL) > LANDING_CFG["MAX_TILT"])
            AND SHIP:ALTITUDE < 50000 THEN {
        IF NOT landingAbortFlag {
            mLogWarn("Excessive tilt — auto abort.").
            landingAbort().
        }
    }

    IF SHIP:ORBIT:BODY:ATM:EXISTS {
        WHEN SHIP:AIRSPEED < 100 AND ALT:RADAR < 20000 THEN {
            _deployAntennas().
            mLog("Antennas deployed — airspeed safe.").
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

// Use an attached descent stage for the early landing burn, then release it.
// Intended sequence:
//   LAND_DEORBIT -> LAND_ASSIST -> LAND
//
// The stage slows the stack while pointed retrograde until surface speed
// is below ASSIST_TARGET_SPEED, or until ASSIST_MIN_ALT forces separation.
// After decoupling, this CPU may still be on the assist stage; if so, the
// flyaway burn points sideways/up to avoid the lander before impact.
GLOBAL FUNCTION landingAssistStage {
    mLogPhase("LANDING ASSIST").

    LOCAL decoupler IS _taggedDecoupler(LANDING_CFG["ASSIST_DECOUPLER_TAG"]).
    IF decoupler = 0 {
        mLogWarn("No assist decoupler tagged '"
            + LANDING_CFG["ASSIST_DECOUPLER_TAG"] + "' — skipping assist.").
        RETURN FALSE.
    }

    SET SAS TO FALSE.
    LOCK STEERING TO SHIP:RETROGRADE.
    mLog("Assist burn: target speed " + LANDING_CFG["ASSIST_TARGET_SPEED"]
        + "m/s, min alt " + LANDING_CFG["ASSIST_MIN_ALT"] + "m.").
    HUDTEXT("Assist descent burn", 3, 2, 14, YELLOW, FALSE).

    UNTIL SHIP:VELOCITY:SURFACE:MAG <= LANDING_CFG["ASSIST_TARGET_SPEED"]
            OR ALT:RADAR <= LANDING_CFG["ASSIST_MIN_ALT"]
            OR _needsStage() {
        LOCK THROTTLE TO LANDING_CFG["ASSIST_THROTTLE"].
        HUDTEXT("Assist v:" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
            + "m/s alt:" + ROUND(ALT:RADAR,0) + "m",
            1, 2, 13, YELLOW, FALSE).
        WAIT 0.05.
    }

    LOCK THROTTLE TO 0.
    WAIT 0.2.
    mLog("Assist cutoff: speed=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + "m/s alt=" + ROUND(ALT:RADAR,0) + "m.").

    _decouplePart(decoupler).
    WAIT 0.5.

    IF LANDING_CFG["ASSIST_FLYAWAY"] {
        mLog("Assist flyaway burn.").
        LOCK STEERING TO (SHIP:FACING:RIGHTVECTOR + SHIP:UP):NORMALIZED.
        WAIT 1.
        LOCK THROTTLE TO LANDING_CFG["ASSIST_FLYAWAY_THROTTLE"].
        WAIT LANDING_CFG["ASSIST_FLYAWAY_TIME"].
        LOCK THROTTLE TO 0.
    }

    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    RETURN TRUE.
}

LOCAL FUNCTION _landDeorbit {
    IF SHIP:PERIAPSIS <= LANDING_CFG["DEORBIT_PE"] {
        mLog("Already suborbital (Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km) — skipping deorbit.").
        RETURN.
    }
    mLog("Planning deorbit. Target Pe="
        + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + "km.").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planLowerPe(LANDING_CFG["DEORBIT_PE"]).
    executeManeuver().
    orbitSummary().
}

LOCAL FUNCTION _landCoast {
    PARAMETER useKE.

    SET SAS TO TRUE.
    LOCK STEERING TO SHIP:RETROGRADE.
    mLog("Coasting to suicide burn point...").
    HUDTEXT("Coasting to burn point", 3, 2, 13, WHITE, FALSE).

    IF useKE {
        mLog("Using KerbalEngineer suicide burn countdown.").
        WAIT UNTIL ADDONS:KE:SUICIDEBURNCOUNTDOWN <= LANDING_CFG["BURN_LEAD"]
                OR landingAbortFlag.
        mLog("KE burn countdown reached. Alt=" + ROUND(ALT:RADAR,0)
            + "m  countdown=" + ROUND(ADDONS:KE:SUICIDEBURNCOUNTDOWN,1) + "s"
            + "  burnLength=" + ROUND(ADDONS:KE:SUICIDEBURNLENGTH,1) + "s"
            + "  burnDv=" + ROUND(ADDONS:KE:SUICIDEBURNDELTAV,1) + "m/s").
    } ELSE {
        mLog("Using manual suicide burn calculation.").
        WAIT UNTIL ALT:RADAR <= _manualBurnAlt()
                OR landingAbortFlag.
        mLog("Manual burn point reached. Alt=" + ROUND(ALT:RADAR,0) + "m").
    }
}

LOCAL FUNCTION _landSuicideBurn {
    PARAMETER useKE.

    mLog("Suicide burn start.").
    HUDTEXT("SUICIDE BURN", 3, 2, 16, YELLOW, FALSE).
    LOCK STEERING TO SHIP:RETROGRADE.

    UNTIL ALT:RADAR <= LANDING_CFG["FINAL_ALT"] OR landingAbortFlag {
        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
        }

        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            IF useKE AND ADDONS:KE:AVAILABLE {
                LOCAL remaining IS ADDONS:KE:SUICIDEBURNDELTAV.
                LOCAL ratio     IS remaining / (maxAcc * ADDONS:KE:SUICIDEBURNLENGTH).
                LOCK THROTTLE TO MAX(0.05, MIN(1.0, ratio)).
            } ELSE {
                LOCAL targetDecel IS (SHIP:VERTICALSPEED^2) / (2 * ALT:RADAR).
                LOCK THROTTLE TO MAX(0.05, MIN(1.0, targetDecel / maxAcc)).
            }
        }

        LOCAL tDV IS "".
        IF (useKE AND ADDONS:KE:AVAILABLE) {
           SET tDV  TO "  dV:" + ROUND(ADDONS:KE:SUICIDEBURNDELTAV, 1).
        }
        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s" + tDV,
            1, 2, 13, YELLOW, FALSE).

        WAIT 0.05.
    }

    mLog("Suicide burn complete. Alt=" + ROUND(ALT:RADAR,0)
        + "m  vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s").
}

LOCAL FUNCTION _landFinal {
    LOCAL legs IS SHIP:MODULESNAMED("ModuleWheelDeployment").
    LOCAL legsMLD IS SHIP:MODULESNAMED("ModuleLandingLeg").
    FOR m IN legsMLD { legs:ADD(m). }
    IF legs:LENGTH > 0 {
        FOR m IN legs {
            IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
        }
        mLog("Landing legs deployed.").
    }

    mLog("Final approach. Target descent "
        + LANDING_CFG["FINAL_SPEED"] + "m/s.").
    HUDTEXT("Final approach", 3, 2, 14, GREEN, FALSE).

    UNTIL ALT:RADAR < 5 OR landingAbortFlag {
        LOCAL hVel IS SHIP:VELOCITY:SURFACE
            - (VDOT(SHIP:VELOCITY:SURFACE, SHIP:UP) * SHIP:UP).
        IF hVel:MAG > 0.5 {
            LOCK STEERING TO (-hVel):NORMALIZED.
        } ELSE {
            LOCK STEERING TO SHIP:UP.
        }

        LOCAL vspd  IS SHIP:VERTICALSPEED.
        LOCAL error IS -LANDING_CFG["FINAL_SPEED"] - vspd.
        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            LOCAL thrott IS LANDING_CFG["HOVER_THROTTLE"] + (error * 0.1).
            LOCK THROTTLE TO MAX(0, MIN(1.0, thrott)).
        }

        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s", 1, 2, 13, GREEN, FALSE).
        WAIT 0.05.
    }
}

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
        _deployAntennas().
        _deploySolarPanels().
    }
}

GLOBAL FUNCTION landingTargetedDeorbit {
    IF LANDING_CFG["TARGET_LAT"] = 0 AND LANDING_CFG["TARGET_LNG"] = 0 {
        mLog("No landing target set — using blind deorbit.").
        RETURN.
    }
    SET CFG["PROBE_TARGET_LAT"] TO LANDING_CFG["TARGET_LAT"].
    SET CFG["PROBE_TARGET_LNG"] TO LANDING_CFG["TARGET_LNG"].
    SET CFG["PROBE_ENTRY_PE"] TO LANDING_CFG["DEORBIT_PE"].
    SET CFG["PROBE_TARGET_TOL"] TO 5000.
    targetedDeorbit().
}

LOCAL FUNCTION _deployAntennas {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableAntenna") {
        IF m:HASEVENT("Extend Antenna") { m:DOEVENT("Extend Antenna"). }
    }
}

LOCAL FUNCTION _deploySolarPanels {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
        IF m:HASEVENT("Extend Solar Panel") { m:DOEVENT("Extend Solar Panel"). }
    }
}

LOCAL FUNCTION _taggedDecoupler {
    PARAMETER tagName.
    LOCAL parts IS SHIP:PARTSTAGGED(tagName).
    IF parts:LENGTH = 0 { RETURN 0. }
    RETURN parts[0].
}

LOCAL FUNCTION _decouplePart {
    PARAMETER partRef.
    IF partRef:HASMODULE("ModuleDecouple") {
        partRef:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF partRef:HASMODULE("ModuleAnchoredDecoupler") {
        partRef:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogWarn("Assist decoupler tag found, but no decouple module. Trying STAGE.").
        STAGE.
    }
}

LOCAL FUNCTION _manualBurnAlt {
    LOCAL maxAcc IS _safeMaxAcc().
    IF maxAcc <= 0 { RETURN 0. }
    RETURN (SHIP:VERTICALSPEED^2) / (2 * maxAcc).
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}
