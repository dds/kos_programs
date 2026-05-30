// ============================================================
// plane.ks  —  Aircraft autopilot library  (0:/lib/plane.ks)
// ============================================================

GLOBAL PLANE_CFG IS LEXICON(
    "ROLL_KP",           0.02,
    "ROLL_KI",           0.001,
    "ROLL_KD",           0.01,
    "ALT_KP",            0.003,
    "ALT_KI",            0.0005,
    "ALT_KD",            0.002,
    "ALT_MAX_PITCH",       8,
    "ALT_MIN_PITCH",      -6,
    "PITCH_KP",          0.05,
    "PITCH_KI",          0.005,
    "PITCH_KD",          0.02,
    "HDG_KP",            0.03,
    "HDG_KI",            0.002,
    "HDG_KD",            0.015,
    "SPD_KP",            0.01,
    "SPD_KI",            0.002,
    "SPD_KD",            0.005,
    "SPD_MIN_THROTTLE",  0.0,
    "SPD_MAX_THROTTLE",  1.0,
    "WPT_RADIUS",        500,
    "STALL_SPEED",        60,
    "STALL_AOA",          20,
    "AOA_LIMIT",          15,
    "SURVEY_ALT",       2000,
    "SURVEY_SPACING",    500,
    "SURVEY_SPEED",      150,
    "SURVEY_LANE_LENGTH", 10000,
    "FBW_REF_SPEED",     100,
    "FBW_MIN_AUTH",      0.15,
    "FBW_MAX_AUTH",      1.0,
    "BRAKE_REF_SPEED",    80,
    "BRAKE_STOP_SPEED",    3,
    "REVERSE_THRUST_DELAY", 1.5,
    "REVERSE_AG",          2,
    "STEER_MAX_SPEED",    30,
    "STEER_TAG",         "steering_gear",
    "SURFACE_CTRL",      FALSE
).

GLOBAL planeActive       IS FALSE.
GLOBAL wingLevelerActive IS FALSE.
GLOBAL altHoldActive     IS FALSE.
GLOBAL hdgHoldActive     IS FALSE.
GLOBAL spdHoldActive     IS FALSE.
GLOBAL targetAlt         IS 0.
GLOBAL targetHdg         IS 0.
GLOBAL targetSpd         IS 0.
GLOBAL apActive          IS FALSE.
GLOBAL wptNavActive      IS FALSE.
GLOBAL wptList           IS LIST().
GLOBAL wptIndex          IS 0.
LOCAL _ctrlSurfaces      IS LIST().
LOCAL _rollPid           IS 0.
LOCAL _altPid            IS 0.
LOCAL _pitchPid          IS 0.
LOCAL _hdgPid            IS 0.
LOCAL _spdPid            IS 0.

