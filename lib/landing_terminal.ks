// landing_terminal.ks - target refinement, approach, final descent, touchdown.

GLOBAL FUNCTION _landingTargetRefineSteering {
    PARAMETER ctx.

    LOCAL targetPos IS LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]):POSITION.
    LOCAL posErr IS VXCL(ctx["UP_VEC"], targetPos - ctx["POSITION"]).
    LOCAL desiredVel IS posErr * LANDING_HOVER_REFINE_SPEED_GAIN.
    IF desiredVel:MAG > LANDING_TARGET_REFINE_HSPEED {
        SET desiredVel TO desiredVel:NORMALIZED * LANDING_TARGET_REFINE_HSPEED.
    }
    LOCAL velErr IS desiredVel - ctx["H_VEL"].
    LOCAL leanVec IS velErr * 0.1.
    LOCAL maxLean IS SIN(MAX_TILT).
    IF leanVec:MAG > maxLean {
        SET leanVec TO leanVec:NORMALIZED * maxLean.
    }
    RETURN (ctx["UP_VEC"] + leanVec):NORMALIZED.
}

GLOBAL FUNCTION _landingSolarRollSteering {
    PARAMETER forwardVec.
    PARAMETER upVec.

    IF forwardVec:MAG < 0.01 { RETURN upVec. }
    LOCAL fwd IS forwardVec:NORMALIZED.
    LOCAL sunVec IS VXCL(fwd, SUN:POSITION - SHIP:POSITION).
    IF sunVec:MAG < 0.01 { RETURN fwd. }
    RETURN LOOKDIRUP(fwd, sunVec:NORMALIZED).
}

