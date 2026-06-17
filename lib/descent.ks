// --- Config defaults owned by this file ---
GLOBAL AEROBRAKE_REENTRY_DIR IS "".
GLOBAL DESCENT_RELEASE_ALT IS -1.
GLOBAL DESCENT_CHUTES_TAG IS "".
GLOBAL DESCENT_DROGUE_CUT_ALT IS -1.
GLOBAL DESCENT_FAIRING_TAG IS "".
GLOBAL DESCENT_DECOUPLER_TAG IS "".
GLOBAL DESCENT_DECOUPLE_ALT IS -999999.
GLOBAL DESCENT_HEAT_SHIELD_DROP_ALT IS -999999.
GLOBAL DESCENT_BAY_REOPEN_ALT IS -1.
GLOBAL DESCENT_FAIRING_DEPLOY_SPEED IS 10.
GLOBAL DESCENT_ENGINE_ASSIST IS 0.
GLOBAL DESCENT_ENGINE_ASSIST_ALT IS 1000.
GLOBAL DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS IS 2.5.
GLOBAL DESCENT_ENGINE_ASSIST_HIGH_VS IS 12.
GLOBAL DESCENT_ENGINE_ASSIST_MAX_THROTTLE IS 0.85.
GLOBAL DESCENT_ENGINE_ASSIST_GAIN IS 0.18.
GLOBAL DESCENT_ENGINE_ASSIST_ALIGN_DEG IS 20.

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
        SET alarmId TO kacEnsureAlarm(label + ": " + SHIP:NAME,
            TIME:SECONDS + eta_ - 120, "Auto-created by phaseDescent").
        mLog("KAC alarm set for " + label + " in "
            + ROUND(eta_ - 120, 0) + "s.").
    }
    LOCAL targetAlt IS rTarget - SHIP:BODY:RADIUS.
    WAIT UNTIL SHIP:ALTITUDE < targetAlt
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    SET WARP TO 0.
    IF alarmId <> "" { DELETEALARM(alarmId). }
}

LOCAL FUNCTION _descentGravity {
    LOCAL radiusMag IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    IF radiusMag <= 0 { RETURN 0.01. }
    RETURN MAX(0.01, SHIP:BODY:MU / (radiusMag * radiusMag)).
}

LOCAL FUNCTION _descentMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _descentBottomRadar {
    RETURN MAX(0, SHIP:BOUNDS:BOTTOMALTRADAR).
}

LOCAL FUNCTION _descentEngineAssistTargetDown {
    PARAMETER bottomAlt.
    PARAMETER assistAlt.
    LOCAL touchdownVs IS MAX(0.2, DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS).
    LOCAL highVs IS MAX(touchdownVs, DESCENT_ENGINE_ASSIST_HIGH_VS).
    LOCAL altFrac IS MAX(0, MIN(1, bottomAlt / MAX(1, assistAlt))).
    RETURN touchdownVs + altFrac * (highVs - touchdownVs).
}

LOCAL FUNCTION _descentEngineAssist {
    IF DESCENT_ENGINE_ASSIST <= 0 { RETURN. }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN. }
    IF SHIP:AVAILABLETHRUST <= 0 {
        mLogWarn("Descent engine assist requested, but no thrust is available.").
        RETURN.
    }

    LOCAL assistAlt IS MAX(1, DESCENT_ENGINE_ASSIST_ALT).
    IF _descentBottomRadar() > assistAlt {
        mLog("Engine assist armed below " + ROUND(assistAlt, 0) + "m AGL.").
        WAIT UNTIL _descentBottomRadar() < assistAlt
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN. }

    GEAR ON.
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCK STEERING TO SHIP:UP:VECTOR.

    LOCAL maxThrottle IS MAX(0, MIN(1, DESCENT_ENGINE_ASSIST_MAX_THROTTLE)).
    LOCAL lastLog IS TIME:SECONDS - 999.
    mLog("Engine assist active: alt=" + ROUND(_descentBottomRadar(), 0)
        + "m vs=" + ROUND(SHIP:VERTICALSPEED, 1)
        + " maxThrottle=" + ROUND(maxThrottle, 2) + ".").

    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        LOCAL bottomAlt IS _descentBottomRadar().
        LOCAL downSpeed IS MAX(0, -SHIP:VERTICALSPEED).
        LOCAL targetDown IS _descentEngineAssistTargetDown(bottomAlt, assistAlt).
        LOCAL maxAcc IS _descentMaxAcc().
        LOCAL grav IS _descentGravity().
        LOCAL alignErr IS VANG(SHIP:FACING:FOREVECTOR, SHIP:UP:VECTOR).

        IF maxAcc <= 0 {
            SET throttleCmd TO 0.
        } ELSE IF alignErr > DESCENT_ENGINE_ASSIST_ALIGN_DEG {
            SET throttleCmd TO 0.
        } ELSE IF downSpeed > targetDown {
            SET throttleCmd TO MIN(maxThrottle,
                MAX(0, grav / maxAcc
                    + (downSpeed - targetDown)
                        * DESCENT_ENGINE_ASSIST_GAIN)).
        } ELSE {
            SET throttleCmd TO 0.
        }

        IF TIME:SECONDS - lastLog > 2 {
            SET lastLog TO TIME:SECONDS.
            mLog("ASSIST alt=" + ROUND(bottomAlt, 0)
                + " vs=" + ROUND(SHIP:VERTICALSPEED, 1)
                + "/" + ROUND(-targetDown, 1)
                + " align=" + ROUND(alignErr, 1)
                + " thr=" + ROUND(throttleCmd, 2) + ".").
        }
        WAIT 0.
    }

    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    mLog("Engine assist complete: " + SHIP:STATUS
        + " vs=" + ROUND(SHIP:VERTICALSPEED, 1) + ".").
}

