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
GLOBAL landingLoadedTracks IS LIST("landing_terminal").
GLOBAL LANDING_HUD_INTERVAL IS 5.
GLOBAL LANDING_HUD_INTERVAL_MAX IS 45.
GLOBAL LANDING_HUD_INTERVAL_ETA_SCALE IS 3.
GLOBAL LANDING_HUD_NOTICE_INTERVAL IS 5.
GLOBAL LANDING_HUD_NOTICE_HOLD_TIME IS 6.
GLOBAL LANDING_HUD_NOTICE_LOOKAHEAD IS 90.
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
    PARAMETER applyShift IS TRUE.

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
    // A final 20 m search must not sample only its SW corner when the
    // mission's coarse grid step is 100 m. Seed the center explicitly too.
    SET stepM TO MIN(stepM, radiusM).

    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(targetLat)).

    LOCAL bestLat IS targetLat.
    LOCAL bestLng IS targetLng.
    LOCAL centerTerrain IS LATLNG(targetLat, targetLng):TERRAINHEIGHT.
    LOCAL centerGrade IS landingTerrainGrade(targetLat, targetLng, stepM).
    LOCAL bestScore IS centerGrade * 500.
    IF centerGrade <= TAN(LANDING_TERRAIN_MAX_SLOPE) {
        mLog("STATS landing-terrain shift=0 reason=center-within-slope-limit lat="
            + targetLat + " lng=" + targetLng + " grade=" + ROUND(centerGrade,4)).
        RETURN LEXICON("LAT", targetLat, "LNG", targetLng,
            "ELEVATION", centerTerrain, "SHIFTED", FALSE).
    }

    LOCAL northM IS -radiusM.
    UNTIL northM > radiusM {
        LOCAL eastM IS -radiusM.
        UNTIL eastM > radiusM {
            LOCAL sampleLat IS targetLat + northM * degPerM.
            LOCAL sampleLng IS targetLng + eastM * degPerM / lonScale.

            LOCAL slopePenalty IS landingTerrainGrade(sampleLat, sampleLng, stepM) * 500.
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
    mLog("STATS landing-terrain centerElev=" + ROUND(centerTerrain,1)
        + "m  best score=" + ROUND(bestScore,1)
        + "  shift=" + ROUND(shiftDist,0) + "m.").

    IF shiftDist > 5 {
        IF applyShift {
            mLog("Shifting target by " + ROUND(shiftDist,0) + "m to flatter terrain"
                + " lat=" + ROUND(bestLat,4) + " lng=" + ROUND(bestLng,4) + ".").
            SET TARGET_LAT TO bestLat.
            SET TARGET_LNG TO bestLng.
            IF ADDONS:TR:AVAILABLE {
                ADDONS:TR:SETTARGET(LATLNG(bestLat, bestLng)).
            }
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
    mLog("STATS landing-state " + fromState + " -> " + toState + ": " + reason
        + " alt=" + ROUND(ALT:RADAR,0)
        + "m hs=" + ROUND(ctx["H_SPEED"],1)
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + " acc=" + ROUND(ctx["MAX_ACC"],2)
        + " planAcc=" + ROUND(ctx["PLAN_ACC"],2)
        + " height=" + ROUND(_landingBurnHeight(ctx),0)
        + " stageDv=" + ROUND(ctx["BRAKE_STAGE_DV"],1)
        + " age=" + ROUND(TIME:SECONDS - ctx["STATE_ENTERED"],1) + ".").
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
    IF ABORT OR TIME:SECONDS < ctx["STAGE_UNTIL"] OR ctx["DISCARD_PENDING"] {
        SET ctx["TARGET_THROTTLE"] TO 0.
    }
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
    PARAMETER targetVs IS "uncontrolled".
    PARAMETER targetHs IS "uncontrolled".

    landingDiagnosticHud(ctx, text, targetVs, targetHs).
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
    IF LANDING_FLEXIBLE_SITE > 0 AND LANDING_ECONOMY_BRAKE > 0 AND ctx["DIVERT_PENDING"]
            AND ctx["H_SPEED"] <= LANDING_TOUCHDOWN_HSPEED AND ctx["V_SPEED"] <= 0
            AND LANDING_COAST_MCC_THROTTLE_MAX <= 0 {
        // Ignore a distant old datum only after horizontal capture, outside
        // even the low-speed drift corridor to impact. Moving craft and
        // nearby old sites retain their original obstacle-height guard.
        LOCAL driftBound IS LANDING_TOUCHDOWN_HSPEED * (MAX(0, lmTimeToImpact())
            + MAX(0, LANDING_BRAKE_REACTION_TIME) + MAX(0, LANDING_BRAKE_ALIGN_LEAD)).
        IF lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"])
                > MAX(1000, MAX(LANDING_DIVERT_SEARCH_RADIUS, driftBound)) {
            RETURN MIN(SHIP:ALTITUDE - ctx["DIVERT_ELEVATION"], _landingBottomRadar()).
        }
    }
    RETURN MIN(_landingTargetHeight(ctx), _landingBottomRadar()).
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
    SET ctx["MAX_ACC"] TO vesselLandingThrust() / MAX(0.01, SHIP:MASS).
    SET ctx["BRAKE_GRAV"] TO SHIP:BODY:MU / SHIP:BODY:RADIUS ^ 2.
    IF ctx["RESERVE_STAGE"] <> STAGE:NUMBER {
        SET ctx["RESERVE_ACC"] TO vesselLandingReserveAcc().
        SET ctx["RESERVE_STAGE"] TO STAGE:NUMBER.
        IF LANDING_POWERED_LEAD > 0 { SET ctx["BRAKE_MODEL"] TO landingBrakeStack(). }
    }
    SET ctx["BRAKE_STAGE_DV"] TO 0.
    IF LANDING_STAGE_BRAKE_CREDIT > 0 AND NOT ctx["DISCARD_PENDING"] {
        SET ctx["BRAKE_STAGE_DV"] TO vesselLandingBrakeStageDv().
    }
    SET ctx["PLAN_ACC"] TO ctx["MAX_ACC"].
    IF ctx["RESERVE_ACC"] > 0 {
        SET ctx["PLAN_ACC"] TO MIN(ctx["PLAN_ACC"], ctx["RESERVE_ACC"]).
    }
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

GLOBAL FUNCTION _landingBrakeGateInfo {
    PARAMETER ctx.

    LOCAL maxAcc IS ctx["PLAN_ACC"].
    LOCAL gravAcc IS ctx["BRAKE_GRAV"].
    LOCAL downSpeed IS ctx["DOWN_SPEED"].
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL verticalAcc IS gravAcc.
    LOCAL horizontalAcc IS lmBrakeNetAcc(maxAcc, gravAcc).
    LOCAL envelope IS _landingStopEnvelope(ctx,horizontalSpeed,downSpeed).
    LOCAL brakeDist IS envelope["H"].
    IF LANDING_POWERED_LEAD > 0 AND LANDING_ECONOMY_BRAKE > 0 {
        // Alignment precedes ignition. Safety latency belongs to the V
        // envelope, not nominal powered travel; use the real settle budget.
        LOCAL stack IS landingBrakeStackAt(ctx["BRAKE_MODEL"],SHIP:MASS).
        LOCAL nominalRange IS lmNominalBrakeRange(horizontalSpeed,ctx["MAX_ACC"],
            ctx["PLAN_ACC"],ctx["BRAKE_STAGE_DV"],gravAcc,0,
            SHIP:BODY:RADIUS,SHIP:ALTITUDE,2*MAX(0.05,LANDING_STAGE_SETTLE),stack).
        IF nominalRange >= 0 { SET brakeDist TO MIN(brakeDist,nominalRange). }
    }
    LOCAL burnHeight IS _landingBurnHeight(ctx).
    LOCAL distToTarget IS 999999.
    LOCAL downrangeToTarget IS 999999.
    LOCAL brakeDownrange IS 999999.
    LOCAL brakeLeadDist IS 0.
    LOCAL brakeUndershootBias IS 0.
    IF ctx["HAS_TARGET"] {
        SET distToTarget TO lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        SET downrangeToTarget TO _landingDownrangeToTarget(ctx).
        SET brakeDownrange TO downrangeToTarget.
        IF horizontalSpeed > 0.1 {
            SET brakeLeadDist TO MAX(0, LANDING_BRAKE_GATE_LEAD_DIST).
            SET brakeUndershootBias TO MAX(0, LANDING_BRAKE_UNDERSHOOT_BIAS).
            SET brakeDownrange TO brakeDownrange
                - brakeLeadDist
                - brakeUndershootBias.
        }
    }

    LOCAL hBrakeGate IS brakeDist + BRAKE_MARGIN.
    LOCAL hBrakeEta IS 999999.
    IF ctx["HAS_TARGET"] AND horizontalSpeed > APPROACH_HSPEED
            AND brakeDownrange > 0 {
        IF brakeDownrange <= hBrakeGate {
            SET hBrakeEta TO 0.
        } ELSE IF horizontalSpeed > 0.1 {
            SET hBrakeEta TO (brakeDownrange - hBrakeGate)
                / horizontalSpeed.
        }
    }

    LOCAL vBurnGate IS envelope["V"].
    LOCAL vNow IS burnHeight <= vBurnGate.
    // Search a short coast horizon including the GROWING stopping distance.
    // Treat upward speed as zero here: alignment may be early, never late.
    LOCAL etaLo IS 0.
    LOCAL etaHi IS MAX(120, LANDING_BRAKE_ALIGN_LEAD * 2).
    LOCAL iteration IS 0.
    UNTIL iteration >= 12 {
        LOCAL coastTime IS (etaLo + etaHi) / 2.
        LOCAL futureGate IS _landingStopEnvelope(ctx,horizontalSpeed,
            downSpeed + gravAcc * coastTime).
        LOCAL futureHeight IS burnHeight - downSpeed * coastTime
            - gravAcc * coastTime ^ 2 / 2.
        IF futureHeight <= futureGate["V"] {
            SET etaHi TO coastTime.
        } ELSE {
            SET etaLo TO coastTime.
        }
        SET iteration TO iteration + 1.
    }
    LOCAL vBurnEta IS etaLo.
    IF vNow { SET vBurnEta TO 0. }

    // A passed target is not a horizontal stopping point ahead of us.
    // Never let a negative downrange bypass the separate overshoot gate.
    LOCAL hNow IS ctx["HAS_TARGET"] AND horizontalSpeed > APPROACH_HSPEED
        AND brakeDownrange > 0 AND brakeDownrange <= hBrakeGate.
    LOCAL hSuppressed IS FALSE.
    IF ctx["HAS_TARGET"] AND hBrakeEta < 999999 AND burnHeight > TERRAIN_SAFE_ALT
            AND vBurnEta > LANDING_BRAKE_ALIGN_LEAD {
        SET hNow TO FALSE.
        SET hBrakeEta TO 999999.
        SET hSuppressed TO TRUE.
    }
    LOCAL hOvershot IS ctx["HAS_TARGET"] AND downrangeToTarget <= 0
        AND horizontalSpeed > APPROACH_HSPEED
        AND ctx["V_SPEED"] < 0
        AND burnHeight <= TERRAIN_SAFE_ALT.
    IF LANDING_ECONOMY_BRAKE > 0 AND LANDING_FLEXIBLE_SITE > 0 {
        // Flexible sites do not justify arresting velocity early just to
        // preserve a geographic stopping point. The separate V gate still
        // includes horizontal speed, terrain, latency and next-stage thrust.
        SET hNow TO FALSE.
        SET hOvershot TO FALSE.
        SET hBrakeEta TO 999999.
        SET hSuppressed TO TRUE.
    }

    RETURN LEXICON(
        "DIST", distToTarget,
        "DOWNRANGE", downrangeToTarget,
        "BRAKE_DOWNRANGE", brakeDownrange,
        "BRAKE_LEAD", brakeLeadDist,
        "BRAKE_BIAS", brakeUndershootBias,
        "H_BRAKE", brakeDist,
        "H_GATE", hBrakeGate,
        "RANGE_ERROR", brakeDist-downrangeToTarget,
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
    IF landingLoadedTracks:CONTAINS(nextTrack) {
        SET landingActiveTrack TO nextTrack.
        RETURN.
    }
    bootLibSync(nextTrack).
    LOCAL corePath IS bootCorePath(nextTrack).
    IF NOT EXISTS(corePath + ".ksm") AND NOT EXISTS(corePath + ".ks") {
        SET landingAbortFlag TO TRUE.
        vesselLandingCleanup().
        mLogError("Landing guidance track unavailable: " + nextTrack + ".").
        RETURN.
    }
    RUNONCEPATH(corePath).
    landingLoadedTracks:ADD(nextTrack).
    SET landingActiveTrack TO nextTrack.
    mLog("Landing guidance track loaded: " + nextTrack + ".").
}

GLOBAL FUNCTION _landingSetState {
    PARAMETER ctx.
    PARAMETER nextState.
    PARAMETER reason.

    LOCAL prevState IS ctx["STATE"].
    IF prevState = nextState { RETURN. }
    IF prevState = "BRAKING_BURN" OR prevState = "COAST_MCC"
            OR prevState = "TARGET_REFINE" OR prevState = "APPROACH"
            OR prevState = "HOVER_REFINE" OR prevState = "VERTICAL_DESCENT" {
        _landingSetThrottle(ctx, 0).
        IF NOT thrustCutoffOk(FALSE) {
            SET landingAbortFlag TO TRUE.
            RETURN.
        }
        // The checker temporarily owns a constant zero lock. Hand it back
        // to the FSM's command variable only after physical cutoff.
        LOCK THROTTLE TO ctx["TARGET_THROTTLE"].
    }
    _landingStateLog(ctx, prevState, nextState, reason).
    SET ctx["STATE"] TO nextState.
    SET ctx["STATE_ENTERED"] TO TIME:SECONDS.
    stateSet("landing_state", nextState).
    _landingEnsureStateTrack(nextState).
    IF landingAbortFlag { RETURN. }

    IF nextState = "BRAKE_ALIGN" {
        _landingSetThrottle(ctx, 0).
        LOCAL alignSteerInfo IS _landingBrakeSteeringInfo(ctx).
        mLog("BRAKE ALIGN steering: err="
            + ROUND(alignSteerInfo["ALIGN_ERR"],1)
            + "deg bias=" + ROUND(alignSteerInfo["BIAS"],3)
            + " hard=" + _landingBoolText(alignSteerInfo["HARD"]) + ".").
        _landingHudNotice(ctx, "Performing braking alignment.", YELLOW, TRUE).
    } ELSE IF nextState = "BRAKING_BURN" {
        LOCAL burnSteerInfo IS _landingBrakeSteeringInfo(ctx).
        _landingSetThrottle(ctx, burnSteerInfo["THROTTLE"]).
        LOCAL gate IS _landingBrakeGateInfo(ctx).
        LOCAL brakeReport IS "STATS landing-brake begin ut=" + ROUND(TIME:SECONDS,1)
            + " reason=" + reason
            + " height=" + ROUND(_landingBurnHeight(ctx),0)
            + " bottom=" + ROUND(_landingBottomRadar(),0)
            + " asl=" + ROUND(SHIP:ALTITUDE,0)
            + " targetElev=" + ROUND(ctx["TARGET_ELEVATION"],0)
            + " lat=" + ROUND(ctx["TARGET_LAT"],4)
            + " lng=" + ROUND(ctx["TARGET_LNG"],4)
            + " vGate=" + ROUND(gate["V_GATE"],0)
            + " vNow=" + gate["V_NOW"]
            + " vEta=" + ROUND(gate["V_ETA"],1)
            + " hGate=" + ROUND(gate["H_GATE"],0)
            + " stopRangeError=" + ROUND(gate["RANGE_ERROR"],0)
            + " hNow=" + gate["H_NOW"]
            + " hOver=" + gate["H_OVERSHOT"]
            + " hSupp=" + gate["H_SUPPRESSED"]
            + " downrange=" + ROUND(gate["DOWNRANGE"],0)
            + " hs=" + ROUND(ctx["H_SPEED"],1)
            + " vs=" + ROUND(ctx["V_SPEED"],1)
            + " acc=" + ROUND(ctx["MAX_ACC"],2)
            + " planAcc=" + ROUND(ctx["PLAN_ACC"],2)
            + " reserveAcc=" + ROUND(ctx["RESERVE_ACC"],2)
            + " brakeStageDv=" + ROUND(ctx["BRAKE_STAGE_DV"],1)
            + " stageCredit=" + LANDING_STAGE_BRAKE_CREDIT
            + " poweredLead=" + _landingBoolText(LANDING_POWERED_LEAD > 0)
            + " vectorGate=" + _landingBoolText(LANDING_ECONOMY_BRAKE > 0 AND ctx["H_SPEED"] > APPROACH_HSPEED)
            + " grav=" + ROUND(ctx["BRAKE_GRAV"],2)
            + " stage=" + STAGE:NUMBER
            + " ipu=" + CONFIG:IPU
            + " economyBrake=" + LANDING_ECONOMY_BRAKE
            + " targetVs=" + ROUND(burnSteerInfo["TARGET_VS"],1)
            + " align=" + ROUND(burnSteerInfo["ALIGN_ERR"],1)
            + " throttle=" + ROUND(ctx["TARGET_THROTTLE"],2).
        // One compact record survives a reboot and log rotation; no per-tick
        // state writes or archive reads are needed to explain this ignition.
        stateSet("last_landing_brake", brakeReport).
        mLog(brakeReport).
        mLog("BRAKING BURN steering: err="
            + ROUND(burnSteerInfo["ALIGN_ERR"],1)
            + "deg bias=" + ROUND(burnSteerInfo["BIAS"],3)
            + " hard=" + _landingBoolText(burnSteerInfo["HARD"]) + ".").
        _landingHudNotice(ctx, "Performing braking burn.", YELLOW, TRUE).
    } ELSE IF nextState = "COAST_MCC" {
        _landingSetThrottle(ctx, 0).
        SET ctx["MCC_PULSE_UNTIL"] TO 0.
        SET ctx["MCC_SETTLE_UNTIL"] TO 0.
        _landingHudNotice(ctx, "Correcting landing impact point.", CYAN, TRUE).
    } ELSE IF nextState = "APPROACH" {
        _landingHudNotice(ctx, "Performing approach.", CYAN, TRUE).
    } ELSE IF nextState = "TARGET_REFINE" {
        SET ctx["TARGET_REFINE_LOGGED"] TO FALSE.
        SET ctx["TARGET_REFINE_CLIMB_SINCE"] TO 0.
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

    IF ABORT {
        _landingSetThrottle(ctx, 0).
        SET landingAbortFlag TO TRUE.
        RETURN.
    }
    _landingEnsureStateTrack(ctx["STATE"]).
    IF landingAbortFlag { RETURN. }
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
    IF NOT vesselLandingCleanup() { RETURN FALSE. }
    vesselSetReactionWheelAuthority(100).
    mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
        + "  lat=" + ROUND(SHIP:LATITUDE,4)
        + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
    IF ctx["HAS_TARGET"] {
        mLog("STATS landing-result requestedMiss="
            + ROUND(lmDistanceToTarget(ctx["REQUESTED_LAT"], ctx["REQUESTED_LNG"]),1)
            + " guidanceMiss="
            + ROUND(lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]),1)
            + " targetShift=" + ROUND(geoDistance(ctx["REQUESTED_LAT"], ctx["REQUESTED_LNG"],
                ctx["TARGET_LAT"], ctx["TARGET_LNG"]),1)
            + " remainingDv=" + ROUND(SHIP:DELTAV:VACUUM,1)).
    }
    stateSet("landing_lat",  SHIP:LATITUDE).
    stateSet("landing_lng",  SHIP:LONGITUDE).
    stateSet("landing_time", TIME:SECONDS).
    stateSet("landing_state", "TOUCHDOWN").
    vesselDeployAntennas().
    vesselDeploySolarPanels().
    RETURN TRUE.
}

// ------------------------------------------------------------
// Main entry points
// ------------------------------------------------------------

GLOBAL FUNCTION landExecute {
    mLogPhase("LANDING").
    landingApplyMissionConfig().
    SET landingAbortFlag TO FALSE.
    LOCK THROTTLE TO 0.
    SET SHIP:CONTROL:MAINTHROTTLE TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF NOT vesselLandingPrepareRoles() {
        mLogError("Landing role tags invalid: further automatic staging blocked; active descent guidance retained.").
    }
    LOCAL priorArchiveDeferral IS LOG_ARCHIVE_DEFERRED.
    SET LOG_ARCHIVE_DEFERRED TO 1.
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) {
        stateSet("landing_prior_ipu", priorIpu).
        SET CONFIG:IPU TO MIN(2000, LANDING_MIN_IPU).
    }

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
    IF _hasTarget AND LANDING_FLEXIBLE_SITE <= 0 {
        LOCAL terrainResult IS _landingTerrainCheck(TARGET_LAT, TARGET_LNG).
        SET terrainDone TO TRUE.
        SET TARGET_LAT TO terrainResult["LAT"].
        SET TARGET_LNG TO terrainResult["LNG"].
        SET targetElevation TO terrainResult["ELEVATION"].
    } ELSE IF _hasTarget {
        SET targetElevation TO LATLNG(TARGET_LAT, TARGET_LNG):TERRAINHEIGHT.
        // A mid-descent reboot must not block on grids around an old site.
        // Flexible-site validation runs incrementally after velocity arrest.
        SET terrainDone TO TRUE.
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
        "REQUESTED_LAT", landingTarget["LAT"],
        "REQUESTED_LNG", landingTarget["LNG"],
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
        "TARGET_REFINE_LOGGED", FALSE,
        "TARGET_REFINE_CLIMB_SINCE", 0,
        "MCC_PULSE_UNTIL", 0,
        "MCC_SETTLE_UNTIL", 0,
        "TARGET_STEERING", SHIP:UP:VECTOR,
        "BRAKE_ALIGN_BLOCKED", FALSE,
        "DIVERT_PENDING", FALSE,
        "ECONOMY_FOOTPRINT_TRIED", FALSE,
        "DIVERT_SEARCH", LEXICON(),
        "DIVERT_PREVIEW", LEXICON("OK", FALSE, "AT", -9999, "LOG_AT", -9999),
        "DIVERT_ELEVATION", SHIP:ALTITUDE - _landingBottomRadar(),
        "RESERVE_STAGE", -999,
        "RESERVE_ACC", 0,
        "BRAKE_STAGE_DV", 0,
        "BRAKE_MODEL", LEXICON("VALID",FALSE),
        "STAGE_UNTIL", 0,
        "STAGE_ENGINE", -1,
        "STAGE_EVENTS", 0,
        "STAGE_ACTIVATED", FALSE,
        "STAGE_WARNED", FALSE,
        "DISCARD_TRIED", FALSE,
        "DISCARD_PENDING", FALSE,
        "DISCARD_SINCE", 0,
        "TARGET_THROTTLE", 0
    ).
    _landingCacheTick(ctx).
    landingDiagnosticStart(ctx).
    IF NOT landingReviewReachableSite(ctx) { SET landingAbortFlag TO TRUE. }
    // Precision surveys finish before thrust. Flexible missions use bounded
    // per-tick site validation instead of blocking on a remote target grid.
    IF _hasTarget AND NOT landingAbortFlag { _landingFinalTerrainCheck(ctx). }
    stateSet("landing_state", "COAST").

    IF _hasTarget AND ADDONS:TR:AVAILABLE {
        ADDONS:TR:SETTARGET(LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"])).
        mLog("Trajectories target set for powered descent guidance.").
    }

    SET SAS TO FALSE.
    vesselDeployGear().
    _landingSetSteering(ctx, ctx["TARGET_STEERING"]).
    LOCK THROTTLE TO ctx["TARGET_THROTTLE"].
    mLog("STATS landing setup target=" + _landingBoolText(_hasTarget)
        + " tr=" + _landingBoolText(ADDONS:TR:AVAILABLE)
        + " economyBrake=" + LANDING_ECONOMY_BRAKE + " flexible=" + LANDING_FLEXIBLE_SITE
        + " stageCredit=" + LANDING_STAGE_BRAKE_CREDIT
        + " vectorGate=" + _landingBoolText(LANDING_ECONOMY_BRAKE > 0 AND ctx["H_SPEED"] > APPROACH_HSPEED)
        + " brakeStageDv=" + ROUND(ctx["BRAKE_STAGE_DV"],1) + ".").
    // Load the next track while still at setup, then reclaim its disk file.
    // RUNONCE functions remain resident: no archive/compile delay at ignition.
    _landingEnsureStateTrack("BRAKE_ALIGN").
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
            landingStageDisposalTick(ctx).
            vesselStageForLanding(ctx, ctx["DISCARD_PENDING"]).
            // Staging/activation changes mass and thrust; never fly this tick
            // using the exhausted transfer stage's cached acceleration.
            _landingCacheTick(ctx).
            _landingGuidanceTick(ctx).
            IF TIME:SECONDS < ctx["STAGE_UNTIL"] OR vesselNeedsStage() {
                _landingSetThrottle(ctx, 0).
            }
        }

        IF ctx["STATE"] <> "COAST" {
            SET tickRate TO 0.05.
        }

        landingDiagnosticTick(ctx).
        WAIT tickRate.
    }

    IF landingAbortFlag {
        vesselLandingCleanup().
        landingDiagnosticTick(ctx, TRUE).
        SET CONFIG:IPU TO priorIpu.
        stateRemove("landing_prior_ipu").
        SET LOG_ARCHIVE_DEFERRED TO priorArchiveDeferral.
        IF LOG_ARCHIVE_DEFERRED <= 0 { archiveLog(). }
        RETURN FALSE.
    }
    LOCAL landed IS _landingFinish(ctx).
    landingDiagnosticTick(ctx, TRUE).
    SET CONFIG:IPU TO priorIpu.
    stateRemove("landing_prior_ipu").
    SET LOG_ARCHIVE_DEFERRED TO priorArchiveDeferral.
    IF LOG_ARCHIVE_DEFERRED <= 0 { archiveLog(). }
    RETURN landed.
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
