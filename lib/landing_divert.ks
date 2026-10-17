// ============================================================
// landing_divert.ks - Incremental local-site search during powered descent.
// (0:/lib/landing_divert.ks)
// ============================================================
@LAZYGLOBAL OFF.

LOCAL FUNCTION _landingDivertStart {
    PARAMETER ctx.
    PARAMETER emergency.
    PARAMETER retried IS FALSE.
    // Predict horizontal rest using the low-speed controller's net budget.
    // A fast ballistic impact is not the post-brake landing footprint.
    LOCAL netAcc IS lmBrakeNetAcc(ctx["MAX_ACC"], ctx["GRAV"]).
    LOCAL stopOffset IS ctx["H_VEL"] * ctx["H_SPEED"] / (2 * MAX(0.01, netAcc)).
    LOCAL center IS SHIP:BODY:GEOPOSITIONOF(SHIP:POSITION + stopOffset).
    LOCAL slopeLimit IS LANDING_TERRAIN_MAX_SLOPE.
    IF emergency { SET slopeLimit TO MIN(15, LANDING_DIVERT_EMERGENCY_SLOPE). }
    // Cover the upright controller's reachable area densely instead of
    // spending most samples on a kilometre grid it cannot traverse in time.
    LOCAL lateralAcc IS lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"]).
    LOCAL radiusM IS MIN(MAX(0, LANDING_DIVERT_SEARCH_RADIUS),
        MAX(0, lateralAcc) * MAX(0, LANDING_APPROACH_MAX_TIME) ^ 2 / 4).
    LOCAL stepM IS MAX(20, MIN(LANDING_DIVERT_SEARCH_STEP, radiusM / 10)).
    SET ctx["DIVERT_SEARCH"] TO LEXICON("LAT", center:LAT, "LNG", center:LNG,
        "INDEX", -1, "STARTED", TIME:SECONDS, "EXHAUSTED", FALSE,
        "RETRIED", retried, "START_HS", ctx["H_SPEED"], "CHECKED", 0,
        "REJECTS", LEXICON("reachability", 0, "terrain-grade", 0,
            "altitude-clearance", 0, "light", 0),
        "RADIUS", radiusM, "STEP", stepM, "MIN_GRADE", -1,
        "EMERGENCY", emergency, "SLOPE_LIMIT", slopeLimit,
        "LAST_REASON", "none", "LAST_GRADE", -1, "LAST_DIST", 0, "LAST_TRANSIT", 0).
    SET ctx["DIVERT_PENDING"] TO TRUE.
    SET ctx["DIVERT_ELEVATION"] TO MAX(ctx["DIVERT_ELEVATION"],
        SHIP:ALTITUDE - _landingBottomRadar()).
    mLogWarn("STATS landing-divert search height=" + ROUND(_landingBottomRadar(),0)
        + " hs=" + ROUND(ctx["H_SPEED"],1) + " emergency=" + emergency
        + " slopeLimit=" + slopeLimit + " radius=" + radiusM + " step=" + stepM
        + " retry=" + retried + " lat=" + center:LAT + " lng=" + center:LNG).
}

