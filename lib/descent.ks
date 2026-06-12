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
    "KERBIN", 100,
    "DUNA",   8000,
    "EVE",    12000,
    "LAYTHE", 10000,
    "TEKTO",  10000
).

// Check if we need to burn remaining fuel to ensure capture.
// If Trajectories predicts an impact, we're committed to landing
// and don't need extra braking. If there's no impact (skip-out,
// still orbital), we must decelerate to guarantee reentry.
//
// TODO: This doesn't cover aerobrake-assist scenarios (e.g. Laythe
// atmosphere bend into Jool capture). HASIMPACT could be true on
// Laythe but the post-aerobrake orbit still escapes Jool. Needs
// post-atmospheric-pass orbit prediction to handle correctly.
LOCAL FUNCTION _mustDecelerate {
    IF NOT ADDONS:TR:AVAILABLE {
        mLog("Trajectories not available — braking to be safe.").
        RETURN TRUE.
    }
    IF ADDONS:TR:HASIMPACT {
        LOCAL impact IS ADDONS:TR:IMPACTPOS.
        mLog("Trajectories predicts impact at " + ROUND(impact:LAT, 2) + "," + ROUND(impact:LNG, 2)
            + " — no braking needed.").
        RETURN FALSE.
    }
    mLog("No impact predicted — braking to ensure capture.").
    RETURN TRUE.
}

// Kepler ETA until the orbit descends through the given radius,
// or -1 when it never does (self-contained — descent has no lib
// dependencies). Mean anomaly advances linearly in time.
LOCAL FUNCTION _descentEtaToRadius {
    PARAMETER rTarget.
    LOCAL obtEcc IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL sma IS SHIP:ORBIT:SEMIMAJORAXIS.
    IF obtEcc >= 1 OR sma <= 0 { RETURN -1. }
    IF rTarget <= sma * (1 - obtEcc) OR rTarget >= sma * (1 + obtEcc) {
        RETURN -1.
    }
    LOCAL cosTa IS MAX(-1, MIN(1,
        (sma * (1 - obtEcc ^ 2) / rTarget - 1) / obtEcc)).
    // Descending branch: true anomaly approaching periapsis.
    LOCAL taCross IS 360 - ARCCOS(cosTa).

    LOCAL FUNCTION _meanAnom {
        PARAMETER ta.
        LOCAL eAnom IS 2 * ARCTAN2(
            SQRT(1 - obtEcc) * SIN(ta / 2),
            SQRT(1 + obtEcc) * COS(ta / 2)).
        RETURN eAnom - obtEcc * SIN(eAnom) * CONSTANT:RADTODEG.
    }
    LOCAL dM IS _meanAnom(taCross) - _meanAnom(SHIP:ORBIT:TRUEANOMALY).
    UNTIL dM >= 0  { SET dM TO dM + 360. }
    UNTIL dM < 360 { SET dM TO dM - 360. }
    RETURN (dM / 360) * SHIP:ORBIT:PERIOD.
}

