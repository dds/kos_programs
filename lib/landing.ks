// ============================================================
// landing.ks  -  Vacuum powered descent FSM (0:/lib/landing.ks)
//
// Entry points:
//   landExecute()
//   landingAssistStage()
//
// Target/config helpers live in landing_config.ks. Physics helpers live in
// landing_math.ks. Part operations live in vessel_hardware.ks.
// ============================================================

GLOBAL landingAbortFlag IS FALSE.

// ------------------------------------------------------------
// Terrain survey - one-shot flat spot check near target
// ------------------------------------------------------------

LOCAL FUNCTION _landingTerrainCheck {
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL radiusM IS LAND_CFG_TERRAIN_CHECK_RADIUS.
    LOCAL stepM IS LAND_CFG_TERRAIN_CHECK_STEP.
    IF radiusM <= 0 OR stepM <= 0 {
        RETURN LEXICON("LAT", targetLat, "LNG", targetLng, "SHIFTED", FALSE).
    }

    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(targetLat)).

    LOCAL bestLat IS targetLat.
    LOCAL bestLng IS targetLng.
    LOCAL bestScore IS 999999.
    LOCAL centerTerrain IS LATLNG(targetLat, targetLng):TERRAINHEIGHT.

    LOCAL northM IS -radiusM.
    UNTIL northM > radiusM {
        LOCAL eastM IS -radiusM.
        UNTIL eastM > radiusM {
            LOCAL sampleLat IS targetLat + northM * degPerM.
            LOCAL sampleLng IS targetLng + eastM * degPerM / lonScale.

            LOCAL hN IS LATLNG(sampleLat + stepM * degPerM, sampleLng):TERRAINHEIGHT.
            LOCAL hS IS LATLNG(sampleLat - stepM * degPerM, sampleLng):TERRAINHEIGHT.
            LOCAL hE IS LATLNG(sampleLat, sampleLng + stepM * degPerM / lonScale):TERRAINHEIGHT.
            LOCAL hW IS LATLNG(sampleLat, sampleLng - stepM * degPerM / lonScale):TERRAINHEIGHT.
            LOCAL slopeNS IS ABS(hN - hS) / (2 * stepM).
            LOCAL slopeEW IS ABS(hE - hW) / (2 * stepM).
            LOCAL slopePenalty IS (slopeNS + slopeEW) * 500.
            LOCAL distM IS SQRT(northM * northM + eastM * eastM).
            LOCAL score IS distM / 100 + slopePenalty.

            IF score < bestScore {
                SET bestScore TO score.
                SET bestLat TO sampleLat.
                SET bestLng TO sampleLng.
            }
            SET eastM TO eastM + stepM.
        }
        SET northM TO northM + stepM.
    }

    LOCAL shiftDist IS geoDistance(targetLat, targetLng, bestLat, bestLng).
    mLog("Terrain check: center elev=" + ROUND(centerTerrain,1)
        + "m  best score=" + ROUND(bestScore,1)
        + "  shift=" + ROUND(shiftDist,0) + "m.").

    IF shiftDist > 50 {
        mLog("Shifting target by " + ROUND(shiftDist,0) + "m to flatter terrain"
            + " lat=" + ROUND(bestLat,4) + " lng=" + ROUND(bestLng,4) + ".").
        SET LAND_CFG_TARGET_LAT TO bestLat.
        SET LAND_CFG_TARGET_LNG TO bestLng.
        IF ADDONS:TR:AVAILABLE {
            ADDONS:TR:SETTARGET(LATLNG(bestLat, bestLng)).
        }
        RETURN LEXICON(
            "LAT", bestLat,
            "LNG", bestLng,
            "ELEVATION", LATLNG(bestLat, bestLng):TERRAINHEIGHT,
            "SHIFTED", TRUE
        ).
    }

    RETURN LEXICON(
        "LAT", targetLat,
        "LNG", targetLng,
        "ELEVATION", centerTerrain,
        "SHIFTED", FALSE
    ).
}

// ------------------------------------------------------------
// FSM helpers
// ------------------------------------------------------------

LOCAL FUNCTION _landingStateLog {
    PARAMETER ctx.
    PARAMETER fromState.
    PARAMETER toState.
    PARAMETER reason.
    mLog("Landing state " + fromState + " -> " + toState + ": " + reason
        + " alt=" + ROUND(ALT:RADAR,0)
        + "m hs=" + ROUND(ctx["H_SPEED"],1)
        + " vs=" + ROUND(ctx["V_SPEED"],1) + ".").
}

