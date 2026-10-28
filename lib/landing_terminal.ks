// landing_terminal.ks - target refinement, approach, final descent, touchdown.

// Time for an accelerate/cruise/brake translation, with signed closing speed.
// An away-going or cross-track velocity must first be removed. Unlike the
// old triangle-only estimate, respect the speed actually commanded in flight.
GLOBAL FUNCTION lmApproachTransitTime {
    PARAMETER distance.
    PARAMETER alongSpeed.
    PARAMETER crossSpeed.
    PARAMETER lateralAcc.
    PARAMETER cruiseSpeed.
    LOCAL accel IS MAX(0.01,lateralAcc).
    LOCAL remaining IS MAX(0,distance-LANDING_HOVER_REFINE_SETTLE_RADIUS).
    LOCAL delay IS MAX(1,LANDING_APPROACH_RESPONSE_TIME)+MAX(0,crossSpeed)/accel.
    LOCAL stopDistance IS MAX(0,alongSpeed)^2/(2*accel).
    IF alongSpeed > 0 AND stopDistance > remaining {
        RETURN delay+alongSpeed/accel+2*SQRT((stopDistance-remaining)/accel).
    }
    LOCAL cap IS MAX(0.1,cruiseSpeed).
    IF alongSpeed > cap {
        SET remaining TO MAX(0,remaining-(alongSpeed^2-cap^2)/(2*accel)).
        SET delay TO delay+(alongSpeed-cap)/accel.
        SET alongSpeed TO cap.
    }
    LOCAL peak IS MIN(cap,SQRT(MAX(0,accel*remaining+alongSpeed^2/2))).
    LOCAL ramps IS (2*peak^2-alongSpeed^2)/(2*accel).
    RETURN delay+MAX(0,peak-alongSpeed)/accel+peak/accel
        + MAX(0,remaining-ramps)/MAX(0.1,peak).
}

// Fixed-target recovery reserves a full coupled stop at the current height,
// rather than slowing in proportion to an arbitrary 3km altitude ramp.
GLOBAL FUNCTION lmFixedApproachPlan {
    PARAMETER height.
    PARAMETER distance.
    PARAMETER alongSpeed.
    PARAMETER crossSpeed.
    PARAMETER downSpeed.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    LOCAL lateralAcc IS lmApproachAcceleration(maxAcc,gravAcc).
    LOCAL cap IS MIN(MAX_APPROACH_SPEED,lmApproachSpeedLimit(distance,lateralAcc)).
    IF height <= MAX(BRAKE_MARGIN,LANDING_BRAKE_CLEARANCE)+LANDING_FINAL_HOVER_ALT {
        // The main-burn clearance cannot authorize flight this near the
        // ground. Keep the existing slow final-settling corridor instead.
        SET cap TO MIN(cap,LANDING_HOVER_REFINE_MAX_SPEED).
        RETURN LEXICON("SPEED",MAX(0,cap),"DESCENT",lmApproachDescentSpeed(
            lmDescentSpeed(height,TOUCHDOWN_SPEED,UPRIGHT_ALT,HIGH_DESCENT_SPEED),
            height,distance,SQRT(alongSpeed^2+crossSpeed^2),lateralAcc),
            "TRANSIT",lmApproachTransitTime(distance,alongSpeed,crossSpeed,lateralAcc,MAX(0,cap)),
            "STOP_HEIGHT",MAX(BRAKE_MARGIN,LANDING_BRAKE_CLEARANCE)).
    }
    LOCAL low IS 0.
    LOCAL high IS MAX(0,cap).
    LOCAL iteration IS 0.
    UNTIL iteration >= 10 {
        LOCAL speed IS (low+high)/2.
        LOCAL envelope IS lmBrakeEnvelope(speed,MAX(0,downSpeed),maxAcc,gravAcc,
            MAX(0,LANDING_BRAKE_REACTION_TIME)).
        IF envelope["V"] <= height { SET low TO speed. }
        ELSE { SET high TO speed. }
        SET iteration TO iteration+1.
    }
    LOCAL transit IS lmApproachTransitTime(distance,alongSpeed,crossSpeed,lateralAcc,low).
    LOCAL reserve IS lmBrakeEnvelope(MAX(low,SQRT(alongSpeed^2+crossSpeed^2)),
        MAX(0,downSpeed),maxAcc,gravAcc,
        MAX(0,LANDING_BRAKE_REACTION_TIME)).
    LOCAL scheduled IS lmDescentSpeed(height,TOUCHDOWN_SPEED,UPRIGHT_ALT,HIGH_DESCENT_SPEED).
    LOCAL descent IS MIN(scheduled,MAX(0,height-reserve["V"])/MAX(1,transit)).
    RETURN LEXICON("SPEED",low,"DESCENT",descent,"TRANSIT",transit,
        "STOP_HEIGHT",reserve["V"]).
}

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
    IF _landingBottomRadar() > TERMINAL_ALT {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "target refinement above terminal corridor").
        RETURN.
    }
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

    // This state stabilizes velocity; it cannot translate hundreds of
    // meters at 1 m/s inside a 20-second timeout. Hand off to APPROACH.
    LOCAL stabilized IS horizontalSpeed <= LANDING_TARGET_REFINE_HSPEED
        OR (refineAge >= LANDING_TARGET_REFINE_ACCEPT_TIME
            AND horizontalSpeed <= LANDING_TARGET_REFINE_ACCEPT_HSPEED).
    IF stabilized OR climbLimited OR timedOut {
        LOCAL nextState IS "APPROACH".
        IF stabilized AND landingEconomyTerminalSite(ctx) {
            SET nextState TO "VERTICAL_DESCENT".
            SET ctx["HOVER_REFINED"] TO TRUE.
        }
        IF controlHeight <= LANDING_FINAL_HOVER_ALT {
            SET nextState TO "VERTICAL_DESCENT".
            SET ctx["HOVER_REFINED"] TO TRUE.
        }
        mLog("STATS target-refine exit next=" + nextState
            + " stabilized=" + stabilized + " timeout=" + timedOut
            + " climb=" + climbLimited + " dist=" + ROUND(posErr:MAG,1)
            + " age=" + ROUND(refineAge,1) + " hs=" + ROUND(horizontalSpeed,1)).
        _landingSetState(ctx, nextState, "lateral stabilization handoff").
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
        1, 2, 13, CYAN, FALSE, refineEta, targetVs, desiredVel:MAG).


}

