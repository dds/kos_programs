// --- Config defaults owned by this file ---
GLOBAL TARGET_LAT IS 0.
GLOBAL TARGET_LNG IS 0.
GLOBAL TARGET_LOCK IS 0.
GLOBAL TARGET_WAYPOINT IS "".
GLOBAL LANDING_ASSIST_IMPACT_LIMIT IS 20000.
GLOBAL TOUCHDOWN_SPEED IS 2.
GLOBAL HOVER_ALT IS 100.
GLOBAL UPRIGHT_ALT IS 10.
GLOBAL BURN_MARGIN IS 1.05.
GLOBAL TR_BRAKE_WINDOW IS 250.
GLOBAL TR_BRAKE_BIAS IS 0.35.
GLOBAL CROSS_PID_KP IS 0.01.
GLOBAL CROSS_PID_KI IS 0.001.
GLOBAL CROSS_PID_KD IS 0.005.
GLOBAL CROSS_PID_MIN IS -15.
GLOBAL CROSS_PID_MAX IS 15.
GLOBAL TERMINAL_HSPEED IS 15.
GLOBAL TERMINAL_ALT IS 1000.
GLOBAL BRAKE_ACCEL_FRACTION IS 0.9.
GLOBAL BRAKE_MARGIN IS 500.
GLOBAL APPROACH_RADIUS IS 750.
GLOBAL VERTICAL_RADIUS IS 60.
GLOBAL APPROACH_HSPEED IS 25.
GLOBAL VERTICAL_HSPEED IS 5.
GLOBAL MAX_APPROACH_SPEED IS 35.
GLOBAL TERRAIN_VALIDATE IS TRUE.
GLOBAL TERRAIN_SAFE_ALT IS 6500.
GLOBAL TERRAIN_MIN_CLEARANCE IS 100.
GLOBAL TERRAIN_MAX_CRASH_DIST IS 500.
GLOBAL TERRAIN_MIN_DESCENT_ANGLE IS 40.
GLOBAL TERRAIN_CHECK_RADIUS IS 0.
GLOBAL TERRAIN_CHECK_STEP IS 0.
GLOBAL MAX_TILT IS 15.
GLOBAL GUIDANCE_ALT IS 5000.
GLOBAL GUIDANCE_CORRECTION_THRESHOLD IS 500.

// Shared landing config and target helpers.

GLOBAL FUNCTION landingApplyMissionConfig {
    // Mission config is already applied directly to the globals above.
    RETURN TRUE.
}

GLOBAL FUNCTION landingResolveTarget {
    LOCAL result IS LEXICON("FOUND", FALSE, "LAT", 0, "LNG", 0, "SOURCE", "none").

    IF TARGET_WAYPOINT <> "" {
        LOCAL namedWp IS waypointNamed(TARGET_WAYPOINT).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Landing waypoint '" + TARGET_WAYPOINT
            + "' not found on " + SHIP:BODY:NAME + ".").
    }

    IF TARGET_LOCK
            AND (TARGET_LAT <> 0 OR TARGET_LNG <> 0) {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO TARGET_LAT.
        SET result["LNG"] TO TARGET_LNG.
        SET result["SOURCE"] TO "locked config".
        RETURN result.
    }

    LOCAL selectedWp IS selectedWaypoint().
    IF selectedWp <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO selectedWp:GEOPOSITION:LAT.
        SET result["LNG"] TO selectedWp:GEOPOSITION:LNG.
        SET result["SOURCE"] TO "selected waypoint:" + selectedWp:NAME.
        RETURN result.
    }

    IF TARGET_LAT <> 0 OR TARGET_LNG <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO TARGET_LAT.
        SET result["LNG"] TO TARGET_LNG.
        SET result["SOURCE"] TO "config".
        RETURN result.
    }

    RETURN result.
}

LOCAL FUNCTION _getImpactDistance {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN 999999. }
    IF NOT ADDONS:TR:AVAILABLE { RETURN 999999. }
    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT { RETURN 999999. }
    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    RETURN geoDistance(impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
}

GLOBAL FUNCTION landingFlyoverPe {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN 0. }
    RETURN LATLNG(landingTarget["LAT"], landingTarget["LNG"]):TERRAINHEIGHT.
}

GLOBAL FUNCTION landingFlyoverDistance {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN 999999. }
    LOCAL flyUt IS TIME:SECONDS + ETA:PERIAPSIS.
    LOCAL geo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, flyUt)).
    RETURN geoDistance(geo:LAT, geo:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
}

GLOBAL FUNCTION landingImpactWithinTolerance {
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN TRUE. }
    RETURN _getImpactDistance() <= TARGET_TOLERANCE.
}

GLOBAL FUNCTION landingImpactAcceptableForAssist {
    IF _getImpactDistance() <= LANDING_ASSIST_IMPACT_LIMIT { RETURN TRUE. }
    IF SHIP:PERIAPSIS > landingFlyoverPe() + 500 { RETURN FALSE. }
    RETURN landingFlyoverDistance() <= LANDING_ASSIST_IMPACT_LIMIT.
}
