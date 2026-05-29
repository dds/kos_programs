// ============================================================
// rover.ks  —  Rover co-pilot library  (0:/lib/rover.ks)
// ============================================================

GLOBAL ROVER_CFG IS LEXICON(
    "MAX_SPEED_KERBIN",  20,
    "MAX_SPEED_MUN",      8,
    "MAX_SPEED_MINMUS",   5,
    "MAX_SPEED_DEFAULT",  8,
    "MAX_SLOPE_DEG",     25,
    "MAX_ROLL_DEG",      30,
    "FLIP_ROLL_DEG",     55,
    "HUD_INTERVAL",       1,
    "WAYPOINT_WARN_DIST", 50
).

GLOBAL roverActive     IS FALSE.
GLOBAL roverWaypointLat IS 0.
GLOBAL roverWaypointLng IS 0.
GLOBAL roverWaypointSet IS FALSE.
GLOBAL roverGovernorOn  IS TRUE.
GLOBAL roverSafetyOn    IS TRUE.

GLOBAL FUNCTION roverInit {
    SET roverActive TO TRUE.
    mLog("Rover co-pilot active. Body=" + SHIP:ORBIT:BODY:NAME
        + "  maxSpeed=" + _roverMaxSpeed() + "m/s"
        + "  maxSlope=" + ROVER_CFG["MAX_SLOPE_DEG"] + "deg").
    HUDTEXT("Rover co-pilot ACTIVE", 3, 2, 14, GREEN, FALSE).

    WHEN roverActive AND ABS(SHIP:FACING:ROLL) > ROVER_CFG["FLIP_ROLL_DEG"] THEN {
        HUDTEXT("FLIP WARNING — BRAKE!", 3, 2, 16, RED, FALSE).
        mLog("FLIP WARNING roll=" + ROUND(SHIP:FACING:ROLL,1) + "deg — braking.").
        SET SHIP:CONTROL:WHEELTHROTTLE TO 0.
        SET SHIP:CONTROL:WHEELSTEER TO 0.
        PRESERVE.
    }

    WHEN roverActive AND roverGovernorOn
            AND SHIP:VELOCITY:SURFACE:MAG > _roverMaxSpeed() THEN {
        SET SHIP:CONTROL:WHEELTHROTTLE TO 0.
        PRESERVE.
    }
}

GLOBAL FUNCTION roverShutdown {
    SET roverActive TO FALSE.
    HUDTEXT("Rover co-pilot OFF", 3, 2, 14, YELLOW, FALSE).
    mLog("Rover co-pilot deactivated.").
}

GLOBAL FUNCTION roverSetWaypoint {
    PARAMETER lat.
    PARAMETER lng.
    SET roverWaypointLat TO lat.
    SET roverWaypointLng TO lng.
    SET roverWaypointSet TO TRUE.
    mLog("Waypoint set: " + ROUND(lat,4) + ", " + ROUND(lng,4)).
    HUDTEXT("Waypoint set", 2, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION roverClearWaypoint {
    SET roverWaypointSet TO FALSE.
    mLog("Waypoint cleared.").
}

GLOBAL FUNCTION roverHUD {
    UNTIL NOT roverActive {
        LOCAL spd   IS ROUND(SHIP:VELOCITY:SURFACE:MAG, 1).
        LOCAL slope IS ROUND(_roverSlope(), 1).
        LOCAL roll  IS ROUND(SHIP:FACING:ROLL, 1).
        LOCAL hdg   IS ROUND(SHIP:FACING:YAW, 1).
        LOCAL bat   IS ROUND(_roverBattery(), 0).

        LOCAL hudLine IS "SPD:" + spd + "m/s  SLP:" + slope
            + "deg  ROL:" + roll + "deg  HDG:" + hdg
            + "deg  BAT:" + bat + "%".

        IF roverWaypointSet {
            LOCAL dist IS ROUND(_roverWaypointDist(), 0).
            LOCAL bear IS ROUND(_roverWaypointBearing(), 0).
            SET hudLine TO hudLine + "  WPT:" + dist + "m@" + bear + "deg".
            IF dist < ROVER_CFG["WAYPOINT_WARN_DIST"] {
                HUDTEXT("Waypoint reached!", 3, 2, 15, GREEN, FALSE).
                mLog("Waypoint reached. dist=" + dist + "m").
                roverClearWaypoint().
            }
        }

        IF slope > ROVER_CFG["MAX_SLOPE_DEG"] {
            HUDTEXT("SLOPE WARNING: " + slope + "deg", 2, 2, 15, YELLOW, FALSE).
        }

        PRINT hudLine AT (0, 0).
        WAIT ROVER_CFG["HUD_INTERVAL"].
    }
}

GLOBAL FUNCTION roverStatus {
    mLog("Rover status:"
        + " spd=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1) + "m/s"
        + " slope=" + ROUND(_roverSlope(),1) + "deg"
        + " roll=" + ROUND(SHIP:FACING:ROLL,1) + "deg"
        + " hdg=" + ROUND(SHIP:FACING:YAW,1) + "deg"
        + " bat=" + ROUND(_roverBattery(),0) + "%"
        + " body=" + SHIP:ORBIT:BODY:NAME).
}

LOCAL FUNCTION _roverMaxSpeed {
    LOCAL body IS SHIP:ORBIT:BODY:NAME:TOUPPER.
    IF body = "KERBIN" { RETURN ROVER_CFG["MAX_SPEED_KERBIN"]. }
    IF body = "MUN"    { RETURN ROVER_CFG["MAX_SPEED_MUN"].    }
    IF body = "MINMUS" { RETURN ROVER_CFG["MAX_SPEED_MINMUS"]. }
    RETURN ROVER_CFG["MAX_SPEED_DEFAULT"].
}

LOCAL FUNCTION _roverSlope {
    RETURN VANG(SHIP:FACING:UPVECTOR, SHIP:UP:VECTOR).
}

LOCAL FUNCTION _roverBattery {
    LOCAL stored IS 0.
    LOCAL cap    IS 0.
    FOR r IN SHIP:RESOURCES {
        IF r:NAME = "ElectricCharge" {
            SET stored TO r:AMOUNT.
            SET cap    TO r:CAPACITY.
        }
    }
    IF cap = 0 { RETURN 0. }
    RETURN (stored / cap) * 100.
}

LOCAL FUNCTION _roverWaypointDist {
    LOCAL wp IS LATLNG(roverWaypointLat, roverWaypointLng).
    RETURN wp:DISTANCE.
}

LOCAL FUNCTION _roverWaypointBearing {
    LOCAL wp IS LATLNG(roverWaypointLat, roverWaypointLng).
    RETURN SHIP:BEARING(wp).
}
