// landing_brake.ks - BRAKE_ALIGN and BRAKING_BURN guidance track.

// Exact net-acceleration limit in a chosen velocity-change direction:
// |g*up + aNet*direction| = aMax. The old aMax-g is its conservative
// triangle-inequality bound. Use this only with a separately checked gate.
GLOBAL FUNCTION lmBrakeFullNetAcc {
    PARAMETER horizontalSpeed.
    PARAMETER deltaDown.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    IF maxAcc <= gravAcc { RETURN 0. }
    LOCAL speed IS SQRT(horizontalSpeed ^ 2 + deltaDown ^ 2).
    IF speed < 0.001 { RETURN 0. }
    LOCAL upFraction IS deltaDown / speed.
    RETURN MAX(0, -gravAcc * upFraction
        + SQRT(MAX(0, maxAcc ^ 2 - gravAcc ^ 2 * (1 - upFraction ^ 2)))).
}

// Spend surplus altitude descending during horizontal arrest, then leave
// enough height to stop the remaining descent on the weaker planned stage.
// Reaction time, full gravity and existing clearance are reserved first.
GLOBAL FUNCTION lmBrakeDescentTarget {
    PARAMETER horizontalSpeed.
    PARAMETER downSpeed.
    PARAMETER height.
    PARAMETER currentAcc.
    PARAMETER planAcc.
    PARAMETER gravAcc.
    PARAMETER delay.
    PARAMETER currentGrav.
    IF planAcc <= gravAcc OR currentAcc <= gravAcc { RETURN 0. }
    LOCAL futureDown IS MAX(0, downSpeed + gravAcc * delay).
    LOCAL availableHeight IS height - downSpeed * delay - gravAcc * delay ^ 2 / 2.
    LOCAL low IS 0.
    // Pure horizontal full thrust is the greatest permitted downward
    // acceleration. This bound prevents an engine-down steering request.
    LOCAL high IS downSpeed + currentGrav * horizontalSpeed / currentAcc.
    LOCAL iteration IS 0.
    UNTIL iteration >= 10 {
        LOCAL terminalDown IS (low + high) / 2.
        LOCAL deltaDown IS futureDown - terminalDown.
        LOCAL speed IS SQRT(horizontalSpeed ^ 2 + deltaDown ^ 2).
        // For any gravity between zero and the surface bound, the exact
        // net limit is concave in g. Its minimum is at an endpoint. This
        // also covers orbital centrifugal support disappearing in the burn.
        LOCAL netAcc IS MIN(planAcc,
            lmBrakeFullNetAcc(horizontalSpeed, deltaDown, planAcc, gravAcc)).
        LOCAL stopTime IS speed / MAX(0.001, netAcc) * MAX(1, BURN_MARGIN).
        // The flare uses the unchanged 80%-net envelope, including residual
        // lateral speed, reaction/staging delay, burn margin and clearance.
        LOCAL flare IS lmBrakeEnvelope(APPROACH_HSPEED, terminalDown,
            planAcc, gravAcc, delay).
        LOCAL usedHeight IS (futureDown + terminalDown) * stopTime / 2
            + flare["V"].
        IF netAcc > 0 AND usedHeight <= availableHeight {
            SET low TO terminalDown.
        } ELSE { SET high TO terminalDown. }
        SET iteration TO iteration + 1.
    }
    RETURN -low.
}

// Full available thrust along the chosen net velocity-change direction.
// Retain the one-second tail taper and never point the engine downward.
GLOBAL FUNCTION lmEconomyBrakeThrust {
    PARAMETER horizontalVel.
    PARAMETER verticalSpeed.
    PARAMETER targetVs.
    PARAMETER upVec.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    LOCAL deltaVel IS -horizontalVel + (targetVs - verticalSpeed) * upVec.
    LOCAL thrustVec IS gravAcc * upVec.
    IF deltaVel:MAG > 0.001 {
        LOCAL netAcc IS MIN(lmBrakeFullNetAcc(horizontalVel:MAG,
            targetVs - verticalSpeed, maxAcc, gravAcc),
            deltaVel:MAG / MAX(0.1, LANDING_BRAKE_RESPONSE_TIME)).
        SET thrustVec TO thrustVec + deltaVel:NORMALIZED * netAcc.
    }
    LOCAL upwardAcc IS VDOT(thrustVec, upVec).
    IF upwardAcc < 0 { SET thrustVec TO thrustVec - upwardAcc * upVec. }
    RETURN thrustVec.
}

