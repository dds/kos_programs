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
GLOBAL landingSteeringTarget IS V(0, 0, 0).
GLOBAL LANDING_HUD_INTERVAL IS 5.
GLOBAL LANDING_HUD_INTERVAL_MAX IS 45.
GLOBAL LANDING_HUD_INTERVAL_ETA_SCALE IS 3.
GLOBAL LANDING_HUD_NOTICE_INTERVAL IS 5.
GLOBAL LANDING_HUD_NOTICE_HOLD_TIME IS 6.
GLOBAL LANDING_HUD_NOTICE_LOOKAHEAD IS 90.
GLOBAL LANDING_BRAKE_ALIGN_LEAD IS 20.
GLOBAL LANDING_TOUCHDOWN_ALT IS 3.
GLOBAL LANDING_TOUCHDOWN_VSPEED IS 1.
GLOBAL LANDING_TOUCHDOWN_HSPEED IS 0.3.
GLOBAL LANDING_TOUCHDOWN_SETTLE_TICKS IS 120.

// ------------------------------------------------------------
// Terrain survey - one-shot flat spot check near target
// ------------------------------------------------------------

LOCAL FUNCTION _landingTerrainCheck {
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL radiusM IS TERRAIN_CHECK_RADIUS.
    LOCAL stepM IS TERRAIN_CHECK_STEP.
    IF radiusM <= 0 OR stepM <= 0 {
        RETURN LEXICON(
            "LAT", targetLat,
            "LNG", targetLng,
            "ELEVATION", LATLNG(targetLat, targetLng):TERRAINHEIGHT,
            "SHIFTED", FALSE
        ).
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

    IF shiftDist > 5 {
        mLog("Shifting target by " + ROUND(shiftDist,0) + "m to flatter terrain"
            + " lat=" + ROUND(bestLat,4) + " lng=" + ROUND(bestLng,4) + ".").
        SET TARGET_LAT TO bestLat.
        SET TARGET_LNG TO bestLng.
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
    SET landingSteeringTarget TO steeringVec.
    LOCK STEERING TO landingSteeringTarget.
}

LOCAL FUNCTION _landingSetThrottle {
    PARAMETER ctx.
    PARAMETER throttleValue.
    SET ctx["TARGET_THROTTLE"] TO MAX(0, MIN(1, throttleValue)).
}

LOCAL FUNCTION _landingAdaptiveLogInterval {
    PARAMETER etaSeconds IS 0.

    IF etaSeconds <= 0 { RETURN LANDING_HUD_INTERVAL. }
    RETURN MAX(LANDING_HUD_INTERVAL,
        MIN(LANDING_HUD_INTERVAL_MAX,
            etaSeconds / LANDING_HUD_INTERVAL_ETA_SCALE)).
}

LOCAL FUNCTION _landingHudText {
    PARAMETER ctx.
    PARAMETER text.
    PARAMETER holdTime.
    PARAMETER style.
    PARAMETER size.
    PARAMETER color.
    PARAMETER blink.
    PARAMETER etaSeconds IS 0.

    LOCAL logInterval IS _landingAdaptiveLogInterval(etaSeconds).
    IF TIME:SECONDS - ctx["HUD_LAST"] < logInterval { RETURN. }
    SET ctx["HUD_LAST"] TO TIME:SECONDS.
    mLog(text).
}

LOCAL FUNCTION _landingHudNotice {
    PARAMETER ctx.
    PARAMETER text.
    PARAMETER color.
    PARAMETER forceFlag IS FALSE.
    PARAMETER noticeInterval IS 0.

    IF noticeInterval <= 0 { SET noticeInterval TO LANDING_HUD_NOTICE_INTERVAL. }
    IF NOT forceFlag
            AND TIME:SECONDS - ctx["HUD_NOTICE_LAST"]
                < noticeInterval {
        RETURN.
    }
    IF NOT forceFlag AND text = ctx["HUD_NOTICE_TEXT"] {
        RETURN.
    }
    SET ctx["HUD_NOTICE_TEXT"] TO text.
    SET ctx["HUD_NOTICE_LAST"] TO TIME:SECONDS.
    HUDTEXT(text, LANDING_HUD_NOTICE_HOLD_TIME,
        2, 16, color, FALSE).
}

LOCAL FUNCTION _landingHudEtaNotice {
    PARAMETER ctx.
    PARAMETER actionText.
    PARAMETER etaSeconds.
    PARAMETER color.

    IF etaSeconds < 0 { SET etaSeconds TO 0. }
    IF etaSeconds > LANDING_HUD_NOTICE_LOOKAHEAD { RETURN. }

    LOCAL roundedEta IS ROUND(etaSeconds, 0).
    LOCAL noticeText IS actionText + " in "
        + roundedEta + " seconds.".
    _landingHudNotice(ctx, noticeText, color, FALSE,
        _landingAdaptiveLogInterval(etaSeconds)).
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

LOCAL FUNCTION _landingDownrangeToTarget {
    PARAMETER ctx.
    LOCAL targetVec IS VXCL(ctx["UP_VEC"],
        LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]):POSITION
            - ctx["POSITION"]).
    IF ctx["H_SPEED"] < 0.1 { RETURN targetVec:MAG. }
    RETURN VDOT(targetVec, ctx["H_VEL"]:NORMALIZED).
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
            "ALONG", 999999, "CROSS", 999999, "CROSS_SIGNED", 999999,
            "CROSS_AXIS", SHIP:UP:VECTOR).
    }

    LOCAL horizontalVel IS ctx["H_VEL"].
    IF horizontalVel:MAG < 0.1 {
        RETURN LEXICON("FOUND", TRUE, "DIST", impactInfo["DIST"],
            "ALONG", 0, "CROSS", impactInfo["DIST"], "CROSS_SIGNED", 0,
            "CROSS_AXIS", SHIP:UP:VECTOR).
    }

    LOCAL upVec IS ctx["UP_VEC"].
    LOCAL travelDir IS VXCL(upVec, horizontalVel):NORMALIZED.
    LOCAL crossAxis IS VCRS(travelDir, upVec):NORMALIZED.
    LOCAL targetGeo IS LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL impactGeo IS LATLNG(impactInfo["LAT"], impactInfo["LNG"]).
    LOCAL targetToImpact IS VXCL(upVec, impactGeo:POSITION - targetGeo:POSITION).
    LOCAL alongM IS VDOT(targetToImpact, travelDir).
    LOCAL crossVec IS targetToImpact - travelDir * alongM.
    LOCAL signedCross IS VDOT(crossVec, crossAxis).

    RETURN LEXICON(
        "FOUND", TRUE,
        "DIST", impactInfo["DIST"],
        "ALONG", alongM,
        "CROSS", crossVec:MAG,
        "CROSS_SIGNED", signedCross,
        "CROSS_AXIS", crossAxis
    ).
}

