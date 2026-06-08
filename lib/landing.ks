// ============================================================
// landing.ks  —  Suicide burn landing  (0:/lib/landing.ks)
//
// Clean single-file landing library built around suicide burn
// physics. Handles powered descent from suborbital trajectory
// to touchdown, with optional carrier handoff post-landing.
//
// Entry point: landExecute()
// Also exports: landingResolveTarget(), landingTargetedDeorbit(),
//               landingImpactWithinTolerance(),
//               landingImpactAcceptableForAssist()
// ============================================================

// ------------------------------------------------------------
// Configuration
// ------------------------------------------------------------
GLOBAL LAND_CFG IS LEXICON(
    // Descent parameters
    "TOUCHDOWN_SPEED",    2.0,    // target vertical speed at ground (m/s)
    "HOVER_ALT",        100,      // alt to transition from full-brake to constant-decel
    "UPRIGHT_ALT",       10,      // alt to go pure vertical and hover to touchdown
    "BURN_MARGIN",        1.05,   // safety factor: start burn when TTI <= SBD * margin
    "MAX_TILT",          15,      // max steering lean during descent (degrees)

    // Target resolution
    "TARGET_LAT",           0,
    "TARGET_LNG",           0,
    "TARGET_BODY",         "",
    "TARGET_WAYPOINT",     "",
    "TARGET_LOCK",      FALSE,
    "TARGET_TOLERANCE",  2500,

    // Deorbit
    "DEORBIT_PE",       -3000,
    "DEORBIT_OVERSHOOT",    0,    // meters to overshoot target for carrier braking
    "DEORBIT_OVERSHOOT_TOLERANCE", 1200,
    "GUIDANCE_ALT",      5000,    // alt below which guidance steers toward target

    // Carrier handoff (empty tag = no handoff)
    "CARRIER_TAG",       "",      // decoupler tag for carrier release
    "CARRIER_TIP",     TRUE,      // tip carrier sideways before release
    "CARRIER_TIP_TIME",  1.5,     // seconds to hold tip
    "CARRIER_SETTLE",    2.0,     // seconds to wait after touchdown before handoff
    "ROVER_ORIENT",    TRUE,      // orient rover upright after release
    "ROVER_ORIENT_TIME", 3.0,    // seconds to hold upright orientation
    "ROVER_BRAKE",     TRUE       // engage brakes after rover lands on wheels
).

// Backward-compat alias: code that checks DEFINED LANDING_CFG still works
GLOBAL LANDING_CFG IS LAND_CFG.

GLOBAL landingAbortFlag IS FALSE.

// ------------------------------------------------------------
// Core physics helpers
// ------------------------------------------------------------

// Effective gravity accounting for centrifugal force from ground speed
LOCAL FUNCTION _grav {
    LOCAL _r IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL g IS mu / (_r^2).
    LOCAL gs IS SHIP:GROUNDSPEED.
    IF gs > 1 AND _r > 0 {
        SET g TO g - (gs^2) / _r.
    }
    RETURN MAX(0.01, g).
}

// Maximum acceleration available (m/s^2)
LOCAL FUNCTION _maxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

// Duration of a full-thrust suicide burn to kill current surface speed
LOCAL FUNCTION _suicideBurnDuration {
    LOCAL acc IS _maxAcc().
    LOCAL g IS _grav().
    LOCAL spd IS SHIP:VELOCITY:SURFACE:MAG.
    LOCAL vs IS SHIP:VERTICALSPEED.
    IF acc <= g { RETURN 99999. }
    // Project gravity along velocity vector for more accurate estimate
    IF spd < 0.1 { RETURN 0. }
    RETURN spd / (acc - g * ABS(vs) / spd).
}

// Time to impact assuming constant gravity, current vertical speed and alt
LOCAL FUNCTION _timeToImpact {
    LOCAL g IS _grav().
    LOCAL vs IS SHIP:VERTICALSPEED.
    LOCAL alt_ IS ALT:RADAR.
    IF alt_ <= 0 { RETURN 0. }
    // Quadratic: alt = vs*t + 0.5*g*t^2 (vs negative when descending)
    LOCAL disc IS vs^2 + 2 * alt_ * g.
    IF disc < 0 { RETURN 99999. }
    RETURN (SQRT(disc) + vs) / g.
}

