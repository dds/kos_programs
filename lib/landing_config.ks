// Shared landing config and target helpers.

GLOBAL LAND_CFG IS LEXICON(
    "TOUCHDOWN_SPEED", 2.0,
    "HOVER_ALT", 100,
    "UPRIGHT_ALT", 10,
    "BURN_MARGIN", 1.05,
    "MAX_TILT", 15,
    "TARGET_LAT", 0,
    "TARGET_LNG", 0,
    "TARGET_WAYPOINT", "",
    "TARGET_LOCK", FALSE,
    "TARGET_TOLERANCE", 2500,
    "DEORBIT_PE", -3000,
    "DEORBIT_OVERSHOOT", 0,
    "DEORBIT_OVERSHOOT_TOLERANCE", 1200,
    "GUIDANCE_ALT", 5000,
    "GUIDANCE_CORRECTION_THRESHOLD", 500,
    "TR_BRAKE_WINDOW", 250,
    "TR_BRAKE_BIAS", 0.35,
    "CROSS_PID_KP", 0.01,
    "CROSS_PID_KI", 0.001,
    "CROSS_PID_KD", 0.005,
    "CROSS_PID_MIN", -15,
    "CROSS_PID_MAX", 15,
    "TERMINAL_HSPEED", 15,
    "TERMINAL_ALT", 1000,
    "BRAKE_ACCEL_FRACTION", 0.60,
    "BRAKE_MARGIN", 500,
    "APPROACH_RADIUS", 750,
    "VERTICAL_RADIUS", 60,
    "APPROACH_HSPEED", 25,
    "VERTICAL_HSPEED", 5,
    "MAX_APPROACH_SPEED", 35,
    "TERRAIN_CHECK_RADIUS", 500,
    "TERRAIN_CHECK_STEP", 100
).

GLOBAL LANDING_CFG IS LAND_CFG.

GLOBAL FUNCTION landingApplyMissionConfig {
    IF DEFINED CFG {
        FOR cfgKey IN CFG:KEYS {
            IF LAND_CFG:HASKEY(cfgKey) {
                SET LAND_CFG[cfgKey] TO CFG[cfgKey].
            }
        }
    }
}

GLOBAL FUNCTION landingResolveTarget {
    LOCAL result IS LEXICON("FOUND", FALSE, "LAT", 0, "LNG", 0, "SOURCE", "none").

    IF LAND_CFG["TARGET_WAYPOINT"] <> "" {
        LOCAL namedWp IS waypointNamed(LAND_CFG["TARGET_WAYPOINT"]).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Landing waypoint '" + LAND_CFG["TARGET_WAYPOINT"]
            + "' not found on " + SHIP:BODY:NAME + ".").
    }

    IF LAND_CFG["TARGET_LOCK"]
            AND (LAND_CFG["TARGET_LAT"] <> 0 OR LAND_CFG["TARGET_LNG"] <> 0) {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LAND_CFG["TARGET_LAT"].
        SET result["LNG"] TO LAND_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "locked LAND_CFG".
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

    IF LAND_CFG["TARGET_LAT"] <> 0 OR LAND_CFG["TARGET_LNG"] <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LAND_CFG["TARGET_LAT"].
        SET result["LNG"] TO LAND_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "LAND_CFG".
        RETURN result.
    }

    RETURN result.
}

GLOBAL FUNCTION landingImpactWithinTolerance {
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN TRUE. }
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN FALSE. }
    IF NOT ADDONS:TR:AVAILABLE { RETURN FALSE. }
    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT { RETURN FALSE. }
    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS geoDistance(impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL ok IS dist <= LAND_CFG["TARGET_TOLERANCE"].
    RETURN ok.
}

GLOBAL FUNCTION landingImpactAcceptableForAssist {
    IF LAND_CFG["DEORBIT_OVERSHOOT"] <= 0 { RETURN landingImpactWithinTolerance(). }
    IF NOT ADDONS:TR:AVAILABLE { RETURN FALSE. }
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN FALSE. }
    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT { RETURN FALSE. }
    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS geoDistance(impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL maxDist IS LAND_CFG["DEORBIT_OVERSHOOT"]
        + LAND_CFG["DEORBIT_OVERSHOOT_TOLERANCE"].
    LOCAL ok IS dist <= maxDist.
    RETURN ok.
}
