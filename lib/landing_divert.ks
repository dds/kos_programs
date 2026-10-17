// ============================================================
// landing_divert.ks - Bounded site changes for flexible economy landings.
// (0:/lib/landing_divert.ks)
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingReviewReachableSite {
    PARAMETER ctx.
    PARAMETER initial IS FALSE.
    IF LANDING_FLEXIBLE_SITE <= 0 OR NOT ctx["HAS_TARGET"] { RETURN TRUE. }

    LOCAL impact IS _landingTrajImpactInfo(ctx).
    IF initial {
        // The normal deorbit deliberately leaves a 10-20 km phantom lead.
        // Do not confuse that with an unreachable, unrelated old target.
        IF NOT impact["FOUND"] OR impact["DIST"] <= LANDING_ASSIST_IMPACT_LIMIT {
            RETURN TRUE.
        }
    } ELSE {
        IF ctx["H_SPEED"] > APPROACH_HSPEED { RETURN TRUE. }
        LOCAL dist IS lmDistanceToTarget(ctx["TARGET_LAT"], ctx["TARGET_LNG"]).
        IF _landingBottomRadar() > TERMINAL_ALT
                AND dist <= LANDING_ASSIST_IMPACT_LIMIT { RETURN TRUE. }
        LOCAL lateralAcc IS lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"]).
        LOCAL transitTime IS 2 * SQRT(MAX(0, dist) / MAX(0.01, lateralAcc))
            + ctx["H_SPEED"] / MAX(0.01, lateralAcc).
        IF transitTime <= LANDING_APPROACH_MAX_TIME { RETURN TRUE. }
    }

    // Stop publishing thrust before synchronous terrain/light queries.
    _landingSetThrottle(ctx, 0).
    IF NOT thrustCutoffOk(FALSE) { RETURN FALSE. }
    LOCK THROTTLE TO ctx["TARGET_THROTTLE"].
    // Refresh after physical cutoff: the former prediction may have been
    // sampled while thrust/attitude were still changing.
    SET impact TO _landingTrajImpactInfo(ctx).
    IF NOT impact["FOUND"] OR NOT ADDONS:TR:ISVERTWOTWO {
        mLogError("Economy site unreachable; no timed ballistic impact for a safe diversion.").
        RETURN FALSE.
    }
    LOCAL impactUT IS TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT.
    IF impactUT <= TIME:SECONDS {
        mLogError("Economy diversion refused: impact timing is not in the future.").
        RETURN FALSE.
    }
    LOCAL site IS _landingTerrainCheck(impact["LAT"], impact["LNG"], FALSE).
    LOCAL originalRadius IS TERRAIN_CHECK_RADIUS.
    SET TERRAIN_CHECK_RADIUS TO 20.
    SET site TO _landingTerrainCheck(site["LAT"], site["LNG"], FALSE).
    SET TERRAIN_CHECK_RADIUS TO originalRadius.
    IF impactUT <= TIME:SECONDS
            OR site["ELEVATION"] + LANDING_BRAKE_CLEARANCE >= SHIP:ALTITUDE {
        mLogError("Economy diversion refused: no remaining timing/altitude clearance for the candidate.").
        RETURN FALSE.
    }
    LOCAL grade IS landingTerrainGrade(site["LAT"], site["LNG"], 20).
    LOCAL light IS landingLightWindow(site["LAT"], site["LNG"], impactUT,
        LANDING_DIVERT_KERBIN_TOLERANCE).
    IF grade > TAN(LANDING_TERRAIN_MAX_SLOPE) OR NOT light["OK"] {
        mLogError("Economy diversion rejected: terrain grade=" + ROUND(grade,3)
            + " light/radio=" + light["REASON"]
            + " kerbin=" + ROUND(light["KERBIN"],2)
            + " min=" + MAX(0, LANDING_KERBIN_MIN_ELEV - LANDING_DIVERT_KERBIN_TOLERANCE)
            + ". Original target retained.").
        RETURN FALSE.
    }
    IF NOT initial AND _landingBottomRadar() <= TERMINAL_ALT {
        LOCAL siteDistance IS lmDistanceToTarget(site["LAT"], site["LNG"]).
        LOCAL siteAcc IS lmApproachAcceleration(ctx["MAX_ACC"], ctx["GRAV"]).
        LOCAL siteTime IS 2 * SQRT(MAX(0, siteDistance) / MAX(0.01, siteAcc))
            + ctx["H_SPEED"] / MAX(0.01, siteAcc).
        IF siteTime > LANDING_APPROACH_MAX_TIME {
            mLogError("Economy diversion remains outside the approach time budget; original target retained.").
            RETURN FALSE.
        }
    }

    LOCAL shift IS geoDistance(ctx["TARGET_LAT"], ctx["TARGET_LNG"], site["LAT"], site["LNG"]).
    SET ctx["TARGET_LAT"] TO site["LAT"].
    SET ctx["TARGET_LNG"] TO site["LNG"].
    SET ctx["TARGET_ELEVATION"] TO site["ELEVATION"].
    SET ctx["TERRAIN_DONE"] TO TRUE.
    SET ctx["HOVER_TERRAIN_DONE"] TO TRUE.
    SET TARGET_LAT TO site["LAT"].
    SET TARGET_LNG TO site["LNG"].
    SET TARGET_LOCK TO 1.
    SET TARGET_WAYPOINT TO "".
    missionOverrideUpdate(LEXICON("TARGET_LAT", TARGET_LAT, "TARGET_LNG", TARGET_LNG,
        "TARGET_LOCK", TARGET_LOCK, "TARGET_WAYPOINT", TARGET_WAYPOINT)).
    ADDONS:TR:SETTARGET(LATLNG(TARGET_LAT, TARGET_LNG)).
    mLogWarn("STATS landing-divert shift=" + ROUND(shift,0)
        + "m lat=" + TARGET_LAT + " lng=" + TARGET_LNG
        + " grade=" + ROUND(grade,3) + " sun=" + ROUND(light["SUN"],1)
        + " kerbin=" + ROUND(light["KERBIN"],1)).
    // Terrain queries and cutoff take time. Do not run this tick's guidance
    // with the old velocity, acceleration or position cache.
    _landingCacheTick(ctx).
    RETURN TRUE.
}
