// landing_brake.ks - BRAKE_ALIGN and BRAKING_BURN guidance track.

GLOBAL FUNCTION _landingBrakeSteeringInfo {
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
    LOCAL brakeGuard IS 1.
    IF ctx["HAS_TARGET"] AND trajErr["FOUND"]
            AND trajErr["ALONG"] <= 0 {
        SET brakeGuard TO 0.
    }
    LOCAL crossPid IS ctx["CROSS_PID"].
    LOCAL steeringTarget IS retroSteering.
    LOCAL biasMag IS 0.
    IF brakeGuard <= 0 {
        SET retroSteering TO ctx["UP_VEC"].
        SET steeringTarget TO retroSteering.
        crossPid:RESET().
    } ELSE IF brakeGuard < 0.999 {
        LOCAL lateralRetro IS VXCL(ctx["UP_VEC"], retroSteering).
        IF lateralRetro:MAG > 0.001 {
            SET retroSteering TO (ctx["UP_VEC"]
                + lateralRetro * brakeGuard):NORMALIZED.
            SET steeringTarget TO retroSteering.
        }
    }
    IF brakeGuard > 0
            AND trajErr["FOUND"]
            AND crossAbs > GUIDANCE_CORRECTION_THRESHOLD {
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
        "GUARD", brakeGuard,
        "HARD", hardBrake
    ).
}

GLOBAL FUNCTION _landingBrakeAlignTick {
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

GLOBAL FUNCTION _landingBrakingTick {
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
        SET horizontalThrottle TO horizontalThrottle * steerInfo["GUARD"].
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