LOCAL FUNCTION _landingDivertRetryReady {
    PARAMETER ctx.
    PARAMETER search.
    IF search["RETRIED"] OR search["REJECTS"]["reachability"] = 0 { RETURN FALSE. }
    // A nearby site tested while braking may become reachable only after
    // its grid point was visited. Do not permanently latch that old result.
    LOCAL netAcc IS lmBrakeNetAcc(ctx["MAX_ACC"], ctx["GRAV"]).
    LOCAL stopOffset IS ctx["H_VEL"] * ctx["H_SPEED"] / (2 * MAX(0.01, netAcc)).
    LOCAL center IS SHIP:BODY:GEOPOSITIONOF(SHIP:POSITION + stopOffset).
    LOCAL lateralAcc IS MAX(0.01, lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"])).
    LOCAL transitTime IS 2 * SQRT(MAX(0, lmDistanceToTarget(center:LAT, center:LNG)) / lateralAcc)
        + ctx["H_SPEED"] / lateralAcc.
    // Do not spend the one retry while even its new center is unreachable.
    IF transitTime > LANDING_APPROACH_MAX_TIME { RETURN FALSE. }
    IF search["START_HS"] - ctx["H_SPEED"] >= MAX(1, search["START_HS"] * 0.25) {
        RETURN TRUE.
    }
    RETURN geoDistance(search["LAT"], search["LNG"], center:LAT, center:LNG)
        >= MAX(20, LANDING_DIVERT_SEARCH_STEP / 2).
}

LOCAL FUNCTION _landingDivertCandidate {
    PARAMETER ctx.
    PARAMETER siteLat.
    PARAMETER siteLng.
    PARAMETER slopeLimit.
    PARAMETER preview IS FALSE.
    PARAMETER arrivalUt IS -1.

    LOCAL rejected IS LEXICON("OK", FALSE, "REASON", "reachability", "GRADE", -1,
        "DIST", -1, "TRANSIT", -1, "ELEVATION", -999999).
    IF ABS(siteLat) > 90 { RETURN rejected. }
    LOCAL distance IS 0.
    LOCAL lateralAcc IS lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"]).
    LOCAL transitTime IS 0.
    // A forecast only caches terrain/light; it never approves a target.
    // Actual selection below always repeats the current reachability gate.
    IF NOT preview {
        SET distance TO lmDistanceToTarget(siteLat, siteLng).
        SET transitTime TO 2 * SQRT(MAX(0, distance) / MAX(0.01, lateralAcc))
            + ctx["H_SPEED"] / MAX(0.01, lateralAcc).
    }
    SET rejected["DIST"] TO distance.
    SET rejected["TRANSIT"] TO transitTime.
    IF transitTime > LANDING_APPROACH_MAX_TIME { RETURN rejected. }
    LOCAL elevation IS LATLNG(siteLat, siteLng):TERRAINHEIGHT.
    SET rejected["ELEVATION"] TO elevation.
    IF elevation + LANDING_BRAKE_CLEARANCE >= SHIP:ALTITUDE {
        SET rejected["REASON"] TO "altitude-clearance".
        RETURN rejected.
    }
    // A coarse-grid winner can hide a steep local patch. Validate every
    // candidate at the final 20 m scale, including emergency candidates.
    LOCAL grade IS landingTerrainGrade(siteLat, siteLng, 20).
    SET rejected["GRADE"] TO grade.
    IF grade > TAN(slopeLimit) {
        SET rejected["REASON"] TO "terrain-grade".
        RETURN rejected.
    }
    IF arrivalUt < 0 { SET arrivalUt TO TIME:SECONDS + MAX(1, lmTimeToImpact()). }
    LOCAL light IS landingLightWindow(siteLat, siteLng, arrivalUt,
        LANDING_DIVERT_KERBIN_TOLERANCE, LANDING_DIVERT_REQUIRE_KERBIN).
    IF NOT light["OK"] {
        SET rejected["REASON"] TO light["REASON"].
        RETURN rejected.
    }
    RETURN LEXICON("OK", TRUE, "LAT", siteLat, "LNG", siteLng,
        "ELEVATION", elevation, "GRADE", grade,
        "DIST", distance, "TRANSIT", transitTime,
        "SUN", light["SUN"], "KERBIN", light["KERBIN"]).
}

LOCAL FUNCTION _landingDivertSurveyAhead {
    PARAMETER ctx.
    LOCAL previous IS ctx["DIVERT_PREVIEW"].
    IF TIME:SECONDS - previous["AT"] < 2 OR ctx["MAX_ACC"] <= ctx["GRAV"] { RETURN. }
    LOCAL coastTime IS 0.
    IF ctx["STATE"] = "COAST" OR ctx["STATE"] = "BRAKE_ALIGN" {
        SET coastTime TO _landingBrakeGateInfo(ctx)["V_ETA"].
    }
    LOCAL delay IS MAX(0, LANDING_BRAKE_REACTION_TIME).
    LOCAL futureDown IS ctx["DOWN_SPEED"] + ctx["GRAV"] * (coastTime + delay).
    LOCAL stopTime IS SQRT(ctx["H_SPEED"] ^ 2 + futureDown ^ 2)
        / MAX(0.01, lmBrakeNetAcc(ctx["MAX_ACC"], ctx["GRAV"])) * MAX(1, BURN_MARGIN).
    LOCAL fallHeight IS ctx["DOWN_SPEED"] * coastTime + ctx["GRAV"] * coastTime ^ 2 / 2
        + futureDown * stopTime / 2.
    LOCAL center IS SHIP:BODY:GEOPOSITIONOF(SHIP:POSITION
        + ctx["H_VEL"] * (coastTime + delay + stopTime / 2) - ctx["UP_VEC"] * fallHeight).
    LOCAL arrivalUt IS TIME:SECONDS + coastTime + delay + stopTime
        + MAX(0, _landingBottomRadar() - fallHeight) / MAX(10, HIGH_DESCENT_SPEED).
    LOCAL site IS _landingDivertCandidate(ctx, center:LAT, center:LNG,
        LANDING_TERRAIN_MAX_SLOPE, TRUE, arrivalUt).
    SET site["LAT"] TO center:LAT.
    SET site["LNG"] TO center:LNG.
    SET site["AT"] TO TIME:SECONDS.
    SET site["LOG_AT"] TO previous["LOG_AT"].
    SET ctx["DIVERT_PREVIEW"] TO site.
    IF TIME:SECONDS - site["LOG_AT"] >= 10 {
        SET site["LOG_AT"] TO TIME:SECONDS.
        mLog("STATS landing-divert preview provisional=true ok=" + site["OK"]
            + " lat=" + center:LAT + " lng=" + center:LNG + " grade=" + site["GRADE"]
            + " hs=" + ROUND(ctx["H_SPEED"],1) + " coast=" + ROUND(coastTime,1)).
    }
}

GLOBAL FUNCTION landingReviewReachableSite {
    PARAMETER ctx.
    IF LANDING_FLEXIBLE_SITE <= 0 OR NOT ctx["HAS_TARGET"] { RETURN TRUE. }
    IF ctx["H_SPEED"] > APPROACH_HSPEED {
        IF LANDING_ECONOMY_BRAKE > 0 { _landingDivertSurveyAhead(ctx). }
        RETURN TRUE.
    }
    IF NOT ctx["DIVERT_PENDING"] {
        LOCAL dist IS lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        LOCAL lateralAcc IS lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"]).
        LOCAL transitTime IS 2 * SQRT(MAX(0, dist) / MAX(0.01, lateralAcc))
            + ctx["H_SPEED"] / MAX(0.01, lateralAcc).
        IF ctx["HOVER_TERRAIN_DONE"] AND transitTime <= LANDING_APPROACH_MAX_TIME {
            RETURN TRUE.
        }
        _landingDivertStart(ctx, FALSE).
    }
    LOCAL search IS ctx["DIVERT_SEARCH"].
    IF search["EXHAUSTED"] {
        IF _landingDivertRetryReady(ctx, search) {
            mLogWarn("STATS landing-divert retry reason=changed-reachability"
                + " startHs=" + ROUND(search["START_HS"],1) + " hs=" + ROUND(ctx["H_SPEED"],1)).
            _landingDivertStart(ctx, FALSE, TRUE).
        }
        RETURN TRUE.
    }
    LOCAL stepM IS search["STEP"].
    LOCAL radiusM IS search["RADIUS"].
    LOCAL ring IS 0.
    UNTIL search["INDEX"] < (2 * ring + 1) ^ 2 { SET ring TO ring + 1. }
    IF ring * stepM > radiusM
            OR TIME:SECONDS - search["STARTED"] >= MAX(1, LANDING_DIVERT_SEARCH_TIME) {
        IF NOT search["EMERGENCY"]
                AND MIN(15, LANDING_DIVERT_EMERGENCY_SLOPE) > search["SLOPE_LIMIT"] {
            _landingDivertStart(ctx, TRUE, search["RETRIED"]).
            // Preserve the normal pass's braking state and rejection totals.
            SET ctx["DIVERT_SEARCH"]["START_HS"] TO search["START_HS"].
            SET ctx["DIVERT_SEARCH"]["REJECTS"] TO search["REJECTS"].
            SET ctx["DIVERT_SEARCH"]["CHECKED"] TO search["CHECKED"].
        } ELSE IF _landingDivertRetryReady(ctx, search) {
            mLogWarn("STATS landing-divert retry reason=changed-reachability"
                + " startHs=" + ROUND(search["START_HS"],1) + " hs=" + ROUND(ctx["H_SPEED"],1)).
            _landingDivertStart(ctx, FALSE, TRUE).
        } ELSE {
            SET search["EXHAUSTED"] TO TRUE.
            LOCAL minSlope IS -1.
            IF search["MIN_GRADE"] >= 0 { SET minSlope TO ARCTAN2(search["MIN_GRADE"],1). }
            mLogError("STATS landing-divert unavailable reason=" + search["LAST_REASON"]
                + " grade=" + ROUND(search["LAST_GRADE"],3)
                + " samples=" + search["CHECKED"] + " height=" + ROUND(_landingBottomRadar(),0)
                + " emergency=" + search["EMERGENCY"] + " slopeLimit=" + search["SLOPE_LIMIT"]
                + " retry=" + search["RETRIED"] + " lastDist=" + ROUND(search["LAST_DIST"],1)
                + " minSlope=" + minSlope
                + " transit=" + ROUND(search["LAST_TRANSIT"],1)
                + " reachRejected=" + search["REJECTS"]["reachability"]
                + " terrainRejected=" + search["REJECTS"]["terrain-grade"]
                + " clearanceRejected=" + search["REJECTS"]["altitude-clearance"]
                + " lightRejected=" + search["REJECTS"]["light"]
                + ". No site accepted; powered braking retained. Manual intervention needed.").
        }
        RETURN TRUE.
    }

    // Square spiral: nearest rings first, one candidate per invocation.
    // Prefer the original site if it is still safe and reachable.
    LOCAL siteLat IS ctx["TARGET_LAT"].
    LOCAL siteLng IS ctx["TARGET_LNG"].
    IF search["INDEX"] < 0 AND ctx["DIVERT_PREVIEW"]["OK"] {
        SET siteLat TO ctx["DIVERT_PREVIEW"]["LAT"].
        SET siteLng TO ctx["DIVERT_PREVIEW"]["LNG"].
        SET ctx["DIVERT_PREVIEW"]["OK"] TO FALSE.
    } ELSE IF search["INDEX"] >= 0 {
        LOCAL northM IS 0.
        LOCAL eastM IS 0.
        IF ring > 0 {
            LOCAL sideOffset IS search["INDEX"] - (2 * ring - 1) ^ 2.
            IF sideOffset < 2 * ring {
                SET northM TO -ring.
                SET eastM TO -ring + sideOffset.
            } ELSE IF sideOffset < 4 * ring {
                SET northM TO -ring + sideOffset - 2 * ring.
                SET eastM TO ring.
            } ELSE IF sideOffset < 6 * ring {
                SET northM TO ring.
                SET eastM TO ring - (sideOffset - 4 * ring).
            } ELSE {
                SET northM TO ring - (sideOffset - 6 * ring).
                SET eastM TO -ring.
            }
        }
        LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
        SET siteLat TO search["LAT"] + northM * stepM * degPerM.
        SET siteLng TO search["LNG"] + eastM * stepM * degPerM
            / MAX(0.01, COS(search["LAT"])).
    }
    SET search["INDEX"] TO search["INDEX"] + 1.
    LOCAL site IS _landingDivertCandidate(ctx, siteLat, siteLng, search["SLOPE_LIMIT"]).
    SET search["CHECKED"] TO search["CHECKED"] + 1.
    SET ctx["DIVERT_ELEVATION"] TO MAX(ctx["DIVERT_ELEVATION"], site["ELEVATION"]).
    IF site["GRADE"] >= 0 AND (search["MIN_GRADE"] < 0 OR site["GRADE"] < search["MIN_GRADE"]) {
        SET search["MIN_GRADE"] TO site["GRADE"].
        mLog("STATS landing-divert best emergency=" + search["EMERGENCY"]
            + " slope=" + ARCTAN2(site["GRADE"],1) + " grade=" + site["GRADE"]
            + " lat=" + siteLat + " lng=" + siteLng + " distance=" + site["DIST"]
            + " transit=" + site["TRANSIT"]).
    }
    IF NOT site["OK"] {
        SET search["LAST_REASON"] TO site["REASON"].
        SET search["LAST_GRADE"] TO site["GRADE"].
        SET search["LAST_DIST"] TO site["DIST"].
        SET search["LAST_TRANSIT"] TO site["TRANSIT"].
        LOCAL category IS "light".
        IF site["REASON"] = "reachability" OR site["REASON"] = "terrain-grade"
                OR site["REASON"] = "altitude-clearance" { SET category TO site["REASON"]. }
        SET search["REJECTS"][category] TO search["REJECTS"][category] + 1.
        _landingCacheTick(ctx).
        RETURN TRUE.
    }

    LOCAL shift IS geoDistance(ctx["TARGET_LAT"], ctx["TARGET_LNG"], site["LAT"], site["LNG"]).
    SET ctx["TARGET_LAT"] TO site["LAT"].
    SET ctx["TARGET_LNG"] TO site["LNG"].
    SET ctx["TARGET_ELEVATION"] TO site["ELEVATION"].
    SET ctx["TERRAIN_DONE"] TO TRUE.
    SET ctx["HOVER_TERRAIN_DONE"] TO TRUE.
    SET ctx["DIVERT_PENDING"] TO FALSE.
    SET TARGET_LAT TO site["LAT"].
    SET TARGET_LNG TO site["LNG"].
    SET TARGET_LOCK TO 1.
    SET TARGET_WAYPOINT TO "".
    missionOverrideUpdate(LEXICON("TARGET_LAT", TARGET_LAT, "TARGET_LNG", TARGET_LNG,
        "TARGET_LOCK", TARGET_LOCK, "TARGET_WAYPOINT", TARGET_WAYPOINT)).
    IF ADDONS:TR:AVAILABLE { ADDONS:TR:SETTARGET(LATLNG(TARGET_LAT, TARGET_LNG)). }
    mLogWarn("STATS landing-divert accepted shift=" + ROUND(shift,0)
        + "m lat=" + TARGET_LAT + " lng=" + TARGET_LNG
        + " grade=" + ROUND(site["GRADE"],3) + " sun=" + ROUND(site["SUN"],1)
        + " kerbin=" + ROUND(site["KERBIN"],1)
        + " emergency=" + search["EMERGENCY"] + " slopeLimit=" + search["SLOPE_LIMIT"]
        + " requireKerbin=" + LANDING_DIVERT_REQUIRE_KERBIN).
    _landingCacheTick(ctx).
    RETURN TRUE.
}
