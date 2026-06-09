// ============================================================
// descent.ks  —  Atmospheric descent phase  (0:/lib/descent.ks)
//
// General-purpose atmospheric descent handler. Waits for
// atmosphere entry, chute deployment, safe antenna speed,
// then redeploys antennas, archives the flight log, and waits
// for landing/splashdown.
//
// Usable from:
//   - Return-to-Kerbin after AEROBRAKE
//   - Post-abort descent recovery
//   - Any mission ending with atmospheric entry
// Altitude thresholds for decoupling by body (meters).
// Below this altitude, it's safe to shed the transfer stage
// before deploying chutes.
LOCAL DECOUPLE_ALTS IS LEXICON(
    "KERBIN", 250,
    "DUNA",   8000,
    "EVE",    12000,
    "LAYTHE", 10000,
    "TEKTO",  10000
).

GLOBAL FUNCTION phaseDescent {
    mLogPhase("DESCENT").

    // LOCK STEERING retrograde for descent orientation.
    LOCAL dir IS "RETROGRADE".
    IF DEFINED CFG AND CFG:HASKEY("AEROBRAKE_REENTRY_DIR") {
        SET dir TO CFG["AEROBRAKE_REENTRY_DIR"].
    }
    SAS OFF.
    IF dir = "PROGRADE" {
        LOCK STEERING TO PROGRADE.
    } ELSE {
        LOCK STEERING TO RETROGRADE.
    }
    mLog(dir + " steering lock for descent.").

    // Wait for atmosphere entry
    IF SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT {
        mLog("Waiting for atmospheric entry...").
        WAIT UNTIL SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
        mLog("Entered atmosphere at " + ROUND(SHIP:ALTITUDE/1000, 1) + "km.").
        WAIT 5.
        _descentRetractAntennas().
    }

    // Arm chutes early so they auto-deploy at safe altitude
    _descentArmChutes().

    // TODO: Braking burn disabled — remaining dV is better spent on
    // MCC targeting KSC. Revisit when we have a proper aerobrake
    // altitude + precision landing plan.
    // _descentBrakingBurn().

    // Deploy fairing once slow enough (< 60 m/s)
    _descentDeployFairing().

    // Decouple transfer stage at safe altitude
    _descentDecouple().

    // Wait for chutes to deploy or vessel to land/splash
    mLog("Waiting for chute deployment or landing...").
    WAIT UNTIL _chutesDeployed()
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".

    IF _chutesDeployed() {
        mLog("Chutes deployed.").
    }

    // Wait for safe speed to extend antennas (< 20 m/s)
    // Deployable antennas break at higher speeds in atmosphere
    LOCAL safeSpeed IS 20.
    IF SHIP:AIRSPEED > safeSpeed {
        mLog("Waiting for safe antenna speed (< " + safeSpeed + " m/s)...").
        WAIT UNTIL SHIP:AIRSPEED < safeSpeed
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    mLog("Safe to redeploy antennas (airspeed=" + ROUND(SHIP:AIRSPEED, 1) + " m/s).").
    _descentExtendAntennas().

    // Archive flight log now that comms may be restored
    WAIT 1.
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Flight log archived.").
    }

    // Wait for landing/splashdown if still descending
    IF SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "SPLASHED" {
        mLog("Waiting for landing/splashdown...").
        WAIT UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    mLog("Touchdown: " + SHIP:STATUS + " at " + ROUND(SHIP:GEOPOSITION:LAT, 4)
        + "," + ROUND(SHIP:GEOPOSITION:LNG, 4)).
    mLogWarn("STATS descent status=landed type=" + SHIP:STATUS
        + " lat=" + ROUND(SHIP:GEOPOSITION:LAT, 4)
        + " lng=" + ROUND(SHIP:GEOPOSITION:LNG, 4)).

    // Final log archive after landing
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
    }

    UNLOCK STEERING.
    SET SAS TO TRUE.
    nextPhase(xferSeq).
}

// Check if chutes have deployed. Uses DESCENT_CHUTES_TAG if
// configured, otherwise checks all parachute parts.
LOCAL FUNCTION _chutesDeployed {
    LOCAL parts IS LIST().
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_CHUTES_TAG") {
        SET parts TO SHIP:PARTSTAGGED(CFG["DESCENT_CHUTES_TAG"]).
    } ELSE {
        FOR p IN SHIP:PARTS {
            IF p:HASMODULE("ModuleParachute") { parts:ADD(p). }
        }
    }
    FOR p IN parts {
        IF p:HASMODULE("ModuleParachute") {
            LOCAL m IS p:GETMODULE("ModuleParachute").
            // Once deployed, both "deploy chute" and "arm parachute" events disappear
            IF NOT m:HASEVENT("deploy chute") AND NOT m:HASEVENT("arm parachute") {
                RETURN TRUE.
            }
        }
    }
    RETURN FALSE.
}

// Burn any remaining fuel retrograde to help slow down during
// upper atmosphere descent. The transfer stage doubles as a
// heat shield when oriented retrograde, so we keep it attached
// and burn through it before entry heating peaks.
LOCAL FUNCTION _descentBrakingBurn {
    IF SHIP:AVAILABLETHRUST <= 0 { RETURN. }

    LOCAL fuel IS STAGE:LIQUIDFUEL + STAGE:OXIDIZER.
    IF fuel <= 0.1 {
        mLog("No fuel remaining — skipping braking burn.").
        RETURN.
    }

    mLog("Braking burn: thrust=" + ROUND(SHIP:AVAILABLETHRUST, 1)
        + "kN  fuel=" + ROUND(fuel, 1)).

    LOCK THROTTLE TO 1.
    LOCK STEERING TO RETROGRADE.

    // Burn until fuel is exhausted or we've slowed enough
    WAIT UNTIL (STAGE:LIQUIDFUEL + STAGE:OXIDIZER) <= 0.1
        OR SHIP:AVAILABLETHRUST <= 0
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".

    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.

    mLog("Braking burn complete. Speed=" + ROUND(SHIP:AIRSPEED, 1) + " m/s.").
    mLogWarn("STATS descent braking speed=" + ROUND(SHIP:AIRSPEED, 1)
        + " alt=" + ROUND(SHIP:ALTITUDE/1000, 1)).
}