LOCAL FUNCTION _landingBoolText {
    PARAMETER flag.
    RETURN CHOOSE "true" IF flag ELSE "false".
}

LOCAL FUNCTION _landingTrajImpactInfo {
    PARAMETER ctx.
    IF NOT ctx["HAS_TARGET"] { RETURN LEXICON("FOUND", FALSE, "DIST", 999999). }
    IF NOT ADDONS:TR:AVAILABLE { RETURN LEXICON("FOUND", FALSE, "DIST", 999999). }
    IF NOT ADDONS:TR:HASIMPACT { RETURN LEXICON("FOUND", FALSE, "DIST", 999999). }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL impactDist IS geoDistance(impactPos:LAT, impactPos:LNG,
        ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    RETURN LEXICON(
        "FOUND", TRUE,
        "LAT", impactPos:LAT,
        "LNG", impactPos:LNG,
        "DIST", impactDist
    ).
}

LOCAL FUNCTION _landingSetSteering {
    PARAMETER ctx.
    PARAMETER steeringVec.
    SET ctx["TARGET_STEERING"] TO steeringVec.
}

LOCAL FUNCTION _landingSetThrottle {
    PARAMETER ctx.
    PARAMETER throttleValue.
    SET ctx["TARGET_THROTTLE"] TO MAX(0, MIN(1, throttleValue)).
}

LOCAL FUNCTION _landingBottomRadar {
    RETURN MAX(0, SHIP:BOUNDS:BOTTOMALTRADAR).
}

LOCAL FUNCTION _landingTargetHeight {
    PARAMETER ctx.
    IF ctx["HAS_TARGET"] {
        RETURN MAX(0, SHIP:ALTITUDE - ctx["TARGET_ELEVATION"]).
    }
    RETURN ALT:RADAR.
}

LOCAL FUNCTION _landingBurnHeight {
    PARAMETER ctx.
    IF ctx["STATE"] = "VERTICAL_DESCENT" {
        RETURN _landingBottomRadar().
    }
    RETURN _landingTargetHeight(ctx).
}

LOCAL FUNCTION _landingCacheTick {
    PARAMETER ctx.
    LOCAL surfaceVel IS SHIP:VELOCITY:SURFACE.
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL hVel IS surfaceVel - (VDOT(surfaceVel, upVec) * upVec).
    SET ctx["SURFACE_VEL"] TO surfaceVel.
    SET ctx["UP_VEC"] TO upVec.
    SET ctx["POSITION"] TO SHIP:POSITION.
    SET ctx["H_VEL"] TO hVel.
    SET ctx["H_SPEED"] TO hVel:MAG.
    SET ctx["MAX_ACC"] TO lmMaxAcc().
    SET ctx["GRAV"] TO lmGravity().
    SET ctx["V_SPEED"] TO SHIP:VERTICALSPEED.
    SET ctx["DOWN_SPEED"] TO MAX(0, -ctx["V_SPEED"]).
}

LOCAL FUNCTION _landingTrajError {
    PARAMETER ctx.
    LOCAL impactInfo IS _landingTrajImpactInfo(ctx).
    IF NOT impactInfo["FOUND"] {
        RETURN LEXICON("FOUND", FALSE, "DIST", 999999,
            "ALONG", 999999, "CROSS", 999999,
            "CROSS_CORR", SHIP:UP:VECTOR).
    }

    LOCAL horizontalVel IS ctx["H_VEL"].
    IF horizontalVel:MAG < 0.1 {
        RETURN LEXICON("FOUND", TRUE, "DIST", impactInfo["DIST"],
            "ALONG", 0, "CROSS", impactInfo["DIST"],
            "CROSS_CORR", SHIP:UP:VECTOR).
    }

    LOCAL upVec IS ctx["UP_VEC"].
    LOCAL travelDir IS VXCL(upVec, horizontalVel):NORMALIZED.
    LOCAL targetGeo IS LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL impactGeo IS LATLNG(impactInfo["LAT"], impactInfo["LNG"]).
    LOCAL targetToImpact IS VXCL(upVec, impactGeo:POSITION - targetGeo:POSITION).
    LOCAL alongM IS VDOT(targetToImpact, travelDir).
    LOCAL crossVec IS targetToImpact - travelDir * alongM.
    LOCAL crossCorr IS upVec.
    IF crossVec:MAG > 0.01 { SET crossCorr TO (-crossVec):NORMALIZED. }

    RETURN LEXICON(
        "FOUND", TRUE,
        "DIST", impactInfo["DIST"],
        "ALONG", alongM,
        "CROSS", crossVec:MAG,
        "CROSS_CORR", crossCorr
    ).
}

LOCAL FUNCTION _landingSetState {
    PARAMETER ctx.
    PARAMETER nextState.
    PARAMETER reason.

    LOCAL prevState IS ctx["STATE"].
    IF prevState = nextState { RETURN. }
    _landingStateLog(ctx, prevState, nextState, reason).
    SET ctx["STATE"] TO nextState.
    SET ctx["STATE_ENTERED"] TO TIME:SECONDS.
    stateSet("landing_state", nextState).

    IF nextState = "BRAKING_BURN" {
        _landingSetThrottle(ctx, 1).
        HUDTEXT("BRAKING BURN", 3, 2, 16, YELLOW, FALSE).
    } ELSE IF nextState = "APPROACH" {
        HUDTEXT("APPROACH", 3, 2, 16, CYAN, FALSE).
    } ELSE IF nextState = "VERTICAL_DESCENT" {
        vesselDeployGear().
        HUDTEXT("VERTICAL DESCENT", 3, 2, 16, GREEN, FALSE).
    } ELSE IF nextState = "TOUCHDOWN" {
        _landingSetThrottle(ctx, 0).
    }
}

LOCAL FUNCTION _landingCoastTick {
    PARAMETER ctx.

    _landingSetThrottle(ctx, 0).
    _landingSetSteering(ctx, lmRetroSteering(
        ctx["H_VEL"], ctx["SURFACE_VEL"], ctx["UP_VEC"])).

    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL gravAcc IS ctx["GRAV"].
    LOCAL downSpeed IS ctx["DOWN_SPEED"].
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL horizontalAcc IS MAX(0.1, maxAcc * LAND_CFG_BRAKE_ACCEL_FRACTION).
    LOCAL brakeDist IS lmHorizontalBrakeDistance(
        horizontalSpeed, horizontalAcc).
    LOCAL burnDist IS lmVerticalBurnDistance(
        downSpeed, maxAcc, gravAcc).
    LOCAL burnHeight IS _landingBurnHeight(ctx).
    LOCAL distToTarget IS 999999.
    IF ctx["HAS_TARGET"] {
        SET distToTarget TO lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    }
    LOCAL trajErr IS _landingTrajError(ctx).
    LOCAL impactErr IS trajErr["DIST"].
    LOCAL alongErr IS trajErr["ALONG"].

    IF ctx["HAS_TARGET"] AND NOT ctx["TERRAIN_DONE"]
            AND ALT:RADAR <= LAND_CFG_GUIDANCE_ALT {
        LOCAL terrainResult IS _landingTerrainCheck(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        SET ctx["TERRAIN_DONE"] TO TRUE.
        IF terrainResult["SHIFTED"] {
            SET ctx["TARGET_LAT"] TO terrainResult["LAT"].
            SET ctx["TARGET_LNG"] TO terrainResult["LNG"].
            SET ctx["TARGET_ELEVATION"] TO terrainResult["ELEVATION"].
        }
    }

    HUDTEXT("COAST d=" + ROUND(distToTarget,0)
        + " brake=" + ROUND(brakeDist,0)
        + " trErr=" + ROUND(impactErr,0)
        + " along=" + ROUND(alongErr,0)
        + " hs=" + ROUND(horizontalSpeed,1),
        1, 2, 13, WHITE, FALSE).

    IF burnHeight <= burnDist * LAND_CFG_BURN_MARGIN + LAND_CFG_BRAKE_MARGIN {
        _landingSetState(ctx, "VERTICAL_DESCENT", "vertical burn gate").
    } ELSE IF trajErr["FOUND"]
            AND (alongErr >= 0
                OR ABS(alongErr) <= LAND_CFG_TR_BRAKE_WINDOW
                OR impactErr <= LAND_CFG_TR_BRAKE_WINDOW) {
        _landingSetState(ctx, "BRAKING_BURN", "TR impact reached target").
    } ELSE IF ctx["HAS_TARGET"]
            AND NOT trajErr["FOUND"]
            AND distToTarget <= brakeDist + LAND_CFG_BRAKE_MARGIN {
        _landingSetState(ctx, "BRAKING_BURN", "downrange <= brake distance").
    } ELSE IF NOT ctx["HAS_TARGET"] {
        LOCAL tti IS 999999.
        LOCAL radarAlt IS ALT:RADAR.
        IF radarAlt <= 0 {
            SET tti TO 0.
        } ELSE {
            LOCAL disc IS ctx["V_SPEED"] * ctx["V_SPEED"]
                + 2 * radarAlt * gravAcc.
            IF disc >= 0 AND gravAcc > 0 {
                SET tti TO (SQRT(disc) + ctx["V_SPEED"]) / gravAcc.
            }
        }
        LOCAL burnTime IS downSpeed / MAX(0.1, maxAcc - gravAcc).
        IF tti <= burnTime * LAND_CFG_BURN_MARGIN {
            _landingSetState(ctx, "BRAKING_BURN", "blind suicide burn gate").
        }
    }
}

LOCAL FUNCTION _landingBrakingTick {
    PARAMETER ctx.

    _landingSetThrottle(ctx, 1).

    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL gravAcc IS ctx["GRAV"].
    LOCAL downSpeed IS ctx["DOWN_SPEED"].
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL burnDist IS lmVerticalBurnDistance(
        downSpeed, maxAcc, gravAcc).
    LOCAL burnHeight IS _landingBurnHeight(ctx).
    LOCAL distToTarget IS 999999.
    IF ctx["HAS_TARGET"] {
        SET distToTarget TO lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    }

    LOCAL retroSteering IS lmRetroSteering(
        ctx["H_VEL"], ctx["SURFACE_VEL"], ctx["UP_VEC"]).
    LOCAL trajErr IS _landingTrajError(ctx).
    LOCAL impactErr IS trajErr["DIST"].
    LOCAL crossErr IS trajErr["CROSS"].
    LOCAL crossPid IS ctx["CROSS_PID"].
    IF trajErr["FOUND"] AND crossErr > LAND_CFG_GUIDANCE_CORRECTION_THRESHOLD {
        LOCAL biasDeg IS ABS(crossPid:UPDATE(TIME:SECONDS, crossErr)).
        LOCAL biasMag IS MIN(LAND_CFG_TR_BRAKE_BIAS, SIN(biasDeg)).
        _landingSetSteering(ctx,
            (retroSteering + trajErr["CROSS_CORR"] * biasMag):NORMALIZED).
    } ELSE {
        LOCAL pidReset IS crossPid:UPDATE(TIME:SECONDS, 0).
        _landingSetSteering(ctx, retroSteering).
    }
    SET ctx["CROSS_PID"] TO crossPid.

    HUDTEXT("BRAKE d=" + ROUND(distToTarget,0)
        + " trErr=" + ROUND(impactErr,0)
        + " x=" + ROUND(crossErr,0)
        + " hs=" + ROUND(horizontalSpeed,1)
        + " vs=" + ROUND(ctx["V_SPEED"],1),
        1, 2, 13, YELLOW, FALSE).

    IF ctx["HAS_TARGET"]
            AND (horizontalSpeed <= LAND_CFG_TERMINAL_HSPEED
                OR ALT:RADAR <= LAND_CFG_TERMINAL_ALT) {
        _landingSetState(ctx, "APPROACH", "terminal handoff").
    } ELSE IF burnHeight <= burnDist * LAND_CFG_BURN_MARGIN
            AND burnHeight <= LAND_CFG_HOVER_ALT {
        _landingSetState(ctx, "VERTICAL_DESCENT", "low vertical gate").
    } ELSE IF ctx["HAS_TARGET"]
            AND (horizontalSpeed <= LAND_CFG_APPROACH_HSPEED
                OR distToTarget <= LAND_CFG_APPROACH_RADIUS) {
        _landingSetState(ctx, "APPROACH", "horizontal speed/range captured").
    } ELSE IF NOT ctx["HAS_TARGET"] AND horizontalSpeed < LAND_CFG_APPROACH_HSPEED {
        _landingSetState(ctx, "VERTICAL_DESCENT", "blind horizontal velocity killed").
    }
}

LOCAL FUNCTION _landingApproachTick {
    PARAMETER ctx.

    LOCAL distToTarget IS lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL approachHeight IS _landingTargetHeight(ctx).
    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL horizontalAcc IS MAX(0.1, maxAcc * LAND_CFG_BRAKE_ACCEL_FRACTION).
    LOCAL desiredSpeed IS MIN(LAND_CFG_MAX_APPROACH_SPEED,
        SQRT(MAX(0, 2 * horizontalAcc * MAX(0, distToTarget - LAND_CFG_VERTICAL_RADIUS)))).
    _landingSetSteering(ctx, lmApproachSteering(
        ctx["TARGET_LAT"], ctx["TARGET_LNG"], desiredSpeed, ctx["H_VEL"],
        ctx["UP_VEC"], ctx["POSITION"])).

    LOCAL targetVs IS -lmDescentSpeed(
        approachHeight, LAND_CFG_TOUCHDOWN_SPEED, LAND_CFG_UPRIGHT_ALT).
    _landingSetThrottle(ctx, lmVerticalThrottle(
        targetVs, ctx["MAX_ACC"], ctx["GRAV"], ctx["V_SPEED"])).

    HUDTEXT("APPROACH d=" + ROUND(distToTarget,0)
        + " hT=" + ROUND(approachHeight,0)
        + " hs=" + ROUND(horizontalSpeed,1)
        + "/" + ROUND(desiredSpeed,1)
        + " vs=" + ROUND(ctx["V_SPEED"],1),
        1, 2, 13, CYAN, FALSE).

    IF distToTarget <= LAND_CFG_VERTICAL_RADIUS
            AND horizontalSpeed <= LAND_CFG_VERTICAL_HSPEED {
        _landingSetState(ctx, "VERTICAL_DESCENT", "over target").
    } ELSE IF approachHeight <= LAND_CFG_HOVER_ALT
            AND horizontalSpeed <= LAND_CFG_APPROACH_HSPEED {
        _landingSetState(ctx, "VERTICAL_DESCENT", "hover altitude").
    }
}

LOCAL FUNCTION _landingVerticalTick {
    PARAMETER ctx.
    LOCAL bottomAlt IS _landingBottomRadar().
    LOCAL horizontalSpeed IS ctx["H_SPEED"].

    IF bottomAlt <= LAND_CFG_UPRIGHT_ALT {
        _landingSetSteering(ctx, SHIP:UP:VECTOR).
    } ELSE IF ctx["HAS_TARGET"] {
        _landingSetSteering(ctx, lmApproachSteering(
            ctx["TARGET_LAT"], ctx["TARGET_LNG"], 0, ctx["H_VEL"],
            ctx["UP_VEC"], ctx["POSITION"])).
    } ELSE {
        _landingSetSteering(ctx, lmHoverSteering(
            ctx["H_VEL"], ctx["UP_VEC"])).
    }

    LOCAL targetVs IS -lmDescentSpeed(
        bottomAlt, LAND_CFG_TOUCHDOWN_SPEED, LAND_CFG_UPRIGHT_ALT).
    _landingSetThrottle(ctx, lmVerticalThrottle(
        targetVs, ctx["MAX_ACC"], ctx["GRAV"], ctx["V_SPEED"])).

    HUDTEXT("VERT bottom=" + ROUND(bottomAlt,0)
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + "/" + ROUND(targetVs,1)
        + " hs=" + ROUND(horizontalSpeed,1),
        1, 2, 13, GREEN, FALSE).
}

LOCAL FUNCTION _landingFinish {
    PARAMETER ctx.

    _landingSetState(ctx, "TOUCHDOWN", "surface contact").
    vesselLandingCleanup().
    vesselSetReactionWheelAuthority(100).
    mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
        + "  lat=" + ROUND(SHIP:LATITUDE,4)
        + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
    HUDTEXT("TOUCHDOWN!", 8, 2, 20, GREEN, FALSE).
    stateSet("landing_lat",  SHIP:LATITUDE).
    stateSet("landing_lng",  SHIP:LONGITUDE).
    stateSet("landing_time", TIME:SECONDS).
    stateSet("landing_state", "TOUCHDOWN").
    vesselDeployAntennas().
    vesselDeploySolarPanels().
}

// ------------------------------------------------------------
// Main entry points
// ------------------------------------------------------------

GLOBAL FUNCTION landExecute {
    mLogPhase("LANDING").
    landingApplyMissionConfig().
    SET landingAbortFlag TO FALSE.

    IF SHIP:BODY:ATM:EXISTS {
        mLogWarn("Vacuum landing FSM requested on body with atmosphere; continuing with powered descent only.").
    }

    LOCAL landingTarget IS landingResolveTarget().
    LOCAL hasTarget IS landingTarget["FOUND"].
    IF hasTarget {
        SET LAND_CFG_TARGET_LAT TO landingTarget["LAT"].
        SET LAND_CFG_TARGET_LNG TO landingTarget["LNG"].
        mLog("Landing target: " + ROUND(landingTarget["LAT"],4)
            + "," + ROUND(landingTarget["LNG"],4)
            + " from " + landingTarget["SOURCE"] + ".").
    } ELSE {
        mLogWarn("No landing target resolved; executing safe vertical powered descent.").
    }

    LOCAL targetElevation IS 0.
    IF hasTarget {
        SET targetElevation TO LATLNG(LAND_CFG_TARGET_LAT, LAND_CFG_TARGET_LNG):TERRAINHEIGHT.
    }
    LOCAL crossPid IS PIDLOOP(
        LAND_CFG_CROSS_PID_KP,
        LAND_CFG_CROSS_PID_KI,
        LAND_CFG_CROSS_PID_KD,
        LAND_CFG_CROSS_PID_MIN,
        LAND_CFG_CROSS_PID_MAX).
    SET crossPid:SETPOINT TO 0.

    LOCAL ctx IS LEXICON(
        "STATE", "COAST",
        "STATE_ENTERED", TIME:SECONDS,
        "HAS_TARGET", hasTarget,
        "TARGET_LAT", LAND_CFG_TARGET_LAT,
        "TARGET_LNG", LAND_CFG_TARGET_LNG,
        "TARGET_ELEVATION", targetElevation,
        "CROSS_PID", crossPid,
        "TERRAIN_DONE", FALSE,
        "TARGET_STEERING", SHIP:UP:VECTOR,
        "TARGET_THROTTLE", 0
    ).
    stateSet("landing_state", "COAST").

    IF hasTarget AND ADDONS:TR:AVAILABLE {
        ADDONS:TR:SETTARGET(LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"])).
        mLog("Trajectories target set for powered descent guidance.").
    }

    SET SAS TO FALSE.
    vesselDeployGear().
    LOCK STEERING TO ctx["TARGET_STEERING"].
    LOCK THROTTLE TO ctx["TARGET_THROTTLE"].
    mLog("Landing setup target=" + _landingBoolText(hasTarget)
        + " tr=" + _landingBoolText(ADDONS:TR:AVAILABLE) + ".").

    UNTIL landingAbortFlag
            OR SHIP:STATUS = "LANDED"
            OR SHIP:STATUS = "SPLASHED" {
        _landingCacheTick(ctx).

        IF vesselNeedsStage() {
            LOCAL oldState IS ctx["STATE"].
            _landingSetThrottle(ctx, 0).
            vesselStageForLanding().
            IF oldState = "BRAKING_BURN" { _landingSetThrottle(ctx, 1). }
        }

        IF ctx["STATE"] = "COAST" {
            _landingCoastTick(ctx).
        } ELSE IF ctx["STATE"] = "BRAKING_BURN" {
            _landingBrakingTick(ctx).
        } ELSE IF ctx["STATE"] = "APPROACH" {
            _landingApproachTick(ctx).
        } ELSE IF ctx["STATE"] = "VERTICAL_DESCENT" {
            _landingVerticalTick(ctx).
        }

        WAIT 0.05.
    }

    IF landingAbortFlag {
        vesselLandingCleanup().
        RETURN.
    }
    _landingFinish(ctx).
}

GLOBAL FUNCTION landingAssistStage {
    mLogPhase("LANDING ASSIST").
    SET landingAbortFlag TO FALSE.

    landExecute().

    IF NOT (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED") {
        mLogWarn("Not on surface after assist descent.").
        RETURN FALSE.
    }
    RETURN TRUE.
}
