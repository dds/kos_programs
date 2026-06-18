// ============================================================
// landing_main.ks  -  Vacuum powered descent FSM coordinator
// (0:/lib/landing_main.ks)
//
// Entry points:
//   landExecute()
//   landingAssistStage()
//
// Target/config helpers live in landing_config.ks. Physics helpers live in
// landing_math.ks. Part operations live in vessel_hardware.ks. Per-state
// guidance tracks are loaded dynamically from landing_coast.ks,
// landing_brake.ks, and landing_terminal.ks.
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

GLOBAL landingAbortFlag IS FALSE.
GLOBAL landingSteeringTarget IS V(0, 0, 0).
GLOBAL landingActiveTrack IS "".
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

GLOBAL FUNCTION _landingTerrainCheck {
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

GLOBAL FUNCTION _landingStateLog {
    PARAMETER ctx.
    PARAMETER fromState.
    PARAMETER toState.
    PARAMETER reason.
    mLog("Landing state " + fromState + " -> " + toState + ": " + reason
        + " alt=" + ROUND(ALT:RADAR,0)
        + "m hs=" + ROUND(ctx["H_SPEED"],1)
        + " vs=" + ROUND(ctx["V_SPEED"],1) + ".").
}

GLOBAL FUNCTION _landingBoolText {
    PARAMETER flag.
    RETURN CHOOSE "true" IF flag ELSE "false".
}

GLOBAL FUNCTION _landingTrajImpactInfo {
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

GLOBAL FUNCTION _landingSetSteering {
    PARAMETER ctx.
    PARAMETER steeringVec.
    SET ctx["TARGET_STEERING"] TO steeringVec.
    SET landingSteeringTarget TO steeringVec.
    LOCK STEERING TO landingSteeringTarget.
}

GLOBAL FUNCTION _landingSetThrottle {
    PARAMETER ctx.
    PARAMETER throttleValue.
    SET ctx["TARGET_THROTTLE"] TO MAX(0, MIN(1, throttleValue)).
}

GLOBAL FUNCTION _landingAdaptiveLogInterval {
    PARAMETER etaSeconds IS 0.

    IF etaSeconds <= 0 { RETURN LANDING_HUD_INTERVAL. }
    RETURN MAX(LANDING_HUD_INTERVAL,
        MIN(LANDING_HUD_INTERVAL_MAX,
            etaSeconds / LANDING_HUD_INTERVAL_ETA_SCALE)).
}

GLOBAL FUNCTION _landingHudText {
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

GLOBAL FUNCTION _landingHudNotice {
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

GLOBAL FUNCTION _landingHudEtaNotice {
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

GLOBAL FUNCTION _landingBottomRadar {
    RETURN MAX(0, SHIP:BOUNDS:BOTTOMALTRADAR).
}

GLOBAL FUNCTION _landingTargetHeight {
    PARAMETER ctx.
    IF ctx["HAS_TARGET"] {
        RETURN MAX(0, SHIP:ALTITUDE - ctx["TARGET_ELEVATION"]).
    }
    RETURN ALT:RADAR.
}

GLOBAL FUNCTION _landingBurnHeight {
    PARAMETER ctx.
    IF ctx["STATE"] = "VERTICAL_DESCENT" {
        RETURN _landingBottomRadar().
    }
    RETURN _landingTargetHeight(ctx).
}

GLOBAL FUNCTION _landingDownrangeToTarget {
    PARAMETER ctx.
    LOCAL targetVec IS VXCL(ctx["UP_VEC"],
        LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]):POSITION
            - ctx["POSITION"]).
    IF ctx["H_SPEED"] < 0.1 { RETURN targetVec:MAG. }
    RETURN VDOT(targetVec, ctx["H_VEL"]:NORMALIZED).
}

GLOBAL FUNCTION _landingCacheTick {
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

GLOBAL FUNCTION _landingTrajError {
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

GLOBAL FUNCTION _landingTouchdownSettled {
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

GLOBAL FUNCTION _landingHorizontalBrakeAcc {
    PARAMETER ctx.

    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL gravAcc IS ctx["GRAV"].
    LOCAL fallbackAcc IS MAX(0,
        maxAcc * LANDING_HORIZONTAL_ACCEL_FALLBACK_FRACTION).
    IF maxAcc <= 0 { RETURN fallbackAcc. }

    LOCAL verticalAcc IS gravAcc
        * (1 + LANDING_HORIZONTAL_ACCEL_VERTICAL_BUFFER).
    IF maxAcc <= verticalAcc {
        RETURN fallbackAcc.
    }

    LOCAL horizontalSq IS maxAcc * maxAcc - verticalAcc * verticalAcc.
    IF horizontalSq <= 0 { RETURN fallbackAcc. }
    RETURN MAX(fallbackAcc, SQRT(horizontalSq)).
}

GLOBAL FUNCTION _landingBrakeGateInfo {
    PARAMETER ctx.

    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL gravAcc IS ctx["GRAV"].
    LOCAL downSpeed IS ctx["DOWN_SPEED"].
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL verticalAcc IS gravAcc
        * (1 + LANDING_HORIZONTAL_ACCEL_VERTICAL_BUFFER).
    LOCAL horizontalAcc IS _landingHorizontalBrakeAcc(ctx).
    LOCAL brakeDist IS lmHorizontalBrakeDistance(
        horizontalSpeed, horizontalAcc).
    LOCAL burnDist IS lmVerticalBurnDistance(
        downSpeed, maxAcc, gravAcc).
    LOCAL burnHeight IS _landingBurnHeight(ctx).
    LOCAL distToTarget IS 999999.
    LOCAL downrangeToTarget IS 999999.
    LOCAL brakeLeadDist IS 0.
    IF ctx["HAS_TARGET"] {
        SET distToTarget TO lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        SET downrangeToTarget TO _landingDownrangeToTarget(ctx).
        IF horizontalSpeed > 0.1 {
            SET brakeLeadDist TO MAX(0, LANDING_BRAKE_GATE_LEAD_DIST).
            SET downrangeToTarget TO downrangeToTarget + brakeLeadDist.
        }
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
        "BRAKE_LEAD", brakeLeadDist,
        "H_BRAKE", brakeDist,
        "H_GATE", hBrakeGate,
        "H_ETA", hBrakeEta,
        "H_NOW", hNow,
        "H_SUPPRESSED", hSuppressed,
        "H_OVERSHOT", hOvershot,
        "H_ACC", horizontalAcc,
        "V_GATE", vBurnGate,
        "V_ETA", vBurnEta,
        "V_NOW", vNow,
        "V_REQ_ACC", verticalAcc,
        "MAX_ACC", maxAcc,
        "GRAV", gravAcc,
        "DOWN_SPEED", downSpeed,
        "H_SPEED", horizontalSpeed
    ).
}

GLOBAL FUNCTION _landingTrackForState {
    PARAMETER stateName.
    IF stateName = "COAST" OR stateName = "COAST_MCC" {
        RETURN "landing_coast".
    }
    IF stateName = "BRAKE_ALIGN" OR stateName = "BRAKING_BURN" {
        RETURN "landing_brake".
    }
    IF stateName = "TARGET_REFINE" OR stateName = "APPROACH"
            OR stateName = "HOVER_REFINE"
            OR stateName = "VERTICAL_DESCENT"
            OR stateName = "TOUCHDOWN" {
        RETURN "landing_terminal".
    }
    RETURN "".
}

GLOBAL FUNCTION _landingDeleteTrack {
    PARAMETER trackName.
    IF trackName = "" { RETURN. }
    FOR suffix IN LIST(".ksm", ".ks") {
        LOCAL path IS bootCorePath(trackName) + suffix.
        IF EXISTS(path) { DELETEPATH(path). }
    }
}

GLOBAL FUNCTION _landingEnsureStateTrack {
    PARAMETER stateName.
    LOCAL nextTrack IS _landingTrackForState(stateName).
    IF nextTrack = "" OR nextTrack = landingActiveTrack { RETURN. }
    LOCAL previousTrack IS landingActiveTrack.
    IF previousTrack <> "" {
        _landingDeleteTrack(previousTrack).
    }
    bootLibSync(nextTrack).
    LOCAL corePath IS bootCorePath(nextTrack).
    IF NOT EXISTS(corePath + ".ksm") AND NOT EXISTS(corePath + ".ks") {
        mLogError("Landing guidance track unavailable: " + nextTrack + ".").
        RETURN.
    }
    RUNONCEPATH(corePath).
    SET landingActiveTrack TO nextTrack.
    mLog("Landing guidance track loaded: " + nextTrack + ".").
}

GLOBAL FUNCTION _landingSetState {
    PARAMETER ctx.
    PARAMETER nextState.
    PARAMETER reason.

    LOCAL prevState IS ctx["STATE"].
    IF prevState = nextState { RETURN. }
    _landingStateLog(ctx, prevState, nextState, reason).
    SET ctx["STATE"] TO nextState.
    SET ctx["STATE_ENTERED"] TO TIME:SECONDS.
    stateSet("landing_state", nextState).
    _landingEnsureStateTrack(nextState).

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
        SET ctx["HOVER_HOLD_BOTTOM"] TO _landingBottomRadar().
        _landingHudNotice(ctx, "Hovering to refine target coordinates.", CYAN, TRUE).
    } ELSE IF nextState = "VERTICAL_DESCENT" {
        vesselDeployGear().
        _landingHudNotice(ctx, "Performing vertical descent.", GREEN, TRUE).
    } ELSE IF nextState = "TOUCHDOWN" {
        _landingSetThrottle(ctx, 0).
        _landingHudNotice(ctx, "Touchdown.", GREEN, TRUE).
    }
}

GLOBAL FUNCTION _landingGuidanceTick {
    PARAMETER ctx.

    _landingEnsureStateTrack(ctx["STATE"]).
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
        "HOVER_HOLD_BOTTOM", 0,
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
    _landingEnsureStateTrack(ctx["STATE"]).

    UNTIL landingAbortFlag OR ctx["TOUCHDOWN_SETTLED"] {
        LOCAL tickRate IS 0.33. // Slower tick for coasting.

        _landingCacheTick(ctx).

        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            _landingEnsureStateTrack("TOUCHDOWN").
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