// Horizontal surface velocity vector (surface velocity minus vertical component)
LOCAL FUNCTION _hVel {
    LOCAL upVec IS SHIP:UP:VECTOR.
    RETURN SHIP:VELOCITY:SURFACE - (VDOT(SHIP:VELOCITY:SURFACE, upVec) * upVec).
}

// ------------------------------------------------------------
// Steering helpers
// ------------------------------------------------------------

// Steering vector that is mostly retrograde but leans up to MAX_TILT
// toward killing horizontal velocity
LOCAL FUNCTION _burnSteering {
    LOCAL sVel IS SHIP:VELOCITY:SURFACE.
    IF sVel:MAG < 0.5 { RETURN SHIP:UP:VECTOR. }
    LOCAL retro IS (-sVel):NORMALIZED.
    // Lean toward vertical to preferentially kill horizontal speed
    LOCAL hv IS _hVel().
    IF hv:MAG < 0.5 { RETURN retro. }
    LOCAL maxLean IS SIN(LAND_CFG["MAX_TILT"]).
    LOCAL lean IS MIN(maxLean, hv:MAG / 20).
    RETURN (retro + SHIP:UP:VECTOR * lean):NORMALIZED.
}

// Hover steering: mostly UP with lean to cancel horizontal drift
LOCAL FUNCTION _hoverSteering {
    LOCAL hv IS _hVel().
    IF hv:MAG < 0.3 { RETURN SHIP:UP:VECTOR. }
    LOCAL maxLean IS SIN(LAND_CFG["MAX_TILT"]).
    LOCAL lean IS MIN(maxLean, hv:MAG / 10).
    RETURN (SHIP:UP:VECTOR + (-hv):NORMALIZED * lean):NORMALIZED.
}

// ------------------------------------------------------------
// Hardware helpers
// ------------------------------------------------------------