LOCAL FUNCTION _landingTargetRefineSteering {
    PARAMETER ctx.
    PARAMETER impactInfo.

    LOCAL upVec IS ctx["UP_VEC"].
    LOCAL horizontalVel IS ctx["H_VEL"].
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL maxLean IS SIN(MAX_TILT).
    LOCAL leanVec IS V(0,0,0).
    LOCAL retroLeanLimit IS maxLean.
    IF impactInfo["FOUND"]
            AND impactInfo["DIST"] > LANDING_TARGET_REFINE_IMPACT_TOLERANCE {
        SET retroLeanLimit TO maxLean * LANDING_TARGET_REFINE_RETRO_WEIGHT.
    }

    IF horizontalSpeed > 0.1 {
        SET leanVec TO leanVec
            + (-horizontalVel):NORMALIZED
                * MIN(retroLeanLimit,
                    horizontalSpeed / LANDING_TARGET_REFINE_RETRO_RESPONSE).
    }

    IF impactInfo["FOUND"] {
        LOCAL targetGeo IS LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        LOCAL impactGeo IS LATLNG(impactInfo["LAT"], impactInfo["LNG"]).
        LOCAL impactToTarget IS VXCL(upVec,
            targetGeo:POSITION - impactGeo:POSITION).
        IF impactToTarget:MAG > 1 {
            LOCAL impactLean IS MIN(
                maxLean * LANDING_TARGET_REFINE_IMPACT_WEIGHT,
                impactToTarget:MAG / LANDING_TARGET_REFINE_IMPACT_SCALE
                    * maxLean).
            SET leanVec TO leanVec
                + impactToTarget:NORMALIZED * impactLean.
        }
    }

    IF leanVec:MAG < 0.01 { RETURN upVec. }
    IF leanVec:MAG > maxLean {
        SET leanVec TO leanVec:NORMALIZED * maxLean.
    }
    RETURN (upVec + leanVec):NORMALIZED.
}

LOCAL FUNCTION _landingSolarRollSteering {
    PARAMETER forwardVec.
    PARAMETER upVec.

    IF forwardVec:MAG < 0.01 { RETURN upVec. }
    LOCAL fwd IS forwardVec:NORMALIZED.
    LOCAL sunVec IS VXCL(fwd, SUN:POSITION - SHIP:POSITION).
    IF sunVec:MAG < 0.01 { RETURN fwd. }
    RETURN LOOKDIRUP(fwd, sunVec:NORMALIZED).
}

LOCAL FUNCTION _landingTouchdownSettled {
    PARAMETER ctx.

    LOCAL onSurface IS SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    LOCAL slowEnough IS ABS(ctx["V_SPEED"]) <= LANDING_TOUCHDOWN_VSPEED
        AND ctx["H_SPEED"] <= LANDING_TOUCHDOWN_HSPEED.
    IF onSurface AND _landingBottomRadar() <= LANDING_TOUCHDOWN_ALT
            AND slowEnough {
        SET ctx["TOUCHDOWN_TICKS"] TO ctx["TOUCHDOWN_TICKS"] + 1.
    } ELSE {
        SET ctx["TOUCHDOWN_TICKS"] TO 0.
    }
    RETURN ctx["TOUCHDOWN_TICKS"] >= LANDING_TOUCHDOWN_SETTLE_TICKS.
}

LOCAL FUNCTION _landingBrakeGateInfo {
    PARAMETER ctx.

    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL gravAcc IS ctx["GRAV"].
    LOCAL downSpeed IS ctx["DOWN_SPEED"].
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL horizontalAcc IS MAX(0.1, maxAcc * BRAKE_ACCEL_FRACTION).
    LOCAL brakeDist IS lmHorizontalBrakeDistance(
        horizontalSpeed, horizontalAcc).
    LOCAL burnDist IS lmVerticalBurnDistance(
        downSpeed, maxAcc, gravAcc).
    LOCAL burnHeight IS _landingBurnHeight(ctx).
    LOCAL distToTarget IS 999999.
    LOCAL downrangeToTarget IS 999999.
    IF ctx["HAS_TARGET"] {
        SET distToTarget TO lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        SET downrangeToTarget TO _landingDownrangeToTarget(ctx).
    }

    LOCAL hBrakeGate IS brakeDist + BRAKE_MARGIN.
    LOCAL hBrakeEta IS 999999.
    IF ctx["HAS_TARGET"] AND downrangeToTarget > 0 {
        IF downrangeToTarget <= hBrakeGate {
            SET hBrakeEta TO 0.
        } ELSE IF horizontalSpeed > 0.1 {
            SET hBrakeEta TO (downrangeToTarget - hBrakeGate)
                / horizontalSpeed.
        }
    }

    LOCAL vBurnGate IS burnDist * BURN_MARGIN + BRAKE_MARGIN.
    LOCAL vBurnEta IS 999999.
    LOCAL vNow IS ctx["DOWN_SPEED"] > 0.5 AND burnHeight <= vBurnGate.
    IF vNow {
        SET vBurnEta TO 0.
    } ELSE IF ctx["V_SPEED"] < 0 AND gravAcc > 0 {
        LOCAL vDelta IS burnHeight - vBurnGate.
        LOCAL vDisc IS ctx["V_SPEED"] * ctx["V_SPEED"] + 2 * vDelta * gravAcc.
        IF vDisc >= 0 {
            SET vBurnEta TO MAX(0, (SQRT(vDisc) + ctx["V_SPEED"]) / gravAcc).
        }
    }

    LOCAL hNow IS ctx["HAS_TARGET"] AND downrangeToTarget > 0
        AND downrangeToTarget <= hBrakeGate.
    LOCAL hSuppressed IS FALSE.
    IF hNow AND burnHeight > TERRAIN_SAFE_ALT
            AND burnHeight > hBrakeGate * 2
            AND vBurnEta > 60 {
        SET hNow TO FALSE.
        SET hBrakeEta TO 999999.
        SET hSuppressed TO TRUE.
    }
    LOCAL hOvershot IS ctx["HAS_TARGET"] AND downrangeToTarget <= 0
        AND ctx["V_SPEED"] < 0
        AND burnHeight <= TERRAIN_SAFE_ALT.

    RETURN LEXICON(
        "DIST", distToTarget,
        "DOWNRANGE", downrangeToTarget,
        "H_BRAKE", brakeDist,
        "H_GATE", hBrakeGate,
        "H_ETA", hBrakeEta,
        "H_NOW", hNow,
        "H_SUPPRESSED", hSuppressed,
        "H_OVERSHOT", hOvershot,
        "V_GATE", vBurnGate,
        "V_ETA", vBurnEta,
        "V_NOW", vNow,
        "MAX_ACC", maxAcc,
        "GRAV", gravAcc,
        "DOWN_SPEED", downSpeed,
        "H_SPEED", horizontalSpeed
    ).
}

