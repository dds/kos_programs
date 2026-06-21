// landing_coast.ks - COAST and COAST_MCC guidance track.

GLOBAL FUNCTION _landingCoastMccBurnVector {
    PARAMETER ctx.
    PARAMETER trajErr.

    LOCAL upVec IS ctx["UP_VEC"].
    LOCAL orbVel IS SHIP:VELOCITY:ORBIT.
    LOCAL hOrbVel IS VXCL(upVec, orbVel).
    IF hOrbVel:MAG < 0.1 {
        RETURN LEXICON("VALID", FALSE, "VEC", upVec, "MAG", 0).
    }

    LOCAL travelDir IS hOrbVel:NORMALIZED.
    LOCAL crossAxis IS VCRS(travelDir, upVec):NORMALIZED.
    LOCAL impactInfo IS _landingTrajImpactInfo(ctx).
    IF NOT impactInfo["FOUND"] {
        RETURN LEXICON("VALID", FALSE, "VEC", upVec, "MAG", 0).
    }
    LOCAL targetGeo IS LATLNG(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
    LOCAL impactGeo IS LATLNG(impactInfo["LAT"], impactInfo["LNG"]).
    LOCAL targetToImpact IS VXCL(upVec, impactGeo:POSITION - targetGeo:POSITION).
    LOCAL alongM IS VDOT(targetToImpact, travelDir).
    LOCAL crossVec IS targetToImpact - travelDir * alongM.
    LOCAL signedCross IS VDOT(crossVec, crossAxis).
    LOCAL desiredAlong IS LANDING_COAST_MCC_LEAD_DIST.
    LOCAL correctionVec IS ((desiredAlong - alongM) * travelDir)
        + ((0 - signedCross) * crossAxis).
    LOCAL burnVec IS VXCL(upVec, correctionVec).
    IF burnVec:MAG < 1 {
        RETURN LEXICON("VALID", FALSE, "VEC", upVec, "MAG", burnVec:MAG).
    }
    RETURN LEXICON("VALID", TRUE, "VEC", burnVec:NORMALIZED, "MAG", burnVec:MAG).
}

GLOBAL FUNCTION _landingCoastMccError {
    PARAMETER trajErr.
    LOCAL alongErr IS trajErr["ALONG"] - LANDING_COAST_MCC_LEAD_DIST.
    LOCAL crossErr IS trajErr["CROSS_SIGNED"].
    RETURN LEXICON(
        "DIST", SQRT(alongErr * alongErr + crossErr * crossErr),
        "ALONG_ERR", alongErr,
        "CROSS_ERR", crossErr
    ).
}

LOCAL FUNCTION _landingCoastMccThrottle {
    PARAMETER nextBrakeEta.

    LOCAL minThrottle IS MAX(0, MIN(1, LANDING_COAST_MCC_THROTTLE_MIN)).
    LOCAL maxThrottle IS MAX(minThrottle,
        MIN(1, LANDING_COAST_MCC_THROTTLE_MAX)).
    LOCAL earlyFrac IS MAX(0, MIN(1,
        (nextBrakeEta - LANDING_COAST_MCC_MIN_BRAKE_ETA)
            / MAX(1, LANDING_COAST_MCC_MIN_BRAKE_ETA))).
    RETURN minThrottle + (maxThrottle - minThrottle) * earlyFrac.
}

GLOBAL FUNCTION _landingCoastTick {
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
        LOCAL mccErr IS _landingCoastMccError(trajErr).
        IF trajErr["FOUND"]
                AND mccErr["DIST"] > LANDING_COAST_MCC_TRIGGER_DIST {
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

GLOBAL FUNCTION _landingCoastMccTick {
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
    LOCAL mccErr IS _landingCoastMccError(trajErr).
    IF mccErr["DIST"] <= LANDING_COAST_MCC_ACCEPT_DIST {
        _landingSetThrottle(ctx, 0).
        _landingSetState(ctx, "COAST", "MCC lead impact corrected").
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
    LOCAL mccThrottle IS _landingCoastMccThrottle(nextBrakeEta).

    IF TIME:SECONDS < ctx["MCC_PULSE_UNTIL"] {
        IF canBurn {
            _landingSetThrottle(ctx, mccThrottle).
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
        _landingSetThrottle(ctx, mccThrottle).
    } ELSE {
        _landingSetThrottle(ctx, 0).
    }

    _landingHudText(ctx, "COAST MCC trErr=" + ROUND(trajErr["DIST"],0)
        + " along=" + ROUND(trajErr["ALONG"],0)
        + " leadErr=" + ROUND(mccErr["ALONG_ERR"],0)
        + " cross=" + ROUND(trajErr["CROSS_SIGNED"],0)
        + " mccErr=" + ROUND(mccErr["DIST"],0)
        + " eta=" + ROUND(nextBrakeEta,0)
        + " aErr=" + ROUND(alignErr,1)
        + " upDot=" + ROUND(upDot,3)
        + " mThr=" + ROUND(mccThrottle,2)
        + " thr=" + ROUND(ctx["TARGET_THROTTLE"],2),
        1, 2, 13, CYAN, FALSE, nextBrakeEta).
}