// KAC alarm + warp-friendly wait until the ship descends through
// targetRadius (flight-found: DESCENT blind-waited for reentry —
// warping from the tracking station sailed past the alignment).
LOCAL FUNCTION _descentWaitForRadius {
    PARAMETER rTarget, label.
    LOCAL alarmId IS "".
    LOCAL eta_ IS _descentEtaToRadius(rTarget).
    IF ADDONS:KAC:AVAILABLE AND eta_ > 180 {
        LOCAL alm IS ADDALARM("Raw", TIME:SECONDS + eta_ - 120,
            label + ": " + SHIP:NAME, "Auto-created by phaseDescent").
        SET alm:ACTION TO warpKillAction().
        SET alarmId TO alm:ID.
        mLog("KAC alarm set for " + label + " in "
            + ROUND(eta_ - 120, 0) + "s.").
    }
    LOCAL targetAlt IS rTarget - SHIP:BODY:RADIUS.
    WAIT UNTIL SHIP:ALTITUDE < targetAlt
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    killWarp().
    IF alarmId <> "" { DELETEALARM(alarmId). }
}

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

    // Release attitude control once past the worst of entry
    // (DESCENT_RELEASE_ALT, default 20km): below that the chutes
    // stabilize the craft, and holding the steering lock / SAS
    // just drains the battery when it is needed most. The
    // throttle guard keeps it from releasing mid-braking-burn.
    LOCAL releaseAlt IS 20000.
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_RELEASE_ALT") {
        SET releaseAlt TO CFG["DESCENT_RELEASE_ALT"].
    }
    IF SHIP:BODY:ATM:EXISTS AND releaseAlt > 0 {
        WHEN SHIP:ALTITUDE < releaseAlt AND SHIP:VERTICALSPEED < 0
                AND THROTTLE < 0.01 THEN {
            UNLOCK STEERING.
            SAS OFF.
            mLog("Attitude control released at "
                + ROUND(SHIP:ALTITUDE / 1000, 1)
                + "km — conserving battery.").
        }
    }

    // Wait for atmosphere entry (alarmed); on airless bodies, for
    // the 30km action point instead.
    IF SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT {
        mLog("Waiting for atmospheric entry...").
        _descentWaitForRadius(
            SHIP:BODY:RADIUS + SHIP:BODY:ATM:HEIGHT, "Reentry").
        mLog("Entered atmosphere at " + ROUND(SHIP:ALTITUDE/1000, 1) + "km.").
        WAIT 5.
        _descentRetractAntennas().
    } ELSE IF NOT SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE > 30000 {
        mLog("Airless body — waiting for the 30km action point...").
        _descentWaitForRadius(SHIP:BODY:RADIUS + 30000, "Descent action").
        mLog("30km action point reached.").
    }

    // Arm chutes early so they auto-deploy at safe altitude
    _descentArmChutes().

    // Burn remaining fuel only if we're not committed to landing.
    // If Trajectories predicts an impact, we're captured and don't
    // need to waste dV. If no impact, brake to ensure reentry.
    IF _mustDecelerate() {
        _descentBrakingBurn().
    }

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

// Burn retrograde until we're guaranteed captured, then stop.
//
// Stop conditions (checked every tick):
//   1. Landing this pass — apoapsis below atmosphere (won't exit)
//   2. Captured in orbit — closed orbit, both apsides above atmosphere
//   3. Fuel exhausted    — nothing left to burn
//   4. Landed/splashed   — already on the surface
//
// Note: Trajectories HASIMPACT alone is insufficient — it models
// multi-orbit drag decay and reports impact even when the apoapsis
// is still above atmosphere. The vessel would orbit 2+ more times
// before landing, which isn't survivable without solar panels.
LOCAL FUNCTION _descentBrakingBurn {
    IF SHIP:AVAILABLETHRUST <= 0 { RETURN. }

    LOCAL fuel IS STAGE:LIQUIDFUEL + STAGE:OXIDIZER.
    IF fuel <= 0.1 {
        mLog("No fuel remaining — skipping braking burn.").
        RETURN.
    }

    LOCAL atmHeight IS 0.
    IF SHIP:BODY:ATM:EXISTS { SET atmHeight TO SHIP:BODY:ATM:HEIGHT. }

    mLog("Braking burn: thrust=" + ROUND(SHIP:AVAILABLETHRUST, 1)
        + "kN  fuel=" + ROUND(fuel, 1)
        + "  ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 3)
        + "  ApKm=" + ROUND(SHIP:APOAPSIS/1000, 1)
        + "  atmKm=" + ROUND(atmHeight/1000, 1)).

    LOCK THROTTLE TO 1.
    LOCK STEERING TO RETROGRADE.

    LOCAL reason IS "".
    UNTIL reason <> "" {
        IF (STAGE:LIQUIDFUEL + STAGE:OXIDIZER) <= 0.1
                OR SHIP:AVAILABLETHRUST <= 0 {
            SET reason TO "fuel-exhausted".
        } ELSE IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            SET reason TO "landed".
        } ELSE IF SHIP:ORBIT:ECCENTRICITY < 1
                AND SHIP:ORBIT:APOAPSIS > 0
                AND SHIP:ORBIT:APOAPSIS < atmHeight {
            // Apoapsis below atmosphere — committed to landing this pass
            SET reason TO "landing-this-pass".
        } ELSE IF SHIP:ORBIT:ECCENTRICITY < 1
                AND SHIP:ORBIT:APOAPSIS > atmHeight
                AND SHIP:ORBIT:PERIAPSIS > atmHeight {
            // Stable orbit above atmosphere — captured, no reentry needed
            SET reason TO "orbit-captured".
        }
        WAIT 0.
    }

    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.

    mLog("Braking burn complete: " + reason
        + "  speed=" + ROUND(SHIP:AIRSPEED, 1) + " m/s"
        + "  ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 3)
        + "  ApKm=" + ROUND(SHIP:APOAPSIS/1000, 1)
        + "  PeKm=" + ROUND(SHIP:PERIAPSIS/1000, 1)).
    mLogWarn("STATS descent braking reason=" + reason
        + " speed=" + ROUND(SHIP:AIRSPEED, 1)
        + " alt=" + ROUND(SHIP:ALTITUDE/1000, 1)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 3)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000, 1)).
}