LOCAL FUNCTION _landingBrakeSteeringInfo {
    PARAMETER ctx.

    LOCAL retroSteering IS lmRetroSteering(
        ctx["H_VEL"], ctx["SURFACE_VEL"], ctx["UP_VEC"]).
    LOCAL hardBrake IS ctx["H_SPEED"] > APPROACH_HSPEED
        AND _landingBurnHeight(ctx) > HOVER_ALT * 2.
    IF hardBrake AND ctx["H_VEL"]:MAG > 0.5 {
        SET retroSteering TO ((-ctx["H_VEL"]):NORMALIZED
            + ctx["UP_VEC"] * LANDING_HARD_BRAKE_UP_BIAS):NORMALIZED.
    }
    LOCAL trajErr IS _landingTrajError(ctx).
    LOCAL impactErr IS trajErr["DIST"].
    LOCAL crossErr IS trajErr["CROSS_SIGNED"].
    LOCAL crossAbs IS trajErr["CROSS"].
    LOCAL crossPid IS ctx["CROSS_PID"].
    LOCAL steeringTarget IS retroSteering.
    LOCAL biasMag IS 0.
    IF trajErr["FOUND"] AND crossAbs > GUIDANCE_CORRECTION_THRESHOLD {
        LOCAL biasDeg IS crossPid:UPDATE(TIME:SECONDS, crossErr).
        SET biasMag TO MAX(-TR_BRAKE_BIAS,
            MIN(TR_BRAKE_BIAS, SIN(biasDeg))).
        SET steeringTarget TO (retroSteering
            + trajErr["CROSS_AXIS"] * biasMag):NORMALIZED.
    } ELSE {
        crossPid:RESET().
    }
    _landingSetSteering(ctx, steeringTarget).
    SET ctx["CROSS_PID"] TO crossPid.

    RETURN LEXICON(
        "IMPACT_ERR", impactErr,
        "CROSS_ERR", crossErr,
        "CROSS_ABS", crossAbs,
        "ALIGN_ERR", VANG(SHIP:FACING:FOREVECTOR, steeringTarget),
        "RETRO_ERR", VANG(SHIP:FACING:FOREVECTOR, retroSteering),
        "BIAS", biasMag,
        "HARD", hardBrake
    ).
}

LOCAL FUNCTION _landingCoastMccBurnVector {
    PARAMETER ctx.
    PARAMETER trajErr.

    LOCAL upVec IS ctx["UP_VEC"].
    LOCAL horizontalVel IS ctx["H_VEL"].
    IF horizontalVel:MAG < 0.1 {
        RETURN LEXICON("VALID", FALSE, "VEC", upVec, "MAG", 0).
    }

    LOCAL travelDir IS VXCL(upVec, horizontalVel):NORMALIZED.
    LOCAL correctionVec IS ((0 - trajErr["ALONG"]) * travelDir)
        + ((0 - trajErr["CROSS_SIGNED"]) * trajErr["CROSS_AXIS"]).
    LOCAL burnVec IS VXCL(upVec, correctionVec).
    IF burnVec:MAG < 1 {
        RETURN LEXICON("VALID", FALSE, "VEC", upVec, "MAG", burnVec:MAG).
    }
    RETURN LEXICON("VALID", TRUE, "VEC", burnVec:NORMALIZED, "MAG", burnVec:MAG).
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

    IF nextState = "BRAKE_ALIGN" {
        _landingSetThrottle(ctx, 0).
        LOCAL alignSteerInfo IS _landingBrakeSteeringInfo(ctx).
        mLog("BRAKE ALIGN steering: err="
            + ROUND(alignSteerInfo["ALIGN_ERR"],1)
            + "deg retroErr=" + ROUND(alignSteerInfo["RETRO_ERR"],1)
            + "deg bias=" + ROUND(alignSteerInfo["BIAS"],3)
            + " hard=" + _landingBoolText(alignSteerInfo["HARD"]) + ".").
        _landingHudNotice(ctx, "Performing braking alignment.", YELLOW, TRUE).
    } ELSE IF nextState = "BRAKING_BURN" {
        LOCAL burnSteerInfo IS _landingBrakeSteeringInfo(ctx).
        mLog("BRAKING BURN steering: err="
            + ROUND(burnSteerInfo["ALIGN_ERR"],1)
            + "deg retroErr=" + ROUND(burnSteerInfo["RETRO_ERR"],1)
            + "deg bias=" + ROUND(burnSteerInfo["BIAS"],3)
            + " hard=" + _landingBoolText(burnSteerInfo["HARD"]) + ".").
        _landingSetThrottle(ctx, 1).
        _landingHudNotice(ctx, "Performing braking burn.", YELLOW, TRUE).
    } ELSE IF nextState = "COAST_MCC" {
        _landingSetThrottle(ctx, 0).
        SET ctx["MCC_PULSE_UNTIL"] TO 0.
        SET ctx["MCC_SETTLE_UNTIL"] TO 0.
        _landingHudNotice(ctx, "Correcting landing impact point.", CYAN, TRUE).
    } ELSE IF nextState = "APPROACH" {
        _landingHudNotice(ctx, "Performing approach.", CYAN, TRUE).
    } ELSE IF nextState = "TARGET_REFINE" {
        _landingHudNotice(ctx, "Neutralizing lateral drift for approach.", CYAN, TRUE).
    } ELSE IF nextState = "HOVER_REFINE" {
        vesselDeployGear().
        _landingHudNotice(ctx, "Hovering to refine target coordinates.", CYAN, TRUE).
    } ELSE IF nextState = "VERTICAL_DESCENT" {
        vesselDeployGear().
        _landingHudNotice(ctx, "Performing vertical descent.", GREEN, TRUE).
    } ELSE IF nextState = "TOUCHDOWN" {
        _landingSetThrottle(ctx, 0).
        _landingHudNotice(ctx, "Touchdown.", GREEN, TRUE).
    }
}