LOCAL FUNCTION _deployGear {
    // Landing legs (stock + modded)
    FOR m IN SHIP:MODULESNAMED("ModuleWheelDeployment") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    FOR m IN SHIP:MODULESNAMED("ModuleLandingLeg") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    GEAR ON.
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
    FOR p IN SHIP:PARTS {
        IF p:TAG = tagName {
            IF p:HASMODULE("ModuleDecouple")
                    OR p:HASMODULE("ModuleAnchoredDecoupler") {
                RETURN p.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _decouplePart {
    PARAMETER partRef.
    IF partRef:HASMODULE("ModuleDecouple") {
        partRef:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF partRef:HASMODULE("ModuleAnchoredDecoupler") {
        partRef:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogWarn("Decoupler tag found, but no decouple module. Trying STAGE.").
        STAGE.
    }
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

// ------------------------------------------------------------
// Main entry point
// ------------------------------------------------------------

GLOBAL FUNCTION landExecute {
    mLogPhase("LANDING").
    SET landingAbortFlag TO FALSE.

    // Log KE availability for telemetry (not gating on it)
    IF ADDONS:KE:AVAILABLE {
        mLog("KerbalEngineer available — will log SB countdown for telemetry.").
    }

    // Resolve landing target
    LOCAL landingTarget IS landingResolveTarget().
    IF landingTarget["FOUND"] {
        mLog("Landing target: " + ROUND(landingTarget["LAT"],4)
            + "," + ROUND(landingTarget["LNG"],4)
            + " from " + landingTarget["SOURCE"] + ".").
        IF ADDONS:TR:AVAILABLE {
            ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
        }
    }

    // Phase 1: Orient retrograde, deploy gear
    SET SAS TO FALSE.
    LOCK STEERING TO _burnSteering().
    _deployGear().
    mLog("Oriented retrograde, gear deployed. Coasting to burn point.").
    HUDTEXT("Coast to burn point", 3, 2, 14, WHITE, FALSE).

    // Phase 2: Coast — wait until TTI <= SBD * BURN_MARGIN
    UNTIL landingAbortFlag {
        LOCAL tti IS _timeToImpact().
        LOCAL sbd IS _suicideBurnDuration().
        LOCAL margin IS LAND_CFG["BURN_MARGIN"].

        // Log KE telemetry if available
        IF ADDONS:KE:AVAILABLE AND ALT:RADAR < 20000 {
            HUDTEXT("TTI:" + ROUND(tti,1) + " SBD:" + ROUND(sbd,1)
                + " KE:" + ROUND(ADDONS:KE:SUICIDEBURNCOUNTDOWN,1),
                1, 2, 13, WHITE, FALSE).
        } ELSE {
            HUDTEXT("TTI:" + ROUND(tti,1) + " SBD:" + ROUND(sbd,1),
                1, 2, 13, WHITE, FALSE).
        }

        IF tti <= sbd * margin { BREAK. }
        IF _needsStage() { STAGE. WAIT 0.5. }
        WAIT 0.1.
    }
    IF landingAbortFlag { _landCleanup(). RETURN. }

    mLog("Burn start. Alt=" + ROUND(ALT:RADAR,0)
        + "m  spd=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1) + "m/s.").
    HUDTEXT("SUICIDE BURN", 3, 2, 16, YELLOW, FALSE).

    // Phase 3: Suicide burn — full throttle, steer retrograde with tilt
    LOCK THROTTLE TO 1.0.
    UNTIL ALT:RADAR <= LAND_CFG["HOVER_ALT"] OR landingAbortFlag {
        LOCK STEERING TO _burnSteering().

        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
            LOCK THROTTLE TO 1.0.
        }

        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s",
            1, 2, 13, YELLOW, FALSE).
        WAIT 0.05.
    }
    IF landingAbortFlag { _landCleanup(). RETURN. }

    mLog("Hover transition. Alt=" + ROUND(ALT:RADAR,0)
        + "m  vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s.").

    // Phase 4: Hover transition — constant-decel throttle to UPRIGHT_ALT
    UNTIL ALT:RADAR <= LAND_CFG["UPRIGHT_ALT"] OR landingAbortFlag {
        LOCK STEERING TO _hoverSteering().
        LOCAL acc IS _maxAcc().
        IF acc > 0 {
            LOCAL alt_ IS ALT:RADAR - LAND_CFG["UPRIGHT_ALT"].
            LOCAL spd IS SHIP:VELOCITY:SURFACE:MAG.
            LOCAL g IS _grav().
            // Desired decel to reach TOUCHDOWN_SPEED at UPRIGHT_ALT
            LOCAL desiredDecel IS (spd^2 - LAND_CFG["TOUCHDOWN_SPEED"]^2) / (2 * MAX(1, alt_)).
            LOCAL thrott IS (desiredDecel + g) / acc.
            LOCK THROTTLE TO MAX(0.05, MIN(1.0, thrott)).
        }

        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
        }

        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s",
            1, 2, 13, GREEN, FALSE).
        WAIT 0.05.
    }
    IF landingAbortFlag { _landCleanup(). RETURN. }

    // Phase 5: Upright — point UP, hover at grav/maxAcc until touchdown
    mLog("Final descent. Alt=" + ROUND(ALT:RADAR,0) + "m.").
    LOCK STEERING TO SHIP:UP.
    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" OR landingAbortFlag {
        LOCAL acc IS _maxAcc().
        LOCAL g IS _grav().
        IF acc > 0 {
            // Target descent at TOUCHDOWN_SPEED
            LOCAL vs IS SHIP:VERTICALSPEED.
            LOCAL err IS (-LAND_CFG["TOUCHDOWN_SPEED"]) - vs.
            LOCAL thrott IS (g / acc) + (err * 0.15).
            LOCK THROTTLE TO MAX(0, MIN(1.0, thrott)).
        }
        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s",
            1, 2, 13, GREEN, FALSE).
        WAIT 0.05.
    }
    IF landingAbortFlag { _landCleanup(). RETURN. }

    // Phase 6: Touchdown
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
        + "  lat=" + ROUND(SHIP:LATITUDE,4)
        + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
    HUDTEXT("TOUCHDOWN!", 8, 2, 20, GREEN, FALSE).
    stateSet("landing_lat",  SHIP:LATITUDE).
    stateSet("landing_lng",  SHIP:LONGITUDE).
    stateSet("landing_time", TIME:SECONDS).
    _deployAntennas().
    _deploySolarPanels().

    // Phase 7: Carrier handoff (optional)
    IF LAND_CFG["CARRIER_TAG"] <> "" {
        _carrierHandoff().
    }
}

// Backward-compat wrapper — old code calls landingExecute()
GLOBAL FUNCTION landingExecute {
    landExecute().
}

// ------------------------------------------------------------
// Carrier handoff
// ------------------------------------------------------------

LOCAL FUNCTION _carrierHandoff {
    LOCAL decoupler IS _taggedDecoupler(LAND_CFG["CARRIER_TAG"]).
    IF decoupler = 0 {
        mLogWarn("No decoupler tagged '" + LAND_CFG["CARRIER_TAG"]
            + "' — skipping carrier handoff.").
        RETURN.
    }

    // Step 1: Settle on the bell after touchdown
    mLog("Carrier handoff: settling " + ROUND(LAND_CFG["CARRIER_SETTLE"],1) + "s.").
    WAIT LAND_CFG["CARRIER_SETTLE"].
    mLogWarn("STATS carrier settled status=" + SHIP:STATUS
        + " alt=" + ROUND(ALT:RADAR,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)).

    // Step 2: Tip carrier sideways so rover clears the stack
    IF LAND_CFG["CARRIER_TIP"] {
        mLog("Tipping carrier for release.").
        SET SAS TO FALSE.
        LOCK STEERING TO SHIP:FACING:RIGHTVECTOR.
        WAIT LAND_CFG["CARRIER_TIP_TIME"].
        mLogWarn("STATS carrier tipped pitch=" + ROUND(SHIP:FACING:PITCH,1)
            + " roll=" + ROUND(SHIP:FACING:ROLL,1)).
    }

    // Step 3: Decouple — after this, kOS CPU is on the rover
    mLog("Decoupling rover from carrier.").
    _decouplePart(decoupler).
    WAIT 0.5.
    UNLOCK STEERING.
    mLogWarn("STATS rover released alt=" + ROUND(ALT:RADAR,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).

    // Step 4: Orient rover wheels-down — keep current heading but roll
    // so TOPVECTOR faces away from ground (wheels toward surface)
    IF LAND_CFG["ROVER_ORIENT"] {
        mLog("Orienting rover wheels-down.").
        SET SAS TO FALSE.
        // LOOKDIRUP(fore, top): keep nose roughly forward, roll wheels toward ground
        LOCK STEERING TO LOOKDIRUP(VXCL(SHIP:UP:VECTOR, SHIP:FACING:FOREVECTOR):NORMALIZED,
            SHIP:UP:VECTOR).
        LOCAL orientEnd IS TIME:SECONDS + LAND_CFG["ROVER_ORIENT_TIME"].

        // Hold orientation until timeout or we land on wheels
        UNTIL TIME:SECONDS >= orientEnd
                OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            LOCAL topErr IS VANG(SHIP:FACING:TOPVECTOR, SHIP:UP:VECTOR).
            HUDTEXT("Rover orient: alt=" + ROUND(ALT:RADAR,1)
                + "m  topErr=" + ROUND(topErr,1)
                + "deg", 0.5, 2, 13, CYAN, FALSE).
            WAIT 0.05.
        }
        UNLOCK STEERING.
        mLogWarn("STATS rover oriented topErr="
            + ROUND(VANG(SHIP:FACING:TOPVECTOR, SHIP:UP:VECTOR),1)
            + " alt=" + ROUND(ALT:RADAR,1)
            + " status=" + SHIP:STATUS).
    }

    // Step 5: Wait for rover to settle on its wheels
    IF NOT (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED") {
        mLog("Waiting for rover to touch down on wheels.").
        LOCAL wheelWait IS TIME:SECONDS + 15.
        UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED"
                OR TIME:SECONDS >= wheelWait {
            WAIT 0.1.
        }
    }

    // Step 6: Engage brakes
    IF LAND_CFG["ROVER_BRAKE"] {
        SET BRAKES TO TRUE.
        mLog("Brakes engaged.").
    }

    SET SAS TO TRUE.
    mLogWarn("STATS carrier handoff complete status=" + SHIP:STATUS
        + " lat=" + ROUND(SHIP:LATITUDE,4)
        + " lng=" + ROUND(SHIP:LONGITUDE,4)
        + " alt=" + ROUND(ALT:RADAR,1)).
    mLog("Carrier handoff complete. Rover on surface.").
}

// Assist stage descent: land the whole stack, then decouple + rover release.
// This replaces the old landingAssistStage() — identical contract.
GLOBAL FUNCTION landingAssistStage {
    mLogPhase("LANDING ASSIST").
    SET landingAbortFlag TO FALSE.

    // Ensure carrier tag is set so landExecute triggers _carrierHandoff
    IF LAND_CFG["CARRIER_TAG"] = "" {
        SET LAND_CFG["CARRIER_TAG"] TO "landing_assist_decoupler".
    }

    // Execute the suicide burn landing (includes carrier handoff at the end)
    landExecute().

    IF NOT (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED") {
        mLogWarn("Not on surface after assist descent.").
        RETURN FALSE.
    }
    RETURN TRUE.
}

// ------------------------------------------------------------
// Cleanup helper
// ------------------------------------------------------------

LOCAL FUNCTION _landCleanup {
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
}

// ------------------------------------------------------------
// Target resolution
// ------------------------------------------------------------

GLOBAL FUNCTION landingResolveTarget {
    LOCAL result IS LEXICON().
    result:ADD("FOUND", FALSE).
    result:ADD("LAT", 0).
    result:ADD("LNG", 0).
    result:ADD("SOURCE", "none").

    IF LAND_CFG["TARGET_WAYPOINT"] <> "" {
        LOCAL namedWp IS _waypointNamed(LAND_CFG["TARGET_WAYPOINT"]).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Landing waypoint '" + LAND_CFG["TARGET_WAYPOINT"]
            + "' not found on " + SHIP:BODY:NAME + ".").
    }

    IF LAND_CFG["TARGET_LOCK"]
            AND (LAND_CFG["TARGET_LAT"] <> 0 OR LAND_CFG["TARGET_LNG"] <> 0) {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LAND_CFG["TARGET_LAT"].
        SET result["LNG"] TO LAND_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "locked LAND_CFG".
        RETURN result.
    }

    LOCAL selectedWp IS _selectedWaypoint().
    IF selectedWp <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO selectedWp:GEOPOSITION:LAT.
        SET result["LNG"] TO selectedWp:GEOPOSITION:LNG.
        SET result["SOURCE"] TO "selected waypoint:" + selectedWp:NAME.
        RETURN result.
    }

    IF LAND_CFG["TARGET_LAT"] <> 0 OR LAND_CFG["TARGET_LNG"] <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LAND_CFG["TARGET_LAT"].
        SET result["LNG"] TO LAND_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "LAND_CFG".
        RETURN result.
    }

    RETURN result.
}