GLOBAL FUNCTION _landingFinalTerrainCheck {
    PARAMETER ctx.
    IF LANDING_FLEXIBLE_SITE > 0 { RETURN. }
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

}

GLOBAL FUNCTION _landingApproachTick {
    PARAMETER ctx.

    IF NOT landingReviewReachableSite(ctx) {
        SET landingAbortFlag TO TRUE.
        RETURN.
    }
    IF ctx["DIVERT_PENDING"] {
        _landingSetState(ctx, "BRAKING_BURN", "local terrain search").
        RETURN.
    }
    IF _landingBottomRadar() > TERMINAL_ALT {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "approach above terminal corridor").
        RETURN.
    }
    IF landingEconomyTerminalSite(ctx) {
        SET ctx["HOVER_REFINED"] TO TRUE.
        _landingSetState(ctx,"VERTICAL_DESCENT","economy checked touchdown footprint").
        RETURN.
    }
    _landingFinalTerrainCheck(ctx).

    LOCAL distToTarget IS lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL horizontalSpeed IS ctx["H_SPEED"].
    LOCAL approachHeight IS _landingTargetHeight(ctx).
    LOCAL bottomAlt IS _landingBottomRadar().
    LOCAL controlHeight IS MIN(approachHeight, bottomAlt).
    LOCAL horizontalAcc IS lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"]).
    LOCAL desiredSpeed IS MIN(MAX_APPROACH_SPEED,
        lmApproachSpeedLimit(distToTarget,horizontalAcc)).
    LOCAL descentSpeed IS lmApproachDescentSpeed(lmDescentSpeed(
        controlHeight, TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED),
        controlHeight, distToTarget, horizontalSpeed, horizontalAcc).
    LOCAL altitudeCap IS MAX(LANDING_HOVER_REFINE_MAX_SPEED, MAX_APPROACH_SPEED
        * MAX(0, MIN(1, (controlHeight - HOVER_ALT)
            / APPROACH_SPEED_ALTITUDE_WINDOW))).
    LOCAL recoveryTime IS 0.
    LOCAL stopHeight IS 0.
    LOCAL direction IS lmDirectionToTarget(ctx["TARGET_LAT"],ctx["TARGET_LNG"],
        ctx["UP_VEC"],ctx["POSITION"]).
    LOCAL alongSpeed IS VDOT(ctx["H_VEL"],direction).
    LOCAL crossSpeed IS (ctx["H_VEL"]-alongSpeed*direction):MAG.
    LOCAL poweredRecovery IS LANDING_POWERED_LEAD > 0 AND LANDING_ECONOMY_BRAKE > 0
        AND LANDING_FLEXIBLE_SITE <= 0.
    IF poweredRecovery {
        LOCAL plan IS lmFixedApproachPlan(controlHeight,distToTarget,alongSpeed,crossSpeed,
            ctx["DOWN_SPEED"],ctx["MAX_ACC"],ctx["BRAKE_GRAV"]).
        SET desiredSpeed TO plan["SPEED"].
        SET descentSpeed TO plan["DESCENT"].
        SET recoveryTime TO plan["TRANSIT"].
        SET stopHeight TO plan["STOP_HEIGHT"].
    } ELSE { SET desiredSpeed TO MIN(desiredSpeed, altitudeCap). }
    LOCAL steeringTarget IS lmApproachSteering(
        ctx["TARGET_LAT"], ctx["TARGET_LNG"], desiredSpeed, ctx["H_VEL"],
        ctx["UP_VEC"], ctx["POSITION"]).
    _landingSetSteering(ctx,steeringTarget).

    LOCAL targetVs IS -descentSpeed.
    LOCAL throttle IS lmVerticalThrottle(targetVs,ctx["MAX_ACC"],ctx["GRAV"],ctx["V_SPEED"]).
    IF poweredRecovery {
        // Account for the upward thrust lost while translating under tilt.
        SET throttle TO MIN(1,throttle/MAX(0.1,VDOT(steeringTarget,ctx["UP_VEC"]))).
    }
    _landingSetThrottle(ctx,throttle).
    landingDiagnosticApproach(ctx,distToTarget,alongSpeed,crossSpeed,desiredSpeed,horizontalAcc).

    _landingHudText(ctx, "APPROACH d=" + ROUND(distToTarget,0)
        + " bottom=" + ROUND(bottomAlt,0)
        + " hs=" + ROUND(horizontalSpeed,1) + "/" + ROUND(desiredSpeed,1)
        + " along=" + ROUND(alongSpeed,1) + " cross=" + ROUND(crossSpeed,1)
        + " vs=" + ROUND(ctx["V_SPEED"],1) + "/" + ROUND(targetVs,1)
        + " tLat=" + ROUND(recoveryTime,1) + " stopH=" + ROUND(stopHeight,0),
        1, 2, 13, CYAN, FALSE, 0, targetVs, desiredSpeed).

    IF distToTarget <= LANDING_HOVER_REFINE_ACCEPT_RADIUS
            AND horizontalSpeed <= LANDING_HOVER_REFINE_ACCEPT_HSPEED {
        SET ctx["HOVER_REFINED"] TO TRUE.
        _landingSetState(ctx, "VERTICAL_DESCENT", "approach captured within landing tolerance").
    } ELSE IF bottomAlt <= LANDING_FINAL_HOVER_ALT {
        _landingSetState(ctx, "HOVER_REFINE", "low-altitude lateral settling").
    }

}