LOCAL FUNCTION _landingCoastTick {
    PARAMETER ctx.

    _landingSetThrottle(ctx, 0).
    _landingSetSteering(ctx, lmRetroSteering(
        ctx["H_VEL"], ctx["SURFACE_VEL"], ctx["UP_VEC"])).

    IF ctx["HAS_TARGET"] AND NOT ctx["TERRAIN_DONE"]
            AND ALT:RADAR <= GUIDANCE_ALT {
        LOCAL terrainResult IS _landingTerrainCheck(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        SET ctx["TERRAIN_DONE"] TO TRUE.
        IF terrainResult["SHIFTED"] {
            SET ctx["TARGET_LAT"] TO terrainResult["LAT"].
            SET ctx["TARGET_LNG"] TO terrainResult["LNG"].
            SET ctx["TARGET_ELEVATION"] TO terrainResult["ELEVATION"].
        }
    }

    LOCAL gate IS _landingBrakeGateInfo(ctx).
    LOCAL nextBrakeEta IS MIN(gate["H_ETA"], gate["V_ETA"]).
    LOCAL coastTransitionEta IS nextBrakeEta.
    IF ctx["HAS_TARGET"] {
        SET coastTransitionEta TO nextBrakeEta - LANDING_BRAKE_ALIGN_LEAD.
    }

    _landingHudText(ctx, "COAST d=" + ROUND(gate["DIST"],0)
        + " dr=" + ROUND(gate["DOWNRANGE"],0)
        + " hBrake=" + ROUND(gate["H_BRAKE"],0)
        + " hEta=" + ROUND(gate["H_ETA"],0)
        + " vEta=" + ROUND(gate["V_ETA"],0)
        + " hSupp=" + _landingBoolText(gate["H_SUPPRESSED"])
        + " hOver=" + _landingBoolText(gate["H_OVERSHOT"])
        + " hs=" + ROUND(gate["H_SPEED"],1),
        1, 2, 13, WHITE, FALSE, coastTransitionEta).

    IF ctx["HAS_TARGET"] AND nextBrakeEta < 999999 {
        _landingHudEtaNotice(ctx, "Braking alignment",
            nextBrakeEta - LANDING_BRAKE_ALIGN_LEAD, YELLOW).
    } ELSE IF nextBrakeEta < 999999 {
        _landingHudEtaNotice(ctx, "Braking burn", nextBrakeEta, YELLOW).
    }

    IF ctx["HAS_TARGET"]
            AND nextBrakeEta < 999999
            AND nextBrakeEta > LANDING_COAST_MCC_MIN_BRAKE_ETA {
        LOCAL trajErr IS _landingTrajError(ctx).
        IF trajErr["FOUND"]
                AND trajErr["DIST"] > LANDING_COAST_MCC_TRIGGER_DIST {
            _landingSetState(ctx, "COAST_MCC",
                "impact miss before brake gate").
            RETURN.
        }
    }

    IF gate["V_NOW"] {
        IF ctx["HAS_TARGET"] {
            _landingSetState(ctx, "BRAKING_BURN", "vertical burn gate").
        } ELSE {
            _landingSetState(ctx, "VERTICAL_DESCENT", "vertical burn gate").
        }
    } ELSE IF ctx["HAS_TARGET"] AND gate["H_NOW"] {
        _landingSetState(ctx, "BRAKING_BURN", "downrange <= brake distance").
    } ELSE IF ctx["HAS_TARGET"] AND gate["H_OVERSHOT"] {
        _landingSetState(ctx, "BRAKING_BURN", "target passed below safe altitude").
    } ELSE IF ctx["HAS_TARGET"]
            AND MIN(gate["H_ETA"], gate["V_ETA"]) <= LANDING_BRAKE_ALIGN_LEAD {
        _landingSetState(ctx, "BRAKE_ALIGN", "brake alignment lead").
    } ELSE IF NOT ctx["HAS_TARGET"] {
        LOCAL tti IS 999999.
        LOCAL radarAlt IS ALT:RADAR.
        IF radarAlt <= 0 {
            SET tti TO 0.
        } ELSE {
            LOCAL disc IS ctx["V_SPEED"] * ctx["V_SPEED"]
                + 2 * radarAlt * gate["GRAV"].
            IF disc >= 0 AND gate["GRAV"] > 0 {
                SET tti TO (SQRT(disc) + ctx["V_SPEED"]) / gate["GRAV"].
            }
        }
        LOCAL burnTime IS gate["DOWN_SPEED"]
            / MAX(0.1, gate["MAX_ACC"] - gate["GRAV"]).
        IF tti <= burnTime * BURN_MARGIN {
            _landingSetState(ctx, "BRAKING_BURN", "blind suicide burn gate").
        }
    }
}

LOCAL FUNCTION _landingCoastMccTick {
    PARAMETER ctx.

    IF NOT ctx:HASKEY("MCC_PULSE_UNTIL") {
        SET ctx["MCC_PULSE_UNTIL"] TO 0.
    }
    IF NOT ctx:HASKEY("MCC_SETTLE_UNTIL") {
        SET ctx["MCC_SETTLE_UNTIL"] TO 0.
    }

    LOCAL gate IS _landingBrakeGateInfo(ctx).
    LOCAL nextBrakeEta IS MIN(gate["H_ETA"], gate["V_ETA"]).
    IF gate["H_OVERSHOT"] OR gate["H_NOW"] OR gate["V_NOW"]
            OR nextBrakeEta <= LANDING_BRAKE_ALIGN_LEAD {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "MCC complete before brake gate").
        RETURN.
    }
    IF ctx["V_SPEED"] > LANDING_COAST_MCC_CLIMB_LIMIT {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "MCC climb guard").
        RETURN.
    }

    LOCAL trajErr IS _landingTrajError(ctx).
    IF NOT trajErr["FOUND"] {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "MCC lost trajectory prediction").
        RETURN.
    }
    IF trajErr["DIST"] <= LANDING_COAST_MCC_ACCEPT_DIST {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "MCC impact corrected").
        RETURN.
    }

    LOCAL burnInfo IS _landingCoastMccBurnVector(ctx, trajErr).
    IF NOT burnInfo["VALID"] {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "MCC has no horizontal correction").
        RETURN.
    }

    LOCAL burnVec IS burnInfo["VEC"].
    LOCAL steeringTarget IS LOOKDIRUP(burnVec, ctx["UP_VEC"]).
    _landingSetSteering(ctx, steeringTarget).

    LOCAL alignErr IS VANG(SHIP:FACING:FOREVECTOR, burnVec).
    LOCAL upDot IS ABS(VDOT(SHIP:FACING:FOREVECTOR, ctx["UP_VEC"])).
    LOCAL canBurn IS alignErr <= LANDING_COAST_MCC_ALIGN_DEG
        AND upDot <= LANDING_COAST_MCC_MAX_UP_DOT.

    IF TIME:SECONDS < ctx["MCC_PULSE_UNTIL"] {
        IF canBurn {
            _landingSetThrottle(ctx, LANDING_COAST_MCC_THROTTLE).
        } ELSE {
            _landingSetThrottle(ctx, 0).
            SET ctx["MCC_PULSE_UNTIL"] TO 0.
        }
    } ELSE IF TIME:SECONDS < ctx["MCC_SETTLE_UNTIL"] {
        _landingSetThrottle(ctx, 0).
    } ELSE IF canBurn {
        SET ctx["MCC_PULSE_UNTIL"] TO TIME:SECONDS
            + LANDING_COAST_MCC_PULSE_TIME.
        SET ctx["MCC_SETTLE_UNTIL"] TO ctx["MCC_PULSE_UNTIL"]
            + LANDING_COAST_MCC_SETTLE_TIME.
        _landingSetThrottle(ctx, LANDING_COAST_MCC_THROTTLE).
    } ELSE {
        _landingSetThrottle(ctx, 0).
    }

    _landingHudText(ctx, "COAST MCC trErr=" + ROUND(trajErr["DIST"],0)
        + " along=" + ROUND(trajErr["ALONG"],0)
        + " cross=" + ROUND(trajErr["CROSS_SIGNED"],0)
        + " eta=" + ROUND(nextBrakeEta,0)
        + " aErr=" + ROUND(alignErr,1)
        + " upDot=" + ROUND(upDot,3)
        + " thr=" + ROUND(ctx["TARGET_THROTTLE"],2),
        1, 2, 13, CYAN, FALSE, nextBrakeEta).
}

