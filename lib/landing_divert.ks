// ============================================================
// landing_divert.ks - Incremental local-site search during powered descent.
// (0:/lib/landing_divert.ks)
// ============================================================
@LAZYGLOBAL OFF.

LOCAL FUNCTION _landingDivertStart {
    PARAMETER ctx.
    PARAMETER emergency.
    // Predict horizontal rest using the low-speed controller's net budget.
    // A fast ballistic impact is not the post-brake landing footprint.
    LOCAL netAcc IS lmBrakeNetAcc(ctx["MAX_ACC"], ctx["GRAV"]).
    LOCAL stopOffset IS ctx["H_VEL"] * ctx["H_SPEED"] / (2 * MAX(0.01, netAcc)).
    LOCAL center IS SHIP:BODY:GEOPOSITIONOF(SHIP:POSITION + stopOffset).
    LOCAL slopeLimit IS LANDING_TERRAIN_MAX_SLOPE.
    IF emergency { SET slopeLimit TO MIN(15, LANDING_DIVERT_EMERGENCY_SLOPE). }
    SET ctx["DIVERT_SEARCH"] TO LEXICON("LAT", center:LAT, "LNG", center:LNG,
        "INDEX", -1, "STARTED", TIME:SECONDS, "EXHAUSTED", FALSE,
        "EMERGENCY", emergency, "SLOPE_LIMIT", slopeLimit,
        "LAST_REASON", "none", "LAST_GRADE", -1).
    SET ctx["DIVERT_PENDING"] TO TRUE.
    mLogWarn("STATS landing-divert search height=" + ROUND(_landingBottomRadar(),0)
        + " hs=" + ROUND(ctx["H_SPEED"],1) + " emergency=" + emergency
        + " slopeLimit=" + slopeLimit + " radius=" + LANDING_DIVERT_SEARCH_RADIUS).
}

LOCAL FUNCTION _landingDivertCandidate {
    PARAMETER ctx.
    PARAMETER siteLat.
    PARAMETER siteLng.
    PARAMETER slopeLimit.

    LOCAL rejected IS LEXICON("OK", FALSE, "REASON", "reachability", "GRADE", -1).
    IF ABS(siteLat) > 90 { RETURN rejected. }
    LOCAL distance IS lmDistanceToTarget(siteLat, siteLng).
    LOCAL lateralAcc IS lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"]).
    LOCAL transitTime IS 2 * SQRT(MAX(0, distance) / MAX(0.01, lateralAcc))
        + ctx["H_SPEED"] / MAX(0.01, lateralAcc).
    IF transitTime > LANDING_APPROACH_MAX_TIME { RETURN rejected. }
    LOCAL elevation IS LATLNG(siteLat, siteLng):TERRAINHEIGHT.
    IF elevation + LANDING_BRAKE_CLEARANCE >= SHIP:ALTITUDE {
        SET rejected["REASON"] TO "altitude-clearance".
        RETURN rejected.
    }
    // A coarse-grid winner can hide a steep local patch. Validate every
    // candidate at the final 20 m scale, including emergency candidates.
    LOCAL grade IS landingTerrainGrade(siteLat, siteLng, 20).
    IF grade > TAN(slopeLimit) {
        SET rejected["REASON"] TO "terrain-grade".
        SET rejected["GRADE"] TO grade.
        RETURN rejected.
    }
    LOCAL arrivalUt IS TIME:SECONDS + MAX(1, lmTimeToImpact()).
    LOCAL light IS landingLightWindow(siteLat, siteLng, arrivalUt,
        LANDING_DIVERT_KERBIN_TOLERANCE, LANDING_DIVERT_REQUIRE_KERBIN).
    IF NOT light["OK"] {
        SET rejected["REASON"] TO light["REASON"].
        RETURN rejected.
    }
    RETURN LEXICON("OK", TRUE, "LAT", siteLat, "LNG", siteLng,
        "ELEVATION", elevation, "GRADE", grade,
        "SUN", light["SUN"], "KERBIN", light["KERBIN"]).
}

GLOBAL FUNCTION landingReviewReachableSite {
    PARAMETER ctx.
    IF LANDING_FLEXIBLE_SITE <= 0 OR NOT ctx["HAS_TARGET"] { RETURN TRUE. }
    IF ctx["H_SPEED"] > APPROACH_HSPEED { RETURN TRUE. }
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
    IF search["EXHAUSTED"] { RETURN TRUE. }
    LOCAL stepM IS MAX(20, LANDING_DIVERT_SEARCH_STEP).
    LOCAL radiusM IS MAX(0, LANDING_DIVERT_SEARCH_RADIUS).
    LOCAL ring IS 0.
    UNTIL search["INDEX"] < (2 * ring + 1) ^ 2 { SET ring TO ring + 1. }
    IF ring * stepM > radiusM
            OR TIME:SECONDS - search["STARTED"] >= MAX(1, LANDING_DIVERT_SEARCH_TIME) {
        IF NOT search["EMERGENCY"]
                AND MIN(15, LANDING_DIVERT_EMERGENCY_SLOPE) > search["SLOPE_LIMIT"] {
            _landingDivertStart(ctx, TRUE).
        } ELSE {
            SET search["EXHAUSTED"] TO TRUE.
            mLogError("STATS landing-divert unavailable reason=" + search["LAST_REASON"]
                + " grade=" + ROUND(search["LAST_GRADE"],3)
                + " samples=" + search["INDEX"] + " height=" + ROUND(_landingBottomRadar(),0)
                + ". No site accepted; powered braking retained. Manual intervention needed.").
        }
        RETURN TRUE.
    }

    // Square spiral: nearest rings first, one candidate per invocation.
    // Prefer the original site if it is still safe and reachable.
    LOCAL siteLat IS ctx["TARGET_LAT"].
    LOCAL siteLng IS ctx["TARGET_LNG"].
    IF search["INDEX"] >= 0 {
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
    IF NOT site["OK"] {
        SET search["LAST_REASON"] TO site["REASON"].
        SET search["LAST_GRADE"] TO site["GRADE"].
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