// Deploy descent fairing once airspeed is below 60 m/s.
// Reads tag from DESCENT_FAIRING_TAG config key.
LOCAL FUNCTION _descentDeployFairing {
    LOCAL tag IS "descent_fairing".
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_FAIRING_TAG") {
        SET tag TO CFG["DESCENT_FAIRING_TAG"].
    }
    IF tag = "" { RETURN. }
    IF tag = "none" {
        mLog("Descent fairing disabled (tag=none).").
        RETURN.
    }

    LOCAL fairings IS SHIP:PARTSTAGGED(tag).
    IF fairings:LENGTH = 0 {
        mLogWarn("Descent fairing tag '" + tag + "' not found.").
        RETURN.
    }

    LOCAL deploySpeed IS 10.
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
// Reads tag from DESCENT_DECOUPLER_TAG config key. Tag "none"
// disables the decouple entirely (flight-found on FR3: the shed
// transfer stage exploded next to the lander at touchdown).
LOCAL FUNCTION _descentDecouple {
    LOCAL tag IS "descent_decoupler".
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_DECOUPLER_TAG") {
        SET tag TO CFG["DESCENT_DECOUPLER_TAG"].
    }
    IF tag = "" { RETURN. }
    IF tag = "none" {
        mLog("Descent decouple disabled (tag=none).").
        RETURN.
    }

    LOCAL decouplers IS SHIP:PARTSTAGGED(tag).
    IF decouplers:LENGTH = 0 {
        mLogWarn("Descent decoupler tag '" + tag + "' not found.").
        RETURN.
    }

    // Wait for safe decouple altitude. DESCENT_DECOUPLE_ALT
    // overrides the body table — crew capsules shed their booster
    // high on descent, not at the body default (Kerbin's 100m
    // drops the stage right next to the lander).
    LOCAL decoupleAlt IS 6000.
    IF DECOUPLE_ALTS:HASKEY(SHIP:BODY:NAME) {
        SET decoupleAlt TO DECOUPLE_ALTS[SHIP:BODY:NAME].
    }
    IF DEFINED CFG AND CFG:HASKEY("DESCENT_DECOUPLE_ALT") {
        SET decoupleAlt TO CFG["DESCENT_DECOUPLE_ALT"].
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
        LOCAL moduleName IS "".
        IF p:HASMODULE("ModuleParachute") { SET moduleName TO "ModuleParachute". }
        ELSE IF p:HASMODULE("RealChuteModule") { SET moduleName TO "RealChuteModule". }

        IF moduleName <> "" {
            LOCAL m IS p:GETMODULE(moduleName).
            IF m:HASEVENT("arm parachute") {
                m:DOEVENT("arm parachute").
                SET armed TO armed + 1.
            } ELSE IF m:HASEVENT("deploy chute") {
                m:DOEVENT("deploy chute").
                SET armed TO armed + 1.
            } ELSE IF m:HASEVENT("deploy") {
                m:DOEVENT("deploy").
                SET armed TO armed + 1.
            } ELSE {
                mLogWarn("Chute '" + p:TITLE + "' (" + moduleName + ") has no arm/deploy event."
                    + " Events: " + m:ALLEVENTNAMES:JOIN(", ")).
            }
        } ELSE {
            mLogWarn("Tagged part '" + p:TITLE + "' has no parachute module."
                + " Modules: " + p:MODULES:JOIN(", ")).
        }
    }
    IF armed > 0 {
        mLog("Armed/deployed " + armed + " parachute(s).").
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