LOCAL FUNCTION _landingBrakeAlignTick {
    PARAMETER ctx.

    _landingSetThrottle(ctx, 0).
    LOCAL steerInfo IS _landingBrakeSteeringInfo(ctx).
    LOCAL gate IS _landingBrakeGateInfo(ctx).
    LOCAL nextBurnEta IS MIN(gate["H_ETA"], gate["V_ETA"]).
    IF gate["H_OVERSHOT"] OR gate["H_NOW"] OR gate["V_NOW"] {
        SET nextBurnEta TO 0.
    }

    _landingHudText(ctx, "ALIGN d=" + ROUND(gate["DIST"],0)
        + " dr=" + ROUND(gate["DOWNRANGE"],0)
        + " hEta=" + ROUND(gate["H_ETA"],0)
        + " vEta=" + ROUND(gate["V_ETA"],0)
        + " hSupp=" + _landingBoolText(gate["H_SUPPRESSED"])
        + " hOver=" + _landingBoolText(gate["H_OVERSHOT"])
        + " trErr=" + ROUND(steerInfo["IMPACT_ERR"],0)
        + " x=" + ROUND(steerInfo["CROSS_ERR"],0)
        + " aErr=" + ROUND(steerInfo["ALIGN_ERR"],1)
        + " hard=" + _landingBoolText(steerInfo["HARD"]),
        1, 2, 13, YELLOW, FALSE, nextBurnEta).

    IF nextBurnEta < 999999 {
        _landingHudEtaNotice(ctx, "Braking burn", nextBurnEta, YELLOW).
    }

    IF gate["V_NOW"] {
        _landingSetState(ctx, "BRAKING_BURN", "vertical burn gate").
    } ELSE IF ctx["HAS_TARGET"] AND gate["H_NOW"] {
        _landingSetState(ctx, "BRAKING_BURN", "downrange <= brake distance").
    } ELSE IF ctx["HAS_TARGET"] AND gate["H_OVERSHOT"] {
        _landingSetState(ctx, "BRAKING_BURN", "target passed below safe altitude").
    } ELSE IF NOT gate["H_SUPPRESSED"]
            AND MIN(gate["H_ETA"], gate["V_ETA"]) > LANDING_BRAKE_ALIGN_LEAD {
        _landingSetState(ctx, "COAST", "brake gate deferred").
    }
}

LOCAL FUNCTION _landingBrakingTick {
    PARAMETER ctx.

    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL gravAcc IS ctx["GRAV"].
    LOCAL downSpeed IS ctx["DOWN_SPEED"].
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL burnDist IS lmVerticalBurnDistance(
        downSpeed, maxAcc, gravAcc).
    LOCAL burnHeight IS _landingBurnHeight(ctx).
    LOCAL targetDescent IS lmDescentSpeed(
        burnHeight, TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED).
    LOCAL targetVs IS -targetDescent.
    LOCAL verticalCaptured IS ABS(ctx["V_SPEED"] - targetVs) <= 5.
    LOCAL distToTarget IS 999999.
    IF ctx["HAS_TARGET"] {
        SET distToTarget TO lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    }

    LOCAL steerInfo IS _landingBrakeSteeringInfo(ctx).
    LOCAL verticalThrottle IS lmVerticalThrottle(
        targetVs, maxAcc, gravAcc, ctx["V_SPEED"]).
    LOCAL forceHorizontalBrake IS ctx["HAS_TARGET"]
        AND horizontalSpeed > APPROACH_HSPEED
        AND burnHeight > HOVER_ALT * 2.
    LOCAL horizontalThrottle IS 0.
    IF forceHorizontalBrake {
        SET horizontalThrottle TO MAX(LANDING_HKILL_THROTTLE_MIN,
            MIN(LANDING_HKILL_THROTTLE_MAX,
            (horizontalSpeed - APPROACH_HSPEED) / MAX(1, APPROACH_HSPEED))).
    }
    IF ctx["V_SPEED"] < targetVs - 5 {
        _landingSetThrottle(ctx, 1).
    } ELSE {
        _landingSetThrottle(ctx, MAX(verticalThrottle, horizontalThrottle)).
    }

    LOCAL brakeTransitionEta IS 0.
    IF NOT ctx["HAS_TARGET"] AND burnHeight > HOVER_ALT {
        SET brakeTransitionEta TO (burnHeight - HOVER_ALT) / MAX(1, downSpeed).
    }

    _landingHudText(ctx, "BRAKE d=" + ROUND(distToTarget,0)
        + " trErr=" + ROUND(steerInfo["IMPACT_ERR"],0)
        + " x=" + ROUND(steerInfo["CROSS_ERR"],0)
        + " xAbs=" + ROUND(steerInfo["CROSS_ABS"],0)
        + " aErr=" + ROUND(steerInfo["ALIGN_ERR"],1)
        + " hard=" + _landingBoolText(steerInfo["HARD"])
        + " hKill=" + _landingBoolText(forceHorizontalBrake)
        + " hThr=" + ROUND(horizontalThrottle,2)
        + " hs=" + ROUND(horizontalSpeed,1)
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + "/" + ROUND(targetVs,1)
        + " thr=" + ROUND(ctx["TARGET_THROTTLE"],2),
        1, 2, 13, YELLOW, FALSE, brakeTransitionEta).

    IF NOT ctx["HAS_TARGET"] AND burnHeight > HOVER_ALT {
        _landingHudEtaNotice(ctx, "Vertical descent",
            (burnHeight - HOVER_ALT) / MAX(1, downSpeed), GREEN).
    }

    IF ctx["HAS_TARGET"]
            AND verticalCaptured
            AND horizontalSpeed <= TERMINAL_HSPEED {
        IF distToTarget <= VERTICAL_RADIUS {
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "over-target vertical and horizontal capture").
        } ELSE IF burnHeight > APPROACH_SPEED_ALTITUDE_WINDOW {
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "high-altitude vertical and horizontal capture").
        } ELSE IF distToTarget > APPROACH_RADIUS {
            SET ctx["HOVER_REFINED"] TO TRUE.
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "post-brake miss outside approach radius").
        } ELSE {
            _landingSetState(ctx, "TARGET_REFINE",
                "post-brake lateral stabilization").
        }
    } ELSE IF burnHeight <= burnDist * BURN_MARGIN
            AND burnHeight <= HOVER_ALT
            AND (NOT ctx["HAS_TARGET"]
                OR horizontalSpeed <= LANDING_LOW_ALT_HSPEED) {
        _landingSetState(ctx, "VERTICAL_DESCENT", "low vertical gate").
    } ELSE IF ctx["HAS_TARGET"]
            AND verticalCaptured
            AND horizontalSpeed <= APPROACH_HSPEED
            AND distToTarget <= APPROACH_RADIUS {
        _landingSetState(ctx, "TARGET_REFINE",
            "approach corridor captured for target refinement").
    } ELSE IF NOT ctx["HAS_TARGET"]
            AND verticalCaptured
            AND horizontalSpeed < APPROACH_HSPEED {
        _landingSetState(ctx, "VERTICAL_DESCENT", "blind horizontal velocity killed").
    }
}