GLOBAL FUNCTION _landingTargetRefineTick {
    PARAMETER ctx.

    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL refineAge IS TIME:SECONDS - ctx["STATE_ENTERED"].
    LOCAL controlHeight IS MIN(_landingTargetHeight(ctx), _landingBottomRadar()).
    LOCAL descentSpeed IS lmDescentSpeed(
        controlHeight, TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED).
    LOCAL targetVs IS -descentSpeed.
    LOCAL targetPos IS LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]):POSITION.
    LOCAL posErr IS VXCL(ctx["UP_VEC"], targetPos - ctx["POSITION"]).
    LOCAL desiredVel IS posErr * LANDING_HOVER_REFINE_SPEED_GAIN.
    IF desiredVel:MAG > LANDING_TARGET_REFINE_HSPEED {
        SET desiredVel TO desiredVel:NORMALIZED * LANDING_TARGET_REFINE_HSPEED.
    }
    LOCAL velErr IS desiredVel - ctx["H_VEL"].
    LOCAL targetReady IS posErr:MAG < 5
        AND horizontalSpeed <= LANDING_TARGET_REFINE_HSPEED.
    IF NOT ctx["TARGET_REFINE_LOGGED"] {
        SET ctx["TARGET_REFINE_LOGGED"] TO TRUE.
        mLog("STATS target-refine entry dist="
            + ROUND(posErr:MAG,1)
            + " hs=" + ROUND(horizontalSpeed,1)
            + " vs=" + ROUND(ctx["V_SPEED"],1)
            + "/" + ROUND(targetVs,1)).
    }
    LOCAL climbRaw IS ctx["V_SPEED"]
        > targetVs + LANDING_TARGET_REFINE_CLIMB_LIMIT.
    LOCAL climbArmed IS refineAge >= LANDING_TARGET_REFINE_CLIMB_ARM_TIME.
    IF climbRaw AND climbArmed {
        IF ctx["TARGET_REFINE_CLIMB_SINCE"] = 0 {
            SET ctx["TARGET_REFINE_CLIMB_SINCE"] TO TIME:SECONDS.
        }
    } ELSE {
        SET ctx["TARGET_REFINE_CLIMB_SINCE"] TO 0.
    }
    LOCAL climbLimited IS ctx["TARGET_REFINE_CLIMB_SINCE"] > 0
        AND TIME:SECONDS - ctx["TARGET_REFINE_CLIMB_SINCE"]
            >= LANDING_TARGET_REFINE_CLIMB_TIME.
    LOCAL timedOut IS refineAge >= LANDING_TARGET_REFINE_MAX_TIME.

    IF climbLimited OR timedOut {
        SET ctx["HOVER_REFINED"] TO TRUE.
        _landingSetThrottle(ctx, 0).
        IF climbLimited {
            mLog("STATS target-refine exit reason=climb dist="
                + ROUND(posErr:MAG,1)
                + " age=" + ROUND(refineAge,1)
                + " hs=" + ROUND(horizontalSpeed,1)
                + " vs=" + ROUND(ctx["V_SPEED"],1)
                + "/" + ROUND(targetVs,1)).
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "target refine climb guard triggered").
        } ELSE {
            mLog("STATS target-refine exit reason=timeout dist="
                + ROUND(posErr:MAG,1)
                + " age=" + ROUND(refineAge,1)
                + " hs=" + ROUND(horizontalSpeed,1)
                + " vs=" + ROUND(ctx["V_SPEED"],1)
                + "/" + ROUND(targetVs,1)).
            _landingSetState(ctx, "VERTICAL_DESCENT",
                "target refine timeout").
        }
        RETURN.
    }

    LOCAL steeringTarget IS _landingTargetRefineSteering(ctx).
    _landingSetSteering(ctx, steeringTarget).
    LOCAL maxAcc IS ctx["MAX_ACC"].
    LOCAL gravAcc IS ctx["GRAV"].
    LOCAL hoverThr IS 0.
    IF maxAcc > 0 {
        SET hoverThr TO gravAcc / maxAcc.
    }
    LOCAL verticalThrottle IS 0.
    IF maxAcc > 0 {
        LOCAL verticalFrac IS MAX(0.1,
            VDOT(steeringTarget:NORMALIZED, ctx["UP_VEC"]:NORMALIZED)).
        LOCAL verticalAccDemand IS gravAcc + targetVs - ctx["V_SPEED"].
        SET verticalThrottle TO MAX(0, MIN(1,
            verticalAccDemand / (maxAcc * verticalFrac))).
    }
    LOCAL correctionThrottle IS 0.
    LOCAL requiredLateralAcc IS velErr:MAG * 0.1.
    IF maxAcc > 0 AND NOT targetReady AND requiredLateralAcc > 0.01 {
        LOCAL correctionCeiling IS MIN(1,
            MIN(hoverThr * 1.5,
                hoverThr + requiredLateralAcc / maxAcc)).
        LOCAL correctionFloor IS MIN(correctionCeiling, hoverThr * 0.5).
        SET correctionThrottle TO MAX(correctionFloor,
            MIN(correctionCeiling,
                hoverThr + requiredLateralAcc / maxAcc)).
    }
    _landingSetThrottle(ctx, MAX(verticalThrottle, correctionThrottle)).

    LOCAL refineEta IS MAX(0,
        MIN(LANDING_TARGET_REFINE_ACCEPT_TIME,
            LANDING_TARGET_REFINE_MAX_TIME) - refineAge).
    _landingHudText(ctx, "TARGET REFINE hs=" + ROUND(horizontalSpeed,1)
        + "/" + ROUND(LANDING_TARGET_REFINE_HSPEED,1)
        + " d=" + ROUND(posErr:MAG,1)
        + " vErr=" + ROUND(velErr:MAG,1)
        + " age=" + ROUND(refineAge,0)
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + "/" + ROUND(targetVs,1)
        + " cThr=" + ROUND(correctionThrottle,2)
        + " thr=" + ROUND(ctx["TARGET_THROTTLE"],2),
        1, 2, 13, CYAN, FALSE, refineEta).

    IF targetReady {
        mLog("STATS target-refine exit reason=position-captured dist="
            + ROUND(posErr:MAG,1)
            + " age=" + ROUND(refineAge,1)
            + " hs=" + ROUND(horizontalSpeed,1)).
        _landingSetState(ctx, "APPROACH", "target refine position captured").
    }
}