LOCAL FUNCTION _waypointNamed {
    PARAMETER waypointName.
    LOCAL allWps IS ALLWAYPOINTS().
    LOCAL targetName IS waypointName:TOUPPER.
    FOR wp IN allWps {
        IF wp:BODY:NAME = SHIP:BODY:NAME {
            IF wp:NAME:TOUPPER = targetName { RETURN wp. }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _selectedWaypoint {
    LOCAL allWps IS ALLWAYPOINTS().
    FOR wp IN allWps {
        IF wp:ISSELECTED {
            IF wp:BODY:NAME = SHIP:BODY:NAME { RETURN wp. }
        }
    }
    RETURN 0.
}

// ------------------------------------------------------------
// Deorbit and impact checking
// ------------------------------------------------------------

GLOBAL FUNCTION landingTargetedDeorbit {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set — refusing blind landing deorbit.").
        RETURN FALSE.
    }

    mLogWarn("STATS landing target source=" + landingTarget["SOURCE"]
        + " lat=" + ROUND(landingTarget["LAT"],4)
        + " lng=" + ROUND(landingTarget["LNG"],4)).
    SET LAND_CFG["TARGET_LAT"] TO landingTarget["LAT"].
    SET LAND_CFG["TARGET_LNG"] TO landingTarget["LNG"].
    mLog("Landing deorbit target: " + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)
        + " from " + landingTarget["SOURCE"] + ".").

    LOCAL aimTarget IS _overshootTarget(landingTarget).
    RETURN targetedDeorbitAt(
        aimTarget["LAT"],
        aimTarget["LNG"],
        LAND_CFG["DEORBIT_PE"],
        LAND_CFG["TARGET_TOLERANCE"]).
}

LOCAL FUNCTION _overshootTarget {
    PARAMETER landingTarget.
    LOCAL out IS LEXICON(
        "LAT", landingTarget["LAT"],
        "LNG", landingTarget["LNG"]
    ).
    LOCAL overshoot IS LAND_CFG["DEORBIT_OVERSHOOT"].
    IF overshoot <= 0 { RETURN out. }

    LOCAL hv IS _hVel().
    IF hv:MAG < 0.1 { RETURN out. }
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL northVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE + 0.01, SHIP:LONGITUDE):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL eastVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE, SHIP:LONGITUDE + 0.01):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL northM IS VDOT(hv:NORMALIZED, northVec) * overshoot.
    LOCAL eastM IS VDOT(hv:NORMALIZED, eastVec) * overshoot.
    LOCAL shifted IS _offsetLatLng(landingTarget["LAT"], landingTarget["LNG"], northM, eastM).
    SET out["LAT"] TO shifted["LAT"].
    SET out["LNG"] TO shifted["LNG"].
    mLogWarn("STATS deorbit overshoot aim="
        + ROUND(out["LAT"],4) + "," + ROUND(out["LNG"],4)
        + " overshootM=" + ROUND(overshoot,0)).
    RETURN out.
}