LOCAL FUNCTION _landingTargetRefineTick {
    PARAMETER ctx.

    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL refineAge IS TIME:SECONDS - ctx["STATE_ENTERED"].
    LOCAL controlHeight IS MIN(_landingTargetHeight(ctx), _landingBottomRadar()).
    LOCAL descentSpeed IS lmDescentSpeed(
        controlHeight, TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED).
    LOCAL targetVs IS -descentSpeed.
    LOCAL impactInfo IS _landingTrajImpactInfo(ctx).
    LOCAL impactErr IS 999999.
    LOCAL impactReady IS TRUE.
    IF impactInfo["FOUND"] {
        SET impactErr TO impactInfo["DIST"].
        SET impactReady TO impactErr <= LANDING_TARGET_REFINE_IMPACT_TOLERANCE.
    }
    LOCAL climbLimited IS ctx["V_SPEED"]
        > targetVs + LANDING_TARGET_REFINE_CLIMB_LIMIT.
    LOCAL timedOut IS refineAge >= LANDING_TARGET_REFINE_MAX_TIME.

    IF climbLimited OR timedOut {
        SET ctx["HOVER_REFINED"] TO TRUE.
        _landingSetThrottle(ctx, 0).
        IF climbLimited {
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "target refine climb guard triggered").
        } ELSE {
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "target refine timeout").
        }
        RETURN.
    }

    _landingSetSteering(ctx, _landingTargetRefineSteering(
        ctx, impactInfo)).
    LOCAL verticalThrottle IS lmVerticalThrottle(
        targetVs, ctx["MAX_ACC"], ctx["GRAV"], ctx["V_SPEED"]).
    LOCAL correctionThrottle IS 0.
    IF NOT impactReady OR horizontalSpeed > LANDING_TARGET_REFINE_ACCEPT_HSPEED {
        SET correctionThrottle TO LANDING_TARGET_REFINE_THR_MIN.
        IF impactInfo["FOUND"] {
            SET correctionThrottle TO MIN(LANDING_TARGET_REFINE_THR_MAX,
                MAX(correctionThrottle,
                    impactErr / MAX(1, LANDING_TARGET_REFINE_IMPACT_SCALE))).
        } ELSE {
            SET correctionThrottle TO MIN(LANDING_TARGET_REFINE_THR_MAX,
                MAX(correctionThrottle,
                    horizontalSpeed / MAX(1, APPROACH_HSPEED))).
        }
    }
    _landingSetThrottle(ctx, MAX(verticalThrottle, correctionThrottle)).

    LOCAL refineEta IS MAX(0,
        MIN(LANDING_TARGET_REFINE_ACCEPT_TIME,
            LANDING_TARGET_REFINE_MAX_TIME) - refineAge).
    _landingHudText(ctx, "TARGET REFINE hs=" + ROUND(horizontalSpeed,1)
        + "/" + ROUND(LANDING_TARGET_REFINE_HSPEED,1)
        + " trErr=" + ROUND(impactErr,0)
        + " trOk=" + _landingBoolText(impactReady)
        + " age=" + ROUND(refineAge,0)
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + "/" + ROUND(targetVs,1)
        + " cThr=" + ROUND(correctionThrottle,2)
        + " thr=" + ROUND(ctx["TARGET_THROTTLE"],2),
        1, 2, 13, CYAN, FALSE, refineEta).

    IF horizontalSpeed <= LANDING_TARGET_REFINE_HSPEED
            AND impactReady {
        _landingSetState(ctx, "APPROACH", "lateral drift neutralized").
    } ELSE IF refineAge >= LANDING_TARGET_REFINE_ACCEPT_TIME
            AND horizontalSpeed <= LANDING_TARGET_REFINE_ACCEPT_HSPEED
            AND impactReady {
        _landingSetState(ctx, "APPROACH", "target refine good enough").
    }
}

LOCAL FUNCTION _landingApproachTick {
    PARAMETER ctx.

    LOCAL distToTarget IS lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL approachHeight IS _landingTargetHeight(ctx).
    LOCAL bottomAlt IS _landingBottomRadar().
    LOCAL controlHeight IS MIN(approachHeight, bottomAlt).
    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL horizontalAcc IS MAX(0.1, maxAcc * BRAKE_ACCEL_FRACTION).
    LOCAL desiredSpeed IS MIN(MAX_APPROACH_SPEED,
        SQRT(MAX(0, 2 * horizontalAcc * MAX(0, distToTarget - VERTICAL_RADIUS)))).
    LOCAL descentSpeed IS lmDescentSpeed(
        controlHeight, TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED).
    LOCAL timeToHover IS MAX(1, (controlHeight - HOVER_ALT)
        / MAX(1, descentSpeed)).
    SET timeToHover TO MIN(timeToHover, 30).
    LOCAL altitudeLimitedSpeed IS MAX(VERTICAL_HSPEED,
        MAX(0, distToTarget - VERTICAL_RADIUS) / timeToHover).
    SET desiredSpeed TO MIN(desiredSpeed, altitudeLimitedSpeed).
    LOCAL altitudeCap IS MAX_APPROACH_SPEED
        * MAX(0, MIN(1, (controlHeight - HOVER_ALT)
            / APPROACH_SPEED_ALTITUDE_WINDOW)).
    SET desiredSpeed TO MIN(desiredSpeed, altitudeCap).
    _landingSetSteering(ctx, lmApproachSteering(
        ctx["TARGET_LAT"], ctx["TARGET_LNG"], desiredSpeed, ctx["H_VEL"],
        ctx["UP_VEC"], ctx["POSITION"])).

    LOCAL targetVs IS -descentSpeed.
    _landingSetThrottle(ctx, lmVerticalThrottle(
        targetVs, ctx["MAX_ACC"], ctx["GRAV"], ctx["V_SPEED"])).

    LOCAL verticalEta IS 0.
    IF bottomAlt > TERMINAL_ALT {
        SET verticalEta TO (bottomAlt - TERMINAL_ALT)
            / MAX(1, ctx["DOWN_SPEED"]).
    }
    LOCAL approachTransitionEta IS verticalEta.
    IF ctx["HAS_TARGET"] AND NOT ctx["HOVER_REFINED"] {
        SET approachTransitionEta TO verticalEta - LANDING_HOVER_REFINE_LEAD_TIME.
    }
    IF distToTarget <= VERTICAL_RADIUS
            AND horizontalSpeed <= VERTICAL_HSPEED {
        SET approachTransitionEta TO 0.
    }

    _landingHudText(ctx, "APPROACH d=" + ROUND(distToTarget,0)
        + " hT=" + ROUND(approachHeight,0)
        + " bottom=" + ROUND(bottomAlt,0)
        + " hs=" + ROUND(horizontalSpeed,1)
        + "/" + ROUND(desiredSpeed,1)
        + " cap=" + ROUND(altitudeCap,1)
        + " vs=" + ROUND(ctx["V_SPEED"],1),
        1, 2, 13, CYAN, FALSE, approachTransitionEta).

    IF ctx["HAS_TARGET"] AND NOT ctx["HOVER_REFINED"] {
        _landingHudEtaNotice(ctx, "Hover refinement",
            verticalEta - LANDING_HOVER_REFINE_LEAD_TIME, CYAN).
    } ELSE {
        _landingHudEtaNotice(ctx, "Vertical descent", verticalEta, GREEN).
    }

    IF distToTarget <= VERTICAL_RADIUS
            AND horizontalSpeed <= VERTICAL_HSPEED {
        _landingSetState(ctx, "HOVER_REFINE",
            "over target, entering hover pause").
    } ELSE IF ctx["HAS_TARGET"]
            AND NOT ctx["HOVER_REFINED"]
            AND verticalEta <= LANDING_HOVER_REFINE_LEAD_TIME {
        _landingSetState(ctx, "HOVER_REFINE",
            "hover refinement lead time").
    } ELSE IF bottomAlt <= TERMINAL_ALT {
        _landingSetState(ctx, "HOVER_REFINE", "terminal altitude hover pause").
    }
}