GLOBAL FUNCTION phaseDescent {
    mLogPhase("DESCENT").

    // LOCK STEERING retrograde for descent orientation.
    LOCAL dir IS "RETROGRADE".
    IF AEROBRAKE_REENTRY_DIR <> "" {
        SET dir TO AEROBRAKE_REENTRY_DIR.
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
    IF DESCENT_RELEASE_ALT >= 0 {
        SET releaseAlt TO DESCENT_RELEASE_ALT.
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
    } ELSE IF NOT SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE > 30000 {
        mLog("Airless body — waiting for the 30km action point...").
        _descentWaitForRadius(SHIP:BODY:RADIUS + 30000, "Descent action").
        mLog("30km action point reached.").
    }
    _descentRetractSolarPanels().
    _descentRetractAntennas().
    _descentCloseExtendBays().

    // Arm chutes early so they auto-deploy at safe altitude
    _descentArmChutes().

    // Burn remaining fuel only if we're not committed to landing.
    // If Trajectories predicts an impact, we're captured and don't
    // need to waste dV. If no impact, brake to ensure reentry.
    IF _mustDecelerate() {
        _descentBrakingBurn().
    }

    // Deploy fairing once slow enough for the active profile.
    _descentDeployFairing().

    // Optional drag test: reopen tagged service bays before descent decouple.
    _descentReopenExtendBaysForDrag().

    // Decouple transfer stage at safe altitude
    _descentDecouple().

    // Wait for chutes to deploy or vessel to land/splash
    mLog("Waiting for chute deployment or landing...").
    WAIT UNTIL _chutesDeployed()
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".

    IF _chutesDeployed() {
        mLog("Chutes deployed.").
        _descentCutDrogues().
    }

    _descentEngineAssist().

    // Wait for safe speed to extend antennas (< 20 m/s)
    // Deployable antennas break at higher speeds in atmosphere
    LOCAL safeSpeed IS 20.
    IF SHIP:AIRSPEED > safeSpeed {
        mLog("Waiting for safe antenna speed (< " + safeSpeed + " m/s)...").
        WAIT UNTIL SHIP:AIRSPEED < safeSpeed
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    mLog("Safe to redeploy antennas (airspeed=" + ROUND(SHIP:AIRSPEED, 1) + " m/s).").
    _descentReopenExtendBays().
    _descentExtendAntennas().
    _descentDropHeatShield().

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
    IF DESCENT_CHUTES_TAG <> "" {
        SET parts TO SHIP:PARTSTAGGED(DESCENT_CHUTES_TAG).
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

LOCAL FUNCTION _descentPartLooksDrogue {
    PARAMETER p.
    LOCAL marker IS " " + p:TITLE:TOLOWER + " " + p:NAME:TOLOWER + " ".
    RETURN marker:CONTAINS("drogue").
}

LOCAL FUNCTION _descentCutChutePart {
    PARAMETER p.
    LOCAL moduleName IS "".
    IF p:HASMODULE("ModuleParachute") { SET moduleName TO "ModuleParachute". }
    ELSE IF p:HASMODULE("RealChuteModule") { SET moduleName TO "RealChuteModule". }
    IF moduleName = "" { RETURN FALSE. }

    LOCAL m IS p:GETMODULE(moduleName).
    FOR evName IN m:ALLEVENTNAMES {
        LOCAL evLower IS evName:TOLOWER.
        IF evLower:CONTAINS("cut") {
            m:DOEVENT(evName).
            mLog("Cut drogue chute: " + p:TITLE + " via '" + evName + "'.").
            RETURN TRUE.
        }
    }
    mLogWarn("Drogue chute '" + p:TITLE + "' has no cut event. Events: "
        + m:ALLEVENTNAMES:JOIN(", ")).
    RETURN FALSE.
}

LOCAL FUNCTION _descentCutDrogues {
    LOCAL cutAlt IS 4900.
    IF DESCENT_DROGUE_CUT_ALT >= 0 {
        SET cutAlt TO DESCENT_DROGUE_CUT_ALT.
    }
    IF cutAlt <= 0 { RETURN. }

    IF SHIP:ALTITUDE > cutAlt {
        mLog("Waiting to cut drogue chutes below "
            + ROUND(cutAlt, 0) + "m.").
        WAIT UNTIL SHIP:ALTITUDE < cutAlt
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN. }

    LOCAL found IS 0.
    LOCAL cutCount IS 0.
    FOR p IN SHIP:PARTS {
        IF _descentPartLooksDrogue(p)
                AND (p:HASMODULE("ModuleParachute")
                    OR p:HASMODULE("RealChuteModule")) {
            SET found TO found + 1.
            mLog("Drogue chute candidate: " + p:TITLE + ".").
            IF _descentCutChutePart(p) { SET cutCount TO cutCount + 1. }
        }
    }
    IF found = 0 {
        mLogWarn("No drogue chute candidates found to cut.").
    } ELSE {
        mLog("Drogue chute cut pass: found=" + found + " cut=" + cutCount + ".").
    }
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
}

// Deploy descent fairing once airspeed is below configured safe speed.
// Reads tag from DESCENT_FAIRING_TAG config key.
LOCAL FUNCTION _descentDeployFairing {
    LOCAL tag IS "descent_fairing".
    IF DESCENT_FAIRING_TAG <> "" {
        SET tag TO DESCENT_FAIRING_TAG.
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

    LOCAL deploySpeed IS MAX(0, DESCENT_FAIRING_DEPLOY_SPEED).
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
    IF DESCENT_DECOUPLER_TAG <> "" {
        SET tag TO DESCENT_DECOUPLER_TAG.
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
    IF DESCENT_DECOUPLE_ALT > -999999 {
        SET decoupleAlt TO DESCENT_DECOUPLE_ALT.
    }

    IF SHIP:ALTITUDE > decoupleAlt {
        mLog("Waiting for " + ROUND(decoupleAlt/1000, 1) + "km altitude to decouple...").
        WAIT UNTIL SHIP:ALTITUDE < decoupleAlt
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    FOR dc IN decouplers {
        _descentDecouplePart(dc, "tag=" + tag).
    }
    WAIT 2.
}

LOCAL FUNCTION _descentDecouplePart {
    PARAMETER p.
    PARAMETER label.
    IF p:HASMODULE("ModuleDecouple") {
        IF _descentDoFirstEvent(p:GETMODULE("ModuleDecouple"),
                LIST("decouple", "Decouple", "jettison", "Jettison",
                    "Jettison Heat Shield")) {
            mLog("Decoupled: " + p:TITLE + " (" + label + ")").
            RETURN TRUE.
        }
    }
    IF p:HASMODULE("ModuleAnchoredDecoupler") {
        IF _descentDoFirstEvent(p:GETMODULE("ModuleAnchoredDecoupler"),
                LIST("decouple", "Decouple")) {
            mLog("Decoupled: " + p:TITLE + " (" + label + ")").
            RETURN TRUE.
        }
    }
    IF p:HASMODULE("ModuleJettison") {
        IF _descentDoFirstEvent(p:GETMODULE("ModuleJettison"),
                LIST("jettison", "Jettison", "Jettison Heat Shield")) {
            mLog("Jettisoned: " + p:TITLE + " (" + label + ")").
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _descentDoFirstEvent {
    PARAMETER module_.
    PARAMETER events.
    FOR eventName IN events {
        IF module_:HASEVENT(eventName) {
            module_:DOEVENT(eventName).
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _descentDropHeatShield {
    IF DESCENT_HEAT_SHIELD_DROP_ALT <= -999999 { RETURN. } ELSE {
        RETURN.
    }

    LOCAL dropAlt IS DESCENT_HEAT_SHIELD_DROP_ALT.
    IF dropAlt <= 0 { RETURN. }

    LOCAL candidates IS LIST().
    FOR p IN SHIP:PARTS {
        LOCAL title IS p:TITLE:TOUPPER.
        LOCAL looksLikeHeatShield IS p:HASMODULE("ModuleAblator")
            OR title:CONTAINS("HEAT SHIELD")
            OR title:CONTAINS("HEATSHIELD").
        IF looksLikeHeatShield
                AND (p:HASMODULE("ModuleDecouple")
                    OR p:HASMODULE("ModuleAnchoredDecoupler")
                    OR p:HASMODULE("ModuleJettison")) {
            candidates:ADD(p).
        }
    }

    IF candidates:LENGTH = 0 {
        mLogWarn("Heat shield drop requested, but no decouplable heat shield found.").
        RETURN.
    }
    IF candidates:LENGTH > 1 {
        mLogWarn("Heat shield drop found " + candidates:LENGTH
            + " candidates; using " + candidates[0]:TITLE + ".").
    }

    IF ALT:RADAR > dropAlt {
        mLog("Waiting for " + ROUND(dropAlt, 0)
            + "m AGL to drop heat shield...").
        WAIT UNTIL ALT:RADAR < dropAlt
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN. }

    IF _descentDecouplePart(candidates[0], "heat shield drop") {
        WAIT 1.
    } ELSE {
        mLogWarn("Heat shield candidate has no recognized decouple module: "
            + candidates[0]:TITLE + ".").
    }
}

LOCAL FUNCTION _descentReopenExtendBaysForDrag {
    IF DESCENT_BAY_REOPEN_ALT < 0 { RETURN. } ELSE {
        RETURN.
    }

    LOCAL reopenAlt IS DESCENT_BAY_REOPEN_ALT.
    IF reopenAlt <= 0 { RETURN. }

    IF SHIP:ALTITUDE > reopenAlt {
        mLog("Waiting for " + ROUND(reopenAlt/1000, 1)
            + "km to reopen extend bays for drag...").
        WAIT UNTIL SHIP:ALTITUDE < reopenAlt
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN. }

    _descentReopenExtendBays().
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

LOCAL FUNCTION _descentRetractSolarPanels {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL m IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF m:HASEVENT("Retract Solar Panel") {
                m:DOEVENT("Retract Solar Panel").
                SET retracted TO retracted + 1.
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " solar panel(s) for entry.").
        WAIT 3.
    }
}

LOCAL FUNCTION _descentCloseExtendBays {
    LOCAL closed IS 0.
    LOCAL missing IS 0.
    FOR p IN SHIP:PARTSTAGGED("extend_bay") {
        IF p:HASMODULE("ModuleAnimateGeneric") {
            LOCAL bm IS p:GETMODULE("ModuleAnimateGeneric").
            IF bm:HASEVENT("Close") {
                bm:DOEVENT("Close").
                SET closed TO closed + 1.
            } ELSE IF bm:HASEVENT("Close Doors") {
                bm:DOEVENT("Close Doors").
                SET closed TO closed + 1.
            } ELSE IF bm:HASEVENT("Retract") {
                bm:DOEVENT("Retract").
                SET closed TO closed + 1.
            } ELSE {
                SET missing TO missing + 1.
            }
        } ELSE {
            SET missing TO missing + 1.
        }
    }
    IF closed > 0 OR missing > 0 {
        mLog("Extend bays closed: " + closed + "  unavailable: " + missing + ".").
        WAIT 1.
    }
}

LOCAL FUNCTION _descentReopenExtendBays {
    LOCAL opened IS 0.
    LOCAL missing IS 0.
    FOR p IN SHIP:PARTSTAGGED("extend_bay") {
        IF p:HASMODULE("ModuleAnimateGeneric") {
            LOCAL bm IS p:GETMODULE("ModuleAnimateGeneric").
            IF bm:HASEVENT("Open") {
                bm:DOEVENT("Open").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Open Doors") {
                bm:DOEVENT("Open Doors").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Extend") {
                bm:DOEVENT("Extend").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Deploy") {
                bm:DOEVENT("Deploy").
                SET opened TO opened + 1.
            } ELSE {
                SET missing TO missing + 1.
            }
        } ELSE {
            SET missing TO missing + 1.
        }
    }
    IF opened > 0 OR missing > 0 {
        mLog("Extend bays reopened: " + opened + "  unavailable: " + missing + ".").
        WAIT 1.
    }
}

// Arm chutes by tag (DESCENT_CHUTES_TAG, default "descent_chutes")
// or all chutes if tag yields nothing.
LOCAL FUNCTION _descentArmChutes {
    LOCAL tag IS "descent_chutes".
    IF DESCENT_CHUTES_TAG <> "" {
        SET tag TO DESCENT_CHUTES_TAG.
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