LOCAL FUNCTION _offsetLatLng {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER northM.
    PARAMETER eastM.
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(lat)).
    RETURN LEXICON(
        "LAT", lat + northM * degPerM,
        "LNG", lng + eastM * degPerM / lonScale
    ).
}

GLOBAL FUNCTION landingImpactWithinTolerance {
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN TRUE. }

    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set — refusing impact check.").
        RETURN FALSE.
    }
    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available — cannot verify landing impact.").
        RETURN FALSE.
    }

    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT {
        mLogWarn("STATS landing-impact status=no-impact").
        RETURN FALSE.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _geoDistance(
        impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL ok IS dist <= LAND_CFG["TARGET_TOLERANCE"].
    mLogWarn("STATS landing-impact status=" + ok
        + " distKm=" + ROUND(dist/1000,2)
        + " toleranceKm=" + ROUND(LAND_CFG["TARGET_TOLERANCE"]/1000,2)).
    RETURN ok.
}

GLOBAL FUNCTION landingImpactAcceptableForAssist {
    IF LAND_CFG["DEORBIT_OVERSHOOT"] <= 0 { RETURN landingImpactWithinTolerance(). }
    IF NOT ADDONS:TR:AVAILABLE { RETURN FALSE. }
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN FALSE. }
    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT { RETURN FALSE. }
    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _geoDistance(
        impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL maxDist IS LAND_CFG["DEORBIT_OVERSHOOT"]
        + LAND_CFG["DEORBIT_OVERSHOOT_TOLERANCE"].
    LOCAL ok IS dist <= maxDist.
    mLogWarn("STATS landing-impact-assist status=" + ok
        + " distKm=" + ROUND(dist/1000,2)
        + " allowedKm=" + ROUND(maxDist/1000,2)).
    RETURN ok.
}

LOCAL FUNCTION _geoDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL oRad IS SHIP:BODY:RADIUS.
    LOCAL dLat IS lat2 - lat1.
    LOCAL dLng IS lng2 - lng1.
    LOCAL a IS SIN(dLat/2)^2
        + COS(lat1) * COS(lat2) * SIN(dLng/2)^2.
    LOCAL c IS 2 * ARCSIN(MIN(1, SQRT(a))).
    RETURN oRad * c * CONSTANT:PI / 180.
}