LOCAL FUNCTION _landingHoverRefineTick {
    PARAMETER ctx.

    IF NOT ctx["HOVER_TERRAIN_DONE"] {
        LOCAL originalTerrainRadius IS TERRAIN_CHECK_RADIUS.
        SET TERRAIN_CHECK_RADIUS TO 20.
        LOCAL terrainResult IS _landingTerrainCheck(
            ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        SET TERRAIN_CHECK_RADIUS TO originalTerrainRadius.
        SET ctx["HOVER_TERRAIN_DONE"] TO TRUE.
        SET ctx["TARGET_LAT"] TO terrainResult["LAT"].
        SET ctx["TARGET_LNG"] TO terrainResult["LNG"].
        SET ctx["TARGET_ELEVATION"] TO terrainResult["ELEVATION"].
        SET TARGET_LAT TO ctx["TARGET_LAT"].
        SET TARGET_LNG TO ctx["TARGET_LNG"].
        IF ADDONS:TR:AVAILABLE {
            ADDONS:TR:SETTARGET(LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"])).
        }
    }

    LOCAL distToTarget IS lmDistanceToTarget(
        ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL desiredSpeed IS MIN(LANDING_HOVER_REFINE_MAX_SPEED,
        distToTarget * LANDING_HOVER_REFINE_SPEED_GAIN).
    LOCAL stopSpeed IS SQRT(MAX(0, 2 * ctx["MAX_ACC"] * 0.35 * distToTarget)).
    SET desiredSpeed TO MIN(desiredSpeed, stopSpeed).

    _landingSetSteering(ctx, lmApproachSteering(
        ctx["TARGET_LAT"], ctx["TARGET_LNG"], desiredSpeed, ctx["H_VEL"],
        ctx["UP_VEC"], ctx["POSITION"],
        LANDING_HOVER_REFINE_TARGET_WEIGHT)).
    _landingSetThrottle(ctx, lmVerticalThrottle(
        0, ctx["MAX_ACC"], ctx["GRAV"], ctx["V_SPEED"])).

    LOCAL hoverEta IS MAX(0,
        (distToTarget - LANDING_HOVER_REFINE_ACCEPT_RADIUS)
            / MAX(0.1, horizontalSpeed)).
    _landingHudText(ctx, "HOVER d=" + ROUND(distToTarget,1)
        + " hs=" + ROUND(horizontalSpeed,1)
        + "/" + ROUND(desiredSpeed,1)
        + " stop=" + ROUND(stopSpeed,1)
        + " vs=" + ROUND(ctx["V_SPEED"],1),
        1, 2, 13, GREEN, FALSE, hoverEta).

    IF distToTarget <= LANDING_HOVER_REFINE_ACCEPT_RADIUS
            AND horizontalSpeed <= LANDING_HOVER_REFINE_ACCEPT_HSPEED {
        SET ctx["HOVER_REFINED"] TO TRUE.
        _landingSetState(ctx, "VERTICAL_DESCENT",
            "refinement complete, final drop").
    }
}

LOCAL FUNCTION _landingVerticalTick {
    PARAMETER ctx.
    LOCAL bottomAlt IS _landingBottomRadar().
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL finalHover IS bottomAlt <= LANDING_FINAL_HOVER_ALT
        AND horizontalSpeed > LANDING_FINAL_HOVER_HSPEED.

    IF ctx["HAS_TARGET"]
            AND NOT ctx["HOVER_REFINED"]
            AND bottomAlt <= LANDING_FINAL_HOVER_ALT {
        _landingSetState(ctx, "HOVER_REFINE", "final hover refinement").
        RETURN.
    }

    LOCAL verticalSteering IS ctx["UP_VEC"].
    LOCAL solarRoll IS FALSE.
    IF finalHover {
        SET verticalSteering TO lmHoverSteering(
            ctx["H_VEL"], ctx["UP_VEC"]).
    } ELSE IF bottomAlt <= UPRIGHT_ALT {
        SET verticalSteering TO SHIP:UP:VECTOR.
        SET solarRoll TO TRUE.
    } ELSE IF ctx["HAS_TARGET"] {
        SET verticalSteering TO lmApproachSteering(
            ctx["TARGET_LAT"], ctx["TARGET_LNG"], 0, ctx["H_VEL"],
            ctx["UP_VEC"], ctx["POSITION"]).
        SET solarRoll TO TRUE.
    } ELSE {
        SET verticalSteering TO lmHoverSteering(
            ctx["H_VEL"], ctx["UP_VEC"]).
        SET solarRoll TO TRUE.
    }

    IF solarRoll {
        _landingSetSteering(ctx, _landingSolarRollSteering(
            verticalSteering, ctx["UP_VEC"])).
    } ELSE {
        _landingSetSteering(ctx, verticalSteering).
    }

    LOCAL descentSpeed IS lmDescentSpeed(
        bottomAlt, TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED).
    IF finalHover {
        SET descentSpeed TO LANDING_FINAL_HOVER_VSPEED.
    }
    LOCAL targetVs IS -descentSpeed.
    _landingSetThrottle(ctx, lmVerticalThrottle(
        targetVs, ctx["MAX_ACC"], ctx["GRAV"], ctx["V_SPEED"])).

    LOCAL touchdownEta IS 0.
    IF bottomAlt > LANDING_TOUCHDOWN_ALT {
        SET touchdownEta TO (bottomAlt - LANDING_TOUCHDOWN_ALT)
            / MAX(0.1, ctx["DOWN_SPEED"]).
    }
    _landingHudText(ctx, "VERT bottom=" + ROUND(bottomAlt,0)
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + "/" + ROUND(targetVs,1)
        + " hs=" + ROUND(horizontalSpeed,1)
        + " hover=" + _landingBoolText(finalHover)
        + " solar=" + _landingBoolText(solarRoll),
        1, 2, 13, GREEN, FALSE, touchdownEta).

    IF bottomAlt > LANDING_TOUCHDOWN_ALT {
        _landingHudEtaNotice(ctx, "Touchdown",
            touchdownEta, GREEN).
    }
}

LOCAL FUNCTION _landingSurfaceSettleTick {
    PARAMETER ctx.

    _landingSetThrottle(ctx, 0).
    vesselDeployGear().
    IF _landingBottomRadar() <= UPRIGHT_ALT * 2 {
        _landingSetSteering(ctx, _landingSolarRollSteering(
            SHIP:UP:VECTOR, ctx["UP_VEC"])).
    }

    _landingHudText(ctx, "SETTLE bottom=" + ROUND(_landingBottomRadar(),0)
        + " ticks=" + ctx["TOUCHDOWN_TICKS"]
        + "/" + LANDING_TOUCHDOWN_SETTLE_TICKS
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + " hs=" + ROUND(ctx["H_SPEED"],1)
        + " solar=true",
        1, 2, 13, GREEN, FALSE).
}

LOCAL FUNCTION _landingGuidanceTick {
    PARAMETER ctx.

    IF ctx["STATE"] = "COAST" {
        _landingCoastTick(ctx).
    } ELSE IF ctx["STATE"] = "COAST_MCC" {
        _landingCoastMccTick(ctx).
    } ELSE IF ctx["STATE"] = "BRAKE_ALIGN" {
        _landingBrakeAlignTick(ctx).
    } ELSE IF ctx["STATE"] = "BRAKING_BURN" {
        _landingBrakingTick(ctx).
    } ELSE IF ctx["STATE"] = "TARGET_REFINE" {
        _landingTargetRefineTick(ctx).
    } ELSE IF ctx["STATE"] = "APPROACH" {
        _landingApproachTick(ctx).
    } ELSE IF ctx["STATE"] = "HOVER_REFINE" {
        _landingHoverRefineTick(ctx).
    } ELSE IF ctx["STATE"] = "VERTICAL_DESCENT" {
        _landingVerticalTick(ctx).
    }
}

LOCAL FUNCTION _landingFinish {
    PARAMETER ctx.

    _landingSetState(ctx, "TOUCHDOWN", "surface contact").
    vesselLandingCleanup().
    vesselSetReactionWheelAuthority(100).
    mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
        + "  lat=" + ROUND(SHIP:LATITUDE,4)
        + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
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
    LOCAL _hasTarget IS landingTarget["FOUND"].
    IF _hasTarget {
        SET TARGET_LAT TO landingTarget["LAT"].
        SET TARGET_LNG TO landingTarget["LNG"].
        mLog("Landing target: " + ROUND(landingTarget["LAT"],4)
            + "," + ROUND(landingTarget["LNG"],4)
            + " from " + landingTarget["SOURCE"] + ".").
    } ELSE {
        mLogWarn("No landing target resolved; executing safe vertical powered descent.").
    }

    LOCAL targetElevation IS 0.
    LOCAL terrainDone IS FALSE.
    IF _hasTarget {
        LOCAL terrainResult IS _landingTerrainCheck(TARGET_LAT, TARGET_LNG).
        SET terrainDone TO TRUE.
        SET TARGET_LAT TO terrainResult["LAT"].
        SET TARGET_LNG TO terrainResult["LNG"].
        SET targetElevation TO terrainResult["ELEVATION"].
    }
    LOCAL crossPid IS PIDLOOP(
        CROSS_PID_KP,
        CROSS_PID_KI,
        CROSS_PID_KD,
        CROSS_PID_MIN,
        CROSS_PID_MAX).
    SET crossPid:SETPOINT TO 0.

    LOCAL ctx IS LEXICON(
        "STATE", "COAST",
        "STATE_ENTERED", TIME:SECONDS,
        "HAS_TARGET", _hasTarget,
        "TARGET_LAT", TARGET_LAT,
        "TARGET_LNG", TARGET_LNG,
        "TARGET_ELEVATION", targetElevation,
        "CROSS_PID", crossPid,
        "TERRAIN_DONE", terrainDone,
        "HOVER_TERRAIN_DONE", FALSE,
        "HOVER_REFINED", FALSE,
        "HUD_LAST", TIME:SECONDS - LANDING_HUD_INTERVAL,
        "HUD_NOTICE_LAST", TIME:SECONDS - LANDING_HUD_NOTICE_INTERVAL,
        "HUD_NOTICE_TEXT", "",
        "TOUCHDOWN_TICKS", 0,
        "TOUCHDOWN_SETTLED", FALSE,
        "MCC_PULSE_UNTIL", 0,
        "MCC_SETTLE_UNTIL", 0,
        "TARGET_STEERING", SHIP:UP:VECTOR,
        "TARGET_THROTTLE", 0
    ).
    stateSet("landing_state", "COAST").

    IF _hasTarget AND ADDONS:TR:AVAILABLE {
        ADDONS:TR:SETTARGET(LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"])).
        mLog("Trajectories target set for powered descent guidance.").
    }

    SET SAS TO FALSE.
    vesselDeployGear().
    _landingSetSteering(ctx, ctx["TARGET_STEERING"]).
    LOCK THROTTLE TO ctx["TARGET_THROTTLE"].
    mLog("Landing setup target=" + _landingBoolText(_hasTarget)
        + " tr=" + _landingBoolText(ADDONS:TR:AVAILABLE) + ".").

    UNTIL landingAbortFlag OR ctx["TOUCHDOWN_SETTLED"] {
        LOCAL tickRate IS 0.33. // Slower tick for coasting.

        _landingCacheTick(ctx).

        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            _landingSurfaceSettleTick(ctx).
            IF _landingTouchdownSettled(ctx) {
                SET ctx["TOUCHDOWN_SETTLED"] TO TRUE.
            }
        } ELSE {
            SET ctx["TOUCHDOWN_TICKS"] TO 0.
            IF vesselNeedsStage() {
                LOCAL oldState IS ctx["STATE"].
                _landingSetThrottle(ctx, 0).
                vesselStageForLanding().
                IF oldState = "BRAKING_BURN" { _landingSetThrottle(ctx, 1). }
            }
            _landingGuidanceTick(ctx).
        }

        IF ctx["STATE"] <> "COAST" {
            SET tickRate TO 0.05.
        }

        WAIT tickRate.
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