GLOBAL FUNCTION planeInit {
    SET planeActive TO TRUE.
    mLog("Plane autopilot ready. Modes: off. Stall speed="
        + PLANE_CFG["STALL_SPEED"] + "m/s").
    HUDTEXT("Plane autopilot ready", 3, 2, 13, GREEN, FALSE).

    WHEN planeActive AND ALT:RADAR > 2
            AND SHIP:AIRSPEED < PLANE_CFG["STALL_SPEED"]
            AND SHIP:ALTITUDE < 70000 THEN {
        HUDTEXT("STALL WARNING — " + ROUND(SHIP:AIRSPEED,0) + "m/s", 2, 2, 16, RED, FALSE).
        mLog("Stall warning: airspeed=" + ROUND(SHIP:AIRSPEED,0) + "m/s").
        PRESERVE.
    }

    mLog("Plane init: cruise=" + CFG["CRUISE_SPEED"] + " top=" + CFG["TOP_SPEED"] + "m/s").
    IF PLANE_CFG["SURFACE_CTRL"] {
        SET _ctrlSurfaces TO LIST().
        FOR p IN SHIP:PARTS {
            IF p:HASMODULE("ModuleControlSurface") {
                _ctrlSurfaces:ADD(p:GETMODULE("ModuleControlSurface")).
            }
        }
        mLog("Control surfaces: " + _ctrlSurfaces:LENGTH + " found.").
    }

    SET _rollPid  TO PIDLOOP(PLANE_CFG["ROLL_KP"],  PLANE_CFG["ROLL_KI"],
        PLANE_CFG["ROLL_KD"],  -1, 1).
    SET _altPid   TO PIDLOOP(PLANE_CFG["ALT_KP"],   PLANE_CFG["ALT_KI"],
        PLANE_CFG["ALT_KD"],   PLANE_CFG["ALT_MIN_PITCH"], PLANE_CFG["ALT_MAX_PITCH"]).
    SET _pitchPid TO PIDLOOP(PLANE_CFG["PITCH_KP"], PLANE_CFG["PITCH_KI"],
        PLANE_CFG["PITCH_KD"], -1, 1).
    SET _hdgPid   TO PIDLOOP(PLANE_CFG["HDG_KP"],   PLANE_CFG["HDG_KI"],
        PLANE_CFG["HDG_KD"],   -1, 1).
    SET _spdPid   TO PIDLOOP(PLANE_CFG["SPD_KP"],   PLANE_CFG["SPD_KI"],
        PLANE_CFG["SPD_KD"],
        PLANE_CFG["SPD_MIN_THROTTLE"], PLANE_CFG["SPD_MAX_THROTTLE"]).
    mLog("PID controllers initialized (roll/alt/pitch/hdg/spd).").

    LOCAL _prevAG7 IS AG7.
    LOCAL _prevAG8 IS AG8.
    WHEN planeActive THEN {
        IF AG7 <> _prevAG7 {
            SET _prevAG7 TO AG7.
            IF apActive { apOff(). } ELSE { apOn(). }
        }
        IF AG8 <> _prevAG8 {
            SET _prevAG8 TO AG8.
            IF wptNavActive { wptNavOff(). } ELSE { wptNavOn(). }
        }
        PRESERVE.
    }

    LOCAL steerParts IS SHIP:PARTSTAGGED(PLANE_CFG["STEER_TAG"]).
    IF steerParts:LENGTH > 0 {
        mLog("Nosewheel steering: " + steerParts:LENGTH + " part(s) tagged '"
            + PLANE_CFG["STEER_TAG"] + "'.").
        WHEN planeActive THEN {
            LOCAL spd IS SHIP:VELOCITY:SURFACE:MAG.
            LOCAL maxSteer IS PLANE_CFG["STEER_MAX_SPEED"].
            IF spd < maxSteer {
                LOCAL factor IS 1.0 - spd / maxSteer.
                SET SHIP:CONTROL:WHEELSTEER TO SHIP:CONTROL:PILOTWHEELSTEER * factor.
            } ELSE {
                SET SHIP:CONTROL:WHEELSTEER TO 0.
            }
            PRESERVE.
        }
    }
}

GLOBAL FUNCTION planeShutdown {
    SET apActive TO FALSE.
    SET wptNavActive TO FALSE.
    wingLevelerOff().
    altHoldOff().
    hdgHoldOff().
    spdHoldOff().
    IF PLANE_CFG["SURFACE_CTRL"] {
        FOR sm IN _ctrlSurfaces {
            sm:SETFIELD("Authority Limiter", 100).
        }
    }
    UNLOCK STEERING.
    SET planeActive TO FALSE.
    mLog("Plane autopilot shutdown.").
}