GLOBAL FUNCTION _landingApproachTick {
    PARAMETER ctx.

    LOCAL distToTarget IS lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL approachHeight IS _landingTargetHeight(ctx).
    LOCAL bottomAlt IS _landingBottomRadar().
    LOCAL controlHeight IS MIN(approachHeight, bottomAlt).
    LOCAL horizontalAcc IS _landingHorizontalBrakeAcc(ctx).
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

GLOBAL FUNCTION _landingHoverRefineTick {
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
    LOCAL settleRadius IS MIN(
        LANDING_HOVER_REFINE_ACCEPT_RADIUS,
        LANDING_HOVER_REFINE_SETTLE_RADIUS).
    LOCAL settleHspeed IS MIN(
        LANDING_HOVER_REFINE_ACCEPT_HSPEED,
        LANDING_HOVER_REFINE_SETTLE_HSPEED).
    LOCAL transitDist IS MAX(0, distToTarget - settleRadius).
    LOCAL desiredSpeed IS MIN(LANDING_HOVER_REFINE_MAX_SPEED,
        transitDist * LANDING_HOVER_REFINE_SPEED_GAIN).
    LOCAL stopSpeed IS SQRT(MAX(0, 2 * ctx["MAX_ACC"] * 0.35 * transitDist)).
    SET desiredSpeed TO MIN(desiredSpeed, stopSpeed).

    _landingSetSteering(ctx, lmApproachSteering(
        ctx["TARGET_LAT"], ctx["TARGET_LNG"], desiredSpeed, ctx["H_VEL"],
        ctx["UP_VEC"], ctx["POSITION"],
        LANDING_HOVER_REFINE_TARGET_WEIGHT)).
    LOCAL bottomAlt IS _landingBottomRadar().
    LOCAL holdBottom IS ctx["HOVER_HOLD_BOTTOM"].
    IF holdBottom <= 0 {
        SET holdBottom TO bottomAlt.
        SET ctx["HOVER_HOLD_BOTTOM"] TO holdBottom.
    }
    LOCAL hoverTargetVs IS MAX(-LANDING_HOVER_REFINE_ALT_VSPEED,
        MIN(LANDING_HOVER_REFINE_ALT_VSPEED,
            (holdBottom - bottomAlt) * LANDING_HOVER_REFINE_ALT_GAIN)).
    _landingSetThrottle(ctx, lmVerticalThrottle(
        hoverTargetVs, ctx["MAX_ACC"], ctx["GRAV"], ctx["V_SPEED"])).

    LOCAL hoverEta IS MAX(0,
        (distToTarget - settleRadius)
            / MAX(0.1, horizontalSpeed)).
    _landingHudText(ctx, "HOVER d=" + ROUND(distToTarget,1)
        + " hs=" + ROUND(horizontalSpeed,1)
        + "/" + ROUND(desiredSpeed,1)
        + " stop=" + ROUND(stopSpeed,1)
        + " bottom=" + ROUND(bottomAlt,0)
        + "/" + ROUND(holdBottom,0)
        + " vs=" + ROUND(ctx["V_SPEED"],1)
        + "/" + ROUND(hoverTargetVs,1),
        1, 2, 13, GREEN, FALSE, hoverEta).

    IF distToTarget <= settleRadius
            AND horizontalSpeed <= settleHspeed {
        SET ctx["HOVER_REFINED"] TO TRUE.
        _landingSetState(ctx, "VERTICAL_DESCENT",
            "refinement complete, final drop").
    }
}

GLOBAL FUNCTION _landingVerticalTick {
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

GLOBAL FUNCTION _landingSurfaceSettleTick {
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
