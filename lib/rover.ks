// ============================================================
// rover.ks  —  Rover co-pilot library  (0:/lib/rover.ks)
// ============================================================

GLOBAL ROVER_CFG IS LEXICON(
    "MAX_SPEED_KERBIN",    20,
    "MAX_SPEED_MUN",        8,
    "MAX_SPEED_MINMUS",     5,
    "MAX_SPEED_DEFAULT",    8,
    "MAX_SLOPE_DEG",       25,
    "SLOPE_SPEED_FACTOR",   0.5,
    "MAX_ROLL_DEG",        30,
    "FLIP_ROLL_DEG",       55,
    "STEER_REF_SPEED",      5,
    "STEER_MIN_FACTOR",     0.2,
    "STEER_KP",             0.08,
    "STEER_KI",             0.002,
    "STEER_KD",             0.02,
    "GOV_RELEASE_PCT",      0.9,
    "AUTO_THROTTLE",        0.5,
    "TRACTION_SLOPE_DEG",  15,
    "TRACTION_TAG",        "front_motor",
    "TRACTION_AG",          0,
    "HUD_INTERVAL",         1,
    "WAYPOINT_WARN_DIST",  50
).

GLOBAL roverActive          IS FALSE.
GLOBAL roverAutoSteerActive IS FALSE.
GLOBAL roverWptList         IS LIST().
GLOBAL roverWptIndex        IS 0.
GLOBAL roverGovernorOn      IS TRUE.
LOCAL  roverBraking         IS FALSE.
LOCAL  roverTractionOn      IS FALSE.
LOCAL  _steerPid            IS 0.
LOCAL  _tractionParts       IS LIST().

GLOBAL FUNCTION roverInit {
    mLog("Rover co-pilot active. Body=" + SHIP:ORBIT:BODY:NAME
        + "  maxSpeed=" + _roverMaxSpeed() + "m/s"
        + "  maxSlope=" + ROVER_CFG["MAX_SLOPE_DEG"] + "deg").

    SET _steerPid TO PIDLOOP(ROVER_CFG["STEER_KP"], ROVER_CFG["STEER_KI"],
        ROVER_CFG["STEER_KD"], -1, 1).

    SET _tractionParts TO SHIP:PARTSTAGGED(ROVER_CFG["TRACTION_TAG"]).
    IF _tractionParts:LENGTH > 0 {
        mLog("Traction parts: " + _tractionParts:LENGTH + " tagged '"
            + ROVER_CFG["TRACTION_TAG"] + "'.").
    } ELSE IF ROVER_CFG["TRACTION_AG"] > 0 {
        mLog("Traction assist: AG" + ROVER_CFG["TRACTION_AG"] + ".").
    }

    WHEN roverActive AND ABS(SHIP:FACING:ROLL) > ROVER_CFG["FLIP_ROLL_DEG"] THEN {
        HUDTEXT("FLIP WARNING — BRAKE!", 3, 2, 16, RED, FALSE).
        mLog("FLIP WARNING roll=" + ROUND(SHIP:FACING:ROLL,1) + "deg.").
        SET SHIP:CONTROL:WHEELTHROTTLE TO 0.
        SET SHIP:CONTROL:WHEELSTEER TO 0.
        PRESERVE.
    }

    WHEN roverActive AND roverGovernorOn THEN {
        LOCAL spd IS SHIP:VELOCITY:SURFACE:MAG.
        LOCAL slope IS _roverSlope().
        IF slope > ROVER_CFG["TRACTION_SLOPE_DEG"] {
            _roverTractionOn().
        } ELSE {
            _roverTractionOff().
        }
        LOCAL maxSpd IS _roverEffectiveMaxSpeed().
        IF roverBraking {
            IF spd < maxSpd * ROVER_CFG["GOV_RELEASE_PCT"] {
                SET roverBraking TO FALSE.
                SET BRAKES TO FALSE.
            }
        } ELSE {
            IF spd > maxSpd {
                SET roverBraking TO TRUE.
                SET BRAKES TO TRUE.
                SET SHIP:CONTROL:WHEELTHROTTLE TO 0.
            }
        }
        PRESERVE.
    }

    WHEN roverActive THEN {
        IF roverAutoSteerActive AND roverWptIndex < roverWptList:LENGTH {
            LOCAL wp IS roverWptList[roverWptIndex].
            LOCAL geo IS LATLNG(wp["lat"], wp["lng"]).
            IF geo:DISTANCE < ROVER_CFG["WAYPOINT_WARN_DIST"] {
                SET roverWptIndex TO roverWptIndex + 1.
                IF roverWptIndex >= roverWptList:LENGTH {
                    mLog("Final waypoint reached.").
                    HUDTEXT("Final waypoint reached", 3, 2, 15, GREEN, FALSE).
                    roverAutoSteerOff().
                } ELSE {
                    mLog("Waypoint " + roverWptIndex + "/" + roverWptList:LENGTH + " reached.").
                    HUDTEXT("WPT " + roverWptIndex + "/" + roverWptList:LENGTH,
                        2, 2, 13, CYAN, FALSE).
                }
            }
            IF roverAutoSteerActive AND roverWptIndex < roverWptList:LENGTH {
                SET wp TO roverWptList[roverWptIndex].
                LOCAL tgtBrng IS LATLNG(wp["lat"], wp["lng"]):HEADING.
                LOCAL hdgErr IS tgtBrng - SHIP:FACING:YAW.
                IF hdgErr > 180  { SET hdgErr TO hdgErr - 360. }
                IF hdgErr < -180 { SET hdgErr TO hdgErr + 360. }
                LOCAL steerOut IS _steerPid:UPDATE(TIME:SECONDS, -hdgErr).
                SET SHIP:CONTROL:WHEELSTEER TO MAX(-1, MIN(1, steerOut * _roverSteerFactor())).
                IF NOT roverBraking AND ABS(SHIP:FACING:ROLL) < ROVER_CFG["FLIP_ROLL_DEG"] {
                    SET SHIP:CONTROL:WHEELTHROTTLE TO ROVER_CFG["AUTO_THROTTLE"].
                }
            }
        } ELSE {
            SET SHIP:CONTROL:WHEELSTEER TO SHIP:CONTROL:PILOTWHEELSTEER * _roverSteerFactor().
        }
        PRESERVE.
    }

    SET roverActive TO TRUE.
    HUDTEXT("Rover co-pilot ACTIVE", 3, 2, 14, GREEN, FALSE).
}