// Deploy descent fairing once airspeed is below 60 m/s.
// Reads tag from DESCENT_FAIRING_TAG config key.
LOCAL FUNCTION _descentDeployFairing {
    LOCAL tag IS "".
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_FAIRING_TAG") {
        SET tag TO CFG["DESCENT_FAIRING_TAG"].
    }
    IF tag = "" { RETURN. }

    LOCAL fairings IS SHIP:PARTSTAGGED(tag).
    IF fairings:LENGTH = 0 {
        mLogWarn("Descent fairing tag '" + tag + "' not found.").
        RETURN.
    }

    LOCAL deploySpeed IS 30.
    IF SHIP:AIRSPEED > deploySpeed {
        mLog("Waiting for < " + deploySpeed + " m/s to deploy fairing...").
        WAIT UNTIL SHIP:AIRSPEED < deploySpeed
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    FOR f IN fairings {
        IF f:HASMODULE("ModuleProceduralFairing") {
            f:GETMODULE("ModuleProceduralFairing"):DOEVENT("deploy").
            mLog("Deployed fairing: " + f:TITLE + " (tag=" + tag + ")").
        }
    }
    WAIT 2.
}

// Decouple transfer stage at safe altitude.
// Uses body-specific altitude threshold from DECOUPLE_ALTS table.
// Reads tag from DESCENT_DECOUPLER_TAG config key.
LOCAL FUNCTION _descentDecouple {
    LOCAL tag IS "".
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_DECOUPLER_TAG") {
        SET tag TO CFG["DESCENT_DECOUPLER_TAG"].
    }
    IF tag = "" { RETURN. }

    LOCAL decouplers IS SHIP:PARTSTAGGED(tag).
    IF decouplers:LENGTH = 0 {
        mLogWarn("Descent decoupler tag '" + tag + "' not found.").
        RETURN.
    }

    // Wait for safe decouple altitude
    LOCAL decoupleAlt IS 6000.
    IF DECOUPLE_ALTS:HASKEY(SHIP:BODY:NAME) {
        SET decoupleAlt TO DECOUPLE_ALTS[SHIP:BODY:NAME].
    }

    IF SHIP:ALTITUDE > decoupleAlt {
        mLog("Waiting for " + ROUND(decoupleAlt/1000, 1) + "km altitude to decouple...").
        WAIT UNTIL SHIP:ALTITUDE < decoupleAlt
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    // Decouple
    FOR dc IN decouplers {
        IF dc:HASMODULE("ModuleDecouple") {
            dc:GETMODULE("ModuleDecouple"):DOEVENT("decouple").
            mLog("Decoupled: " + dc:TITLE + " (tag=" + tag + ")").
        } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
            dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("decouple").
            mLog("Decoupled: " + dc:TITLE + " (tag=" + tag + ")").
        }
    }
    WAIT 2.
    mLogWarn("STATS descent decouple alt=" + ROUND(SHIP:ALTITUDE/1000, 1)
        + " speed=" + ROUND(SHIP:AIRSPEED, 1)).
}

LOCAL FUNCTION _descentRetractAntennas {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL m IS p:GETMODULE("ModuleDeployableAntenna").
            IF m:HASEVENT("retract antenna") {
                m:DOEVENT("retract antenna").
                SET retracted TO retracted + 1.
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " antenna(s) for entry.").
        WAIT 3.
    }
}

// Arm chutes by tag (DESCENT_CHUTES_TAG, default "descent_chutes")
// or all chutes if tag yields nothing.
LOCAL FUNCTION _descentArmChutes {
    LOCAL tag IS "descent_chutes".
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_CHUTES_TAG") {
        SET tag TO CFG["DESCENT_CHUTES_TAG"].
    }

    LOCAL parts IS SHIP:PARTSTAGGED(tag).
    IF parts:LENGTH = 0 {
        mLog("No parts with tag '" + tag + "'; scanning all parts for chutes.").
        FOR p IN SHIP:PARTS {
            IF p:HASMODULE("ModuleParachute") { parts:ADD(p). }
        }
    }

    LOCAL armed IS 0.
    FOR p IN parts {
        IF p:HASMODULE("ModuleParachute") {
            LOCAL m IS p:GETMODULE("ModuleParachute").
            IF m:HASEVENT("arm parachute") {
                m:DOEVENT("arm parachute").
                SET armed TO armed + 1.
            }
        }
    }
    IF armed > 0 {
        mLog("Armed " + armed + " parachute(s).").
    } ELSE {
        mLogWarn("No parachutes found to arm (parts=" + parts:LENGTH + ").").
    }
}

LOCAL FUNCTION _descentExtendAntennas {
    LOCAL extended IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL m IS p:GETMODULE("ModuleDeployableAntenna").
            IF m:HASEVENT("extend antenna") {
                m:DOEVENT("extend antenna").
                SET extended TO extended + 1.
                mLog("Extended antenna: " + p:TITLE).
            }
        }
    }
    IF extended > 0 {
        mLog("Extended " + extended + " antenna(s).").
        WAIT 3.
    }
}