GLOBAL FUNCTION wingLevelerOn {
    _rollPid:RESET().
    SET _rollPid:SETPOINT TO 0.
    SET wingLevelerActive TO TRUE.
    mLog("Wing leveler ON.").
    HUDTEXT("Wing leveler ON", 2, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION wingLevelerOff {
    SET wingLevelerActive TO FALSE.
    SET SHIP:CONTROL:ROLL TO 0.
    mLog("Wing leveler OFF.").
    HUDTEXT("Wing leveler OFF", 2, 2, 13, YELLOW, FALSE).
}

GLOBAL FUNCTION altHoldOn {
    PARAMETER tAlt IS SHIP:ALTITUDE.
    SET targetAlt TO tAlt.
    _altPid:RESET().
    _pitchPid:RESET().
    SET altHoldActive TO TRUE.
    mLog("Altitude hold ON at " + ROUND(tAlt,0) + "m.").
    HUDTEXT("Alt hold ON: " + ROUND(tAlt,0) + "m", 2, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION altHoldOff {
    SET altHoldActive TO FALSE.
    SET SHIP:CONTROL:PITCH TO 0.
    mLog("Altitude hold OFF.").
    HUDTEXT("Alt hold OFF", 2, 2, 13, YELLOW, FALSE).
}

GLOBAL FUNCTION hdgHoldOn {
    PARAMETER hdg IS SHIP:FACING:YAW.
    SET targetHdg TO hdg.
    _hdgPid:RESET().
    SET hdgHoldActive TO TRUE.
    mLog("Heading hold ON at " + ROUND(hdg,0) + "deg.").
    HUDTEXT("Hdg hold ON: " + ROUND(hdg,0) + "deg", 2, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION hdgHoldOff {
    SET hdgHoldActive TO FALSE.
    SET SHIP:CONTROL:YAW TO 0.
    mLog("Heading hold OFF.").
    HUDTEXT("Hdg hold OFF", 2, 2, 13, YELLOW, FALSE).
}

GLOBAL FUNCTION spdHoldOn {
    PARAMETER tSpd IS SHIP:AIRSPEED.
    SET targetSpd TO tSpd.
    _spdPid:RESET().
    SET spdHoldActive TO TRUE.
    mLog("Speed hold ON at " + ROUND(tSpd,0) + "m/s.").
    HUDTEXT("Spd hold ON: " + ROUND(tSpd,0) + "m/s", 2, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION spdHoldOff {
    SET spdHoldActive TO FALSE.
    UNLOCK THROTTLE.
    mLog("Speed hold OFF.").
    HUDTEXT("Spd hold OFF", 2, 2, 13, YELLOW, FALSE).
}

LOCAL FUNCTION _fbwAuthority {
    RETURN MAX(PLANE_CFG["FBW_MIN_AUTH"],
           MIN(PLANE_CFG["FBW_MAX_AUTH"],
               PLANE_CFG["FBW_REF_SPEED"] / MAX(SHIP:AIRSPEED, 1))).
}

LOCAL FUNCTION _surfaceAuthority {
    LOCAL topSpd    IS CFG["TOP_SPEED"].
    LOCAL cruiseSpd IS CFG["CRUISE_SPEED"].
    LOCAL minAuth   IS 0.5.
    IF topSpd > 700      { SET minAuth TO 0.2. }
    ELSE IF topSpd > 400 { SET minAuth TO 0.3. }
    LOCAL spd IS SHIP:AIRSPEED.
    IF spd <= cruiseSpd { RETURN 1.0. }
    IF spd >= topSpd    { RETURN minAuth. }
    LOCAL frac IS (spd - cruiseSpd) / (topSpd - cruiseSpd).
    RETURN 1.0 - (1.0 - minAuth) * frac^1.3.
}

GLOBAL FUNCTION planeUpdate {
    IF NOT planeActive { RETURN. }

    LOCAL auth IS _fbwAuthority().
    LOCAL clamp IS 0.3 * auth.

    IF PLANE_CFG["SURFACE_CTRL"] {
        LOCAL surfPct IS ROUND(_surfaceAuthority() * 100, 0).
        FOR sm IN _ctrlSurfaces {
            sm:SETFIELD("Authority Limiter", surfPct).
        }
    }

    IF wptNavActive AND wptIndex < wptList:LENGTH {
        LOCAL wp IS wptList[wptIndex].
        LOCAL geo IS LATLNG(wp["lat"], wp["lng"]).
        IF geo:DISTANCE < PLANE_CFG["WPT_RADIUS"] {
            SET wptIndex TO wptIndex + 1.
            IF wptIndex >= wptList:LENGTH {
                mLog("Final waypoint reached.").
                HUDTEXT("Final waypoint reached", 3, 2, 14, GREEN, FALSE).
                wptNavOff().
            } ELSE {
                mLog("Waypoint " + wptIndex + "/" + wptList:LENGTH
                    + " reached, turning to next.").
                HUDTEXT("WPT " + wptIndex + "/" + wptList:LENGTH,
                    2, 2, 13, CYAN, FALSE).
            }
        }
        IF wptNavActive AND wptIndex < wptList:LENGTH {
            SET wp TO wptList[wptIndex].
            SET geo TO LATLNG(wp["lat"], wp["lng"]).
            SET targetHdg TO geo:HEADING.
            IF wp:HASKEY("alt") { SET targetAlt TO wp["alt"]. }
        }
    }

    IF wingLevelerActive {
        SET _rollPid:SETPOINT TO 0.
        LOCAL correction IS _rollPid:UPDATE(TIME:SECONDS, SHIP:FACING:ROLL).
        SET SHIP:CONTROL:ROLL TO MAX(-clamp, MIN(clamp, correction)).
    }

    IF altHoldActive {
        SET _altPid:SETPOINT TO targetAlt.
        LOCAL tgtPitch IS _altPid:UPDATE(TIME:SECONDS, SHIP:ALTITUDE).
        LOCAL aoa IS VANG(SHIP:VELOCITY:SURFACE, SHIP:FACING:FOREVECTOR).
        IF aoa > PLANE_CFG["AOA_LIMIT"] AND tgtPitch > 0 {
            LOCAL aoaMargin IS PLANE_CFG["STALL_AOA"] - aoa.
            IF aoaMargin < 0 { SET aoaMargin TO 0. }
            SET tgtPitch TO tgtPitch
                * aoaMargin / (PLANE_CFG["STALL_AOA"] - PLANE_CFG["AOA_LIMIT"]).
        }
        SET _pitchPid:SETPOINT TO tgtPitch.
        LOCAL pitchOut IS _pitchPid:UPDATE(TIME:SECONDS, SHIP:FACING:PITCH).
        SET SHIP:CONTROL:PITCH TO MAX(-clamp, MIN(clamp, pitchOut)).
    }

    IF hdgHoldActive {
        LOCAL hdgError IS targetHdg - SHIP:FACING:YAW.
        IF hdgError > 180  { SET hdgError TO hdgError - 360. }
        IF hdgError < -180 { SET hdgError TO hdgError + 360. }
        SET _hdgPid:SETPOINT TO 0.
        LOCAL correction IS _hdgPid:UPDATE(TIME:SECONDS, -hdgError).
        SET SHIP:CONTROL:YAW TO MAX(-clamp, MIN(clamp, correction)).
    }

    IF spdHoldActive {
        SET _spdPid:SETPOINT TO targetSpd.
        LOCAL thr IS _spdPid:UPDATE(TIME:SECONDS, SHIP:AIRSPEED).
        LOCK THROTTLE TO thr.
    }
}

GLOBAL FUNCTION apOn {
    wingLevelerOn().
    altHoldOn().
    hdgHoldOn().
    SET apActive TO TRUE.
    mLog("Autopilot ON: alt=" + ROUND(targetAlt,0) + "m hdg=" + ROUND(targetHdg,0) + "deg.").
    HUDTEXT("AP ON", 3, 2, 14, GREEN, FALSE).
}

GLOBAL FUNCTION apOff {
    wptNavOff().
    wingLevelerOff().
    altHoldOff().
    hdgHoldOff().
    spdHoldOff().
    SET apActive TO FALSE.
    mLog("Autopilot OFF.").
    HUDTEXT("AP OFF", 3, 2, 14, YELLOW, FALSE).
}

GLOBAL FUNCTION wptNavOn {
    IF wptList:LENGTH = 0 {
        mLog("No waypoints loaded.").
        HUDTEXT("No waypoints!", 3, 2, 14, RED, FALSE).
        RETURN.
    }
    IF NOT apActive { apOn(). }
    SET wptIndex TO 0.
    SET wptNavActive TO TRUE.
    LOCAL wp IS wptList[0].
    mLog("Waypoint nav ON: " + wptList:LENGTH + " waypoints. First="
        + ROUND(wp["lat"],2) + "," + ROUND(wp["lng"],2) + ".").
    HUDTEXT("WPT NAV ON (" + wptList:LENGTH + " wpts)", 3, 2, 14, GREEN, FALSE).
}

GLOBAL FUNCTION wptNavOff {
    SET wptNavActive TO FALSE.
    mLog("Waypoint nav OFF.").
    HUDTEXT("WPT NAV OFF", 2, 2, 13, YELLOW, FALSE).
}

GLOBAL FUNCTION waypointLoad {
    PARAMETER wpListIn.
    SET wptList TO wpListIn.
    SET wptIndex TO 0.
    mLog("Loaded " + wptList:LENGTH + " waypoints.").
}

GLOBAL FUNCTION waypointAdd {
    PARAMETER lat_.
    PARAMETER lng_.
    PARAMETER alt_ IS -1.
    LOCAL wp IS LEXICON("lat", lat_, "lng", lng_).
    IF alt_ >= 0 { wp:ADD("alt", alt_). }
    wptList:ADD(wp).
    mLog("Waypoint added: " + ROUND(lat_,2) + "," + ROUND(lng_,2)
        + " (total " + wptList:LENGTH + ").").
}

GLOBAL FUNCTION waypointClear {
    wptNavOff().
    SET wptList TO LIST().
    SET wptIndex TO 0.
    mLog("Waypoints cleared.").
}

GLOBAL FUNCTION planeLandingAssist {
    LOCAL refSpd IS PLANE_CFG["BRAKE_REF_SPEED"].
    LOCAL stopSpd IS PLANE_CFG["BRAKE_STOP_SPEED"].
    LOCAL revDelay IS PLANE_CFG["REVERSE_THRUST_DELAY"].
    LOCAL revAG IS PLANE_CFG["REVERSE_AG"].

    mLog("Landing assist: brake attenuation armed, throttle zero.").
    LOCK THROTTLE TO 0.

    WHEN TRUE THEN {
        LOCAL spd IS SHIP:VELOCITY:SURFACE:MAG.
        IF spd > stopSpd {
            SET SHIP:CONTROL:WHEELBRAKES TO MAX(0.15, 1.0 - spd / refSpd).
            PRESERVE.
        } ELSE {
            SET SHIP:CONTROL:WHEELBRAKES TO 0.
            mLog("Brake attenuation complete — stopped.").
        }
    }

    mLog("Waiting " + revDelay + "s for reverse thrust.").
    WAIT revDelay.

    IF revAG = 2 { AG2 ON. }
    ELSE IF revAG = 3 { AG3 ON. }
    ELSE IF revAG = 4 { AG4 ON. }
    mLog("Reverse thrust AG" + revAG + " engaged.").
    LOCK THROTTLE TO 0.5.
    mLog("Partial reverse throttle (0.5).").

    WAIT UNTIL SHIP:VELOCITY:SURFACE:MAG < stopSpd.
    mLog("Below stop speed — shutting down.").

    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    IF revAG = 2 { AG2 OFF. }
    ELSE IF revAG = 3 { AG3 OFF. }
    ELSE IF revAG = 4 { AG4 OFF. }
    mLog("Landing assist complete.").
}

GLOBAL FUNCTION surveyStart {
    PARAMETER startLat.
    PARAMETER startLng.
    PARAMETER heading_.
    PARAMETER laneCount IS 4.
    PARAMETER laneLength IS PLANE_CFG["SURVEY_LANE_LENGTH"].

    LOCAL survAlt IS PLANE_CFG["SURVEY_ALT"].
    LOCAL spacing IS PLANE_CFG["SURVEY_SPACING"].

    waypointClear().

    LOCAL curLat IS startLat.
    LOCAL curLng IS startLng.
    LOCAL lane IS 0.
    UNTIL lane >= laneCount {
        LOCAL fwdHdg IS MOD(heading_ + lane * 180, 360).
        LOCAL endPt IS _geoProject(curLat, curLng, laneLength, fwdHdg).
        waypointAdd(endPt["lat"], endPt["lng"], survAlt).
        IF lane < laneCount - 1 {
            LOCAL turnHdg IS MOD(heading_ + 90, 360).
            LOCAL turnPt IS _geoProject(endPt["lat"], endPt["lng"], spacing, turnHdg).
            waypointAdd(turnPt["lat"], turnPt["lng"], survAlt).
            SET curLat TO turnPt["lat"].
            SET curLng TO turnPt["lng"].
        }
        SET lane TO lane + 1.
    }

    mLog("Survey: " + laneCount + " lanes  hdg=" + ROUND(heading_,0)
        + "  alt=" + survAlt + "m  len=" + laneLength + "m  "
        + wptList:LENGTH + " waypoints.").
    HUDTEXT("Survey: " + wptList:LENGTH + " waypoints", 3, 2, 14, CYAN, FALSE).
    altHoldOn(survAlt).
    wptNavOn().
}

GLOBAL FUNCTION planePreflightChecklist {
    PARAMETER craftName.
    PARAMETER items.

    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "    " + craftName + " PREFLIGHT CHECKLIST".
    PRINT "  ========================================".
    PRINT " ".
    FOR item IN items {
        PRINT "  [ ] " + item.
    }
    PRINT " ".
    PRINT "  -- ENVIRONMENT --".
    PRINT "  Airspeed .... " + ROUND(SHIP:AIRSPEED,1) + " m/s".
    PRINT "  Heading ..... " + ROUND(SHIP:FACING:YAW,1) + " deg".
    PRINT "  Stall speed . " + PLANE_CFG["STALL_SPEED"] + " m/s".
    PRINT "  Storage ..... " + CORE:VOLUME:FREESPACE + " bytes free".
    PRINT " ".
    PRINT "  >> Press any key when ready for takeoff".

    TERMINAL:INPUT:GETCHAR().
    PRINT " ".
    PRINT "  Takeoff clearance given.".
    mLog("Takeoff clearance given.").
}

GLOBAL FUNCTION planeStatus {
    mLog("Plane status:"
        + " airspeed=" + ROUND(SHIP:AIRSPEED,0) + "m/s"
        + " alt=" + ROUND(SHIP:ALTITUDE,0) + "m"
        + " hdg=" + ROUND(SHIP:FACING:YAW,0) + "deg"
        + " pitch=" + ROUND(SHIP:FACING:PITCH,1) + "deg"
        + " roll=" + ROUND(SHIP:FACING:ROLL,1) + "deg"
        + " ap=" + apActive
        + " wingLeveler=" + wingLevelerActive
        + " altHold=" + altHoldActive
        + " hdgHold=" + hdgHoldActive
        + " spdHold=" + spdHoldActive
        + " wptNav=" + wptNavActive
        + " wpt=" + wptIndex + "/" + wptList:LENGTH).
}

LOCAL FUNCTION _geoProject {
    PARAMETER lat0.
    PARAMETER lng0.
    PARAMETER dist.
    PARAMETER brng.
    LOCAL r IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL dlat IS dist * COS(brng) / r * (180 / 3.14159265).
    LOCAL dlng IS dist * SIN(brng) / (r * COS(lat0)) * (180 / 3.14159265).
    RETURN LEXICON("lat", lat0 + dlat, "lng", lng0 + dlng).
}