GLOBAL FUNCTION roverShutdown {
    SET roverAutoSteerActive TO FALSE.
    _roverTractionOff().
    SET roverActive TO FALSE.
    HUDTEXT("Rover co-pilot OFF", 3, 2, 14, YELLOW, FALSE).
    mLog("Rover co-pilot deactivated.").
}

GLOBAL FUNCTION roverAddWaypoint {
    PARAMETER lat_.
    PARAMETER lng_.
    roverWptList:ADD(LEXICON("lat", lat_, "lng", lng_)).
    mLog("Waypoint added: " + ROUND(lat_,4) + "," + ROUND(lng_,4)
        + " (total " + roverWptList:LENGTH + ").").
    HUDTEXT("Waypoint added (" + roverWptList:LENGTH + ")", 2, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION roverSetWaypoints {
    PARAMETER wpList.
    SET roverWptList TO wpList.
    SET roverWptIndex TO 0.
    mLog("Loaded " + roverWptList:LENGTH + " waypoints.").
}

GLOBAL FUNCTION roverClearWaypoints {
    SET roverAutoSteerActive TO FALSE.
    SET roverWptList TO LIST().
    SET roverWptIndex TO 0.
    mLog("Waypoints cleared.").
}

GLOBAL FUNCTION roverSetWaypoint {
    PARAMETER lat_.
    PARAMETER lng_.
    roverClearWaypoints().
    roverAddWaypoint(lat_, lng_).
}

GLOBAL FUNCTION roverAutoSteerOn {
    IF roverWptList:LENGTH = 0 {
        mLog("No waypoints loaded.").
        HUDTEXT("No waypoints!", 3, 2, 14, RED, FALSE).
        RETURN.
    }
    SET roverWptIndex TO 0.
    _steerPid:RESET().
    SET roverAutoSteerActive TO TRUE.
    mLog("Auto-steer ON: " + roverWptList:LENGTH + " waypoints.").
    HUDTEXT("Auto-steer ON (" + roverWptList:LENGTH + " wpts)", 3, 2, 14, GREEN, FALSE).
}

GLOBAL FUNCTION roverAutoSteerOff {
    SET roverAutoSteerActive TO FALSE.
    SET SHIP:CONTROL:WHEELTHROTTLE TO 0.
    mLog("Auto-steer OFF.").
    HUDTEXT("Auto-steer OFF", 2, 2, 13, YELLOW, FALSE).
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

        IF roverAutoSteerActive AND roverWptIndex < roverWptList:LENGTH {
            LOCAL wp IS roverWptList[roverWptIndex].
            LOCAL geo IS LATLNG(wp["lat"], wp["lng"]).
            LOCAL dist IS ROUND(geo:DISTANCE, 0).
            LOCAL bear IS ROUND(geo:HEADING, 0).
            SET hudLine TO hudLine + "  WPT:" + (roverWptIndex+1) + "/"
                + roverWptList:LENGTH + " " + dist + "m@" + bear + "deg".
        }

        IF roverTractionOn { SET hudLine TO hudLine + "  TRXN". }

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
        + " autoSteer=" + roverAutoSteerActive
        + " traction=" + roverTractionOn
        + " wpt=" + roverWptIndex + "/" + roverWptList:LENGTH
        + " body=" + SHIP:ORBIT:BODY:NAME).
}

LOCAL FUNCTION _roverMaxSpeed {
    LOCAL bodyName IS SHIP:ORBIT:BODY:NAME.
    IF bodyName = "KERBIN" { RETURN ROVER_CFG["MAX_SPEED_KERBIN"]. }
    IF bodyName = "MUN"    { RETURN ROVER_CFG["MAX_SPEED_MUN"].    }
    IF bodyName = "MINMUS" { RETURN ROVER_CFG["MAX_SPEED_MINMUS"]. }
    RETURN ROVER_CFG["MAX_SPEED_DEFAULT"].
}

LOCAL FUNCTION _roverEffectiveMaxSpeed {
    LOCAL base IS _roverMaxSpeed().
    LOCAL slope IS _roverSlope().
    LOCAL roll IS ABS(SHIP:FACING:ROLL).

    LOCAL slopeFactor IS MAX(ROVER_CFG["SLOPE_SPEED_FACTOR"],
        1.0 - (slope / ROVER_CFG["MAX_SLOPE_DEG"])
            * (1.0 - ROVER_CFG["SLOPE_SPEED_FACTOR"])).

    LOCAL rollFactor IS 1.0.
    IF roll > ROVER_CFG["MAX_ROLL_DEG"] {
        LOCAL rollRange IS ROVER_CFG["FLIP_ROLL_DEG"] - ROVER_CFG["MAX_ROLL_DEG"].
        SET rollFactor TO MAX(0.3,
            1.0 - (roll - ROVER_CFG["MAX_ROLL_DEG"]) / rollRange * 0.7).
    }

    RETURN base * slopeFactor * rollFactor.
}

LOCAL FUNCTION _roverSteerFactor {
    LOCAL spd IS SHIP:VELOCITY:SURFACE:MAG.
    LOCAL ref IS ROVER_CFG["STEER_REF_SPEED"].
    LOCAL minF IS ROVER_CFG["STEER_MIN_FACTOR"].
    RETURN MAX(minF, MIN(1.0, ref / MAX(spd, 0.1))).
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

LOCAL FUNCTION _roverTractionOn {
    IF roverTractionOn { RETURN. }
    SET roverTractionOn TO TRUE.
    IF ROVER_CFG["TRACTION_AG"] > 0 {
        _roverSetAG(ROVER_CFG["TRACTION_AG"], TRUE).
    } ELSE {
        FOR p IN _tractionParts {
            IF p:HASMODULE("ModuleWheelMotor") {
                p:GETMODULE("ModuleWheelMotor"):SETFIELD("Motor Enabled", TRUE).
            }
        }
    }
    mLog("Traction ON (slope=" + ROUND(_roverSlope(),1) + "deg).").
    HUDTEXT("Traction ON", 2, 2, 13, YELLOW, FALSE).
}

LOCAL FUNCTION _roverTractionOff {
    IF NOT roverTractionOn { RETURN. }
    SET roverTractionOn TO FALSE.
    IF ROVER_CFG["TRACTION_AG"] > 0 {
        _roverSetAG(ROVER_CFG["TRACTION_AG"], FALSE).
    } ELSE {
        FOR p IN _tractionParts {
            IF p:HASMODULE("ModuleWheelMotor") {
                p:GETMODULE("ModuleWheelMotor"):SETFIELD("Motor Enabled", FALSE).
            }
        }
    }
    mLog("Traction OFF.").
    HUDTEXT("Traction OFF", 2, 2, 13, CYAN, FALSE).
}

LOCAL FUNCTION _roverSetAG {
    PARAMETER agNum.
    PARAMETER state.
    IF state {
        IF      agNum = 1 { AG1 ON. }
        ELSE IF agNum = 2 { AG2 ON. }
        ELSE IF agNum = 3 { AG3 ON. }
        ELSE IF agNum = 4 { AG4 ON. }
        ELSE IF agNum = 5 { AG5 ON. }
    } ELSE {
        IF      agNum = 1 { AG1 OFF. }
        ELSE IF agNum = 2 { AG2 OFF. }
        ELSE IF agNum = 3 { AG3 OFF. }
        ELSE IF agNum = 4 { AG4 OFF. }
        ELSE IF agNum = 5 { AG5 OFF. }
    }
}