GLOBAL FUNCTION _landingHoverRefineTick {
    PARAMETER ctx.

    _landingFinalTerrainCheck(ctx).

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
    LOCAL stopSpeed IS SQRT(MAX(0, 2 * lmApproachAcceleration(
        ctx["MAX_ACC"], ctx["GRAV"]) * transitDist)).
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
    IF bottomAlt > LANDING_FINAL_HOVER_ALT {
        SET hoverTargetVs TO -lmApproachDescentSpeed(lmDescentSpeed(
            bottomAlt, TOUCHDOWN_SPEED, UPRIGHT_ALT, HIGH_DESCENT_SPEED),
            bottomAlt, distToTarget, horizontalSpeed,
            lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"])).
    }
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
        1, 2, 13, GREEN, FALSE, hoverEta, hoverTargetVs, desiredSpeed).

    LOCAL hoverAge IS TIME:SECONDS - ctx["STATE_ENTERED"].
    LOCAL precise IS distToTarget <= settleRadius AND horizontalSpeed <= settleHspeed.
    LOCAL acceptable IS distToTarget <= LANDING_HOVER_REFINE_ACCEPT_RADIUS
        AND horizontalSpeed <= LANDING_HOVER_REFINE_ACCEPT_HSPEED.
    LOCAL timedOut IS hoverAge >= LANDING_HOVER_REFINE_MAX_TIME.
    IF precise OR acceptable OR timedOut {
        mLog("STATS hover-refine exit precise=" + precise
            + " acceptable=" + acceptable + " timeout=" + timedOut
            + " dist=" + ROUND(distToTarget,1) + " age=" + ROUND(hoverAge,1)
            + " hs=" + ROUND(horizontalSpeed,1)).
        SET ctx["HOVER_REFINED"] TO TRUE.
        _landingSetState(ctx, "VERTICAL_DESCENT",
            "bounded final refinement complete").
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
    IF LANDING_ECONOMY_BRAKE > 0 AND LANDING_FLEXIBLE_SITE > 0 AND NOT finalHover
            AND NOT SHIP:BODY:ATM:EXISTS AND ctx["HAS_TARGET"] AND ctx["HOVER_TERRAIN_DONE"]
            AND horizontalSpeed <= TERMINAL_HSPEED
            AND lmDistanceToTarget(ctx["TARGET_LAT"],ctx["TARGET_LNG"]) <= VERTICAL_RADIUS {
        LOCAL verticalAcc IS MIN(ctx["PLAN_ACC"],ctx["MAX_ACC"]
            * MAX(0,VDOT(SHIP:FACING:FOREVECTOR,ctx["UP_VEC"]))).
        SET descentSpeed TO lmEconomyDescentSpeed(descentSpeed,
            MIN(bottomAlt,_landingTargetHeight(ctx)),horizontalSpeed,verticalAcc,ctx["BRAKE_GRAV"]).
    }
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
        1, 2, 13, GREEN, FALSE, touchdownEta, targetVs, 0).

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