LOCAL FUNCTION _landingLogBrakeComplete {
    PARAMETER ctx.
    PARAMETER nextState.
    PARAMETER steerInfo.

    IF NOT ctx["HAS_TARGET"] { RETURN. }
    LOCAL trajErr IS _landingTrajError(ctx).
    IF NOT trajErr["FOUND"] {
        mLog("STATS brake-complete next=" + nextState
            + " impact=none bias=" + ROUND(LANDING_BRAKE_UNDERSHOOT_BIAS,0)
            + " hs=" + ROUND(ctx["H_SPEED"],1)
            + " vs=" + ROUND(ctx["V_SPEED"],1)).
        RETURN.
    }

    mLog("STATS brake-complete next=" + nextState
        + " impactLong=" + ROUND(trajErr["ALONG"],0)
        + " cross=" + ROUND(trajErr["CROSS_SIGNED"],0)
        + " dist=" + ROUND(trajErr["DIST"],0)
        + " bias=" + ROUND(LANDING_BRAKE_UNDERSHOOT_BIAS,0)
        + " guard=" + ROUND(steerInfo["GUARD"],2)
        + " hs=" + ROUND(ctx["H_SPEED"],1)
        + " vs=" + ROUND(ctx["V_SPEED"],1)).
}

GLOBAL FUNCTION _landingBrakeSteeringInfo {
    PARAMETER ctx.

    LOCAL height IS _landingBurnHeight(ctx).
    LOCAL targetVs IS -lmDescentSpeed(height,
        TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED).
    // Precision guidance keeps its original single-stop model. Economy
    // guidance below explicitly budgets a separate descending flare entry.
    IF ctx["H_SPEED"] > APPROACH_HSPEED { SET targetVs TO 0. }
    LOCAL fullVector IS LANDING_ECONOMY_BRAKE > 0
        AND ctx["H_SPEED"] > APPROACH_HSPEED.
    LOCAL thrustVec IS ctx["UP_VEC"] * 0.
    IF fullVector {
        SET targetVs TO lmBrakeDescentTarget(ctx["H_SPEED"], ctx["DOWN_SPEED"], height,
            ctx["MAX_ACC"], ctx["PLAN_ACC"], ctx["BRAKE_GRAV"],
            MAX(0, LANDING_BRAKE_REACTION_TIME), ctx["GRAV"]).
        SET thrustVec TO lmEconomyBrakeThrust(ctx["H_VEL"], ctx["V_SPEED"],
            targetVs, ctx["UP_VEC"], ctx["MAX_ACC"], ctx["GRAV"]).
    } ELSE {
        SET thrustVec TO lmBrakeThrust(ctx["H_VEL"], ctx["V_SPEED"],
            targetVs, ctx["UP_VEC"], ctx["MAX_ACC"], ctx["GRAV"]).
    }
    LOCAL steeringTarget IS ctx["UP_VEC"].
    IF thrustVec:MAG > 0.001 { SET steeringTarget TO thrustVec:NORMALIZED. }
    _landingSetSteering(ctx, steeringTarget).
    LOCAL throttleCommand IS 0.
    IF ctx["MAX_ACC"] > 0 {
        SET throttleCommand TO MIN(1, thrustVec:MAG / ctx["MAX_ACC"]).
    }
    LOCAL trajErr IS _landingTrajError(ctx).
    RETURN LEXICON(
        "IMPACT_ERR", trajErr["DIST"],
        "CROSS_ERR", trajErr["CROSS_SIGNED"],
        "CROSS_ABS", trajErr["CROSS"],
        "ALIGN_ERR", VANG(SHIP:FACING:FOREVECTOR, steeringTarget),
        "RETRO_ERR", VANG(SHIP:FACING:FOREVECTOR, steeringTarget),
        "BIAS", 0,
        "GUARD", 1,
        "HARD", ctx["H_SPEED"] > APPROACH_HSPEED,
        "TARGET_VS", targetVs,
        "THROTTLE", throttleCommand
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

    // A geographic gate is not permission to burn while still slewing.
    // Preserve urgent vertical arrest when the stopping envelope is already
    // reached; the normal twenty-second alignment lead avoids this case.
    IF steerInfo["ALIGN_ERR"] > 15 AND NOT gate["V_NOW"] { RETURN. }

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

    IF NOT landingReviewReachableSite(ctx) {
        SET landingAbortFlag TO TRUE.
        RETURN.
    }
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
    LOCAL terminalReady IS _landingBottomRadar() <= TERMINAL_ALT.
    LOCAL coastEnvelope IS lmBrakeEnvelope(horizontalSpeed, downSpeed,
        ctx["PLAN_ACC"], ctx["BRAKE_GRAV"], MAX(0, LANDING_BRAKE_REACTION_TIME)).
    IF NOT terminalReady AND horizontalSpeed <= APPROACH_HSPEED
            AND burnHeight > coastEnvelope["V"] {
        // An early horizontal arrest must not turn into minutes of hovering
        // or backtracking. Re-enter coast and re-evaluate the full stop gate.
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "velocity captured above terminal corridor").
        RETURN.
    }
    LOCAL distToTarget IS 999999.
    IF ctx["HAS_TARGET"] {
        SET distToTarget TO lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    }

    LOCAL steerInfo IS _landingBrakeSteeringInfo(ctx).
    SET targetVs TO steerInfo["TARGET_VS"].
    LOCAL verticalCaptured IS ABS(ctx["V_SPEED"] - targetVs) <= 5.
    // One vector owns both steering and throttle. Trajectories aiming must
    // not suppress velocity arrest when terrain clearance is running out.
    _landingSetThrottle(ctx, steerInfo["THROTTLE"]).

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
            AND terminalReady
            AND verticalCaptured
            AND horizontalSpeed <= TERMINAL_HSPEED {
        IF distToTarget <= VERTICAL_RADIUS {
            _landingLogBrakeComplete(ctx, "VERTICAL_DESCENT", steerInfo).
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "over-target vertical and horizontal capture").
        } ELSE IF distToTarget > APPROACH_RADIUS {
            _landingLogBrakeComplete(ctx, "APPROACH", steerInfo).
            _landingSetState(ctx, "APPROACH",
                "post-brake miss outside approach radius").
        } ELSE {
            _landingLogBrakeComplete(ctx, "TARGET_REFINE", steerInfo).
            _landingSetState(ctx, "TARGET_REFINE",
                "post-brake lateral stabilization").
        }
    } ELSE IF burnHeight <= burnDist * BURN_MARGIN
            AND burnHeight <= HOVER_ALT
            AND (NOT ctx["HAS_TARGET"]
                OR horizontalSpeed <= LANDING_LOW_ALT_HSPEED) {
        _landingSetState(ctx, "VERTICAL_DESCENT", "low vertical gate").
    } ELSE IF ctx["HAS_TARGET"]
            AND terminalReady
            AND verticalCaptured
            AND horizontalSpeed <= APPROACH_HSPEED
            AND distToTarget <= APPROACH_RADIUS {
        _landingLogBrakeComplete(ctx, "TARGET_REFINE", steerInfo).
        _landingSetState(ctx, "TARGET_REFINE",
            "approach corridor captured for target refinement").
    } ELSE IF NOT ctx["HAS_TARGET"]
            AND terminalReady
            AND verticalCaptured
            AND horizontalSpeed < APPROACH_HSPEED {
        _landingSetState(ctx, "VERTICAL_DESCENT", "blind horizontal velocity killed").
    }
}
