// ============================================================
// airplane.ks - Aircraft autopilot library (0:/lib/airplane.ks)
// ============================================================

GLOBAL PLANE_CFG IS LEXICON(
    // Roll PID tracks a bank-angle target (0 for wing leveler,
    // computed from heading error for heading hold).
    "ROLL_KP",           0.02,
    "ROLL_KI",           0.001,
    "ROLL_KD",           0.01,
    // Altitude hold flies vertical speed like a real autopilot:
    // alt error -> VS target (proportional) -> pitch target (PID)
    // -> elevator (pitch PID). Direct alt->pitch invited phugoid.
    "ALT_VS_PER_M",      0.15,
    "ALT_MAX_VS",          20,
    "ALT_VS_KP",         0.40,
    "ALT_VS_KI",         0.05,
    "ALT_VS_KD",         0.05,
    "ALT_MAX_PITCH",       8,
    "ALT_MIN_PITCH",      -6,
    "PITCH_KP",          0.05,
    "PITCH_KI",          0.005,
    "PITCH_KD",          0.02,
    // Heading hold turns by BANKING (like a real airplane), not by
    // yawing: heading error -> bank target -> roll channel.
    // HDG_BANK_SIGN is an airframe escape hatch if a cockpit's
    // FACING:ROLL convention is inverted.
    "HDG_BANK_PER_DEG",  2.0,
    "HDG_MAX_BANK",       25,
    "HDG_BANK_SIGN",       1,
    "SPD_KP",            0.01,
    "SPD_KI",            0.002,
    "SPD_KD",            0.005,
    "SPD_MIN_THROTTLE",  0.0,
    "SPD_MAX_THROTTLE",  1.0,
    "WPT_RADIUS",        500,
    "STALL_SPEED",        50,
    "STALL_AOA",          20,
    "AOA_LIMIT",          15,
    "SURVEY_ALT",       2000,
    "SURVEY_SPACING",    500,
    "SURVEY_SPEED",      150,
    "SURVEY_LANE_LENGTH", 10000,
    // Control authority gain-schedules with dynamic pressure (real
    // FBW practice): full deflection at/below FBW_REF_Q, scaled
    // down as Q grows. Q accounts for altitude where speed alone
    // does not (thin air needs MORE deflection, not less).
    "FBW_REF_Q",         0.06,
    "FBW_MIN_AUTH",      0.15,
    "FBW_MAX_AUTH",      1.0,
    "BRAKE_REF_SPEED",    80,
    "BRAKE_STOP_SPEED",    3,
    "REVERSE_THRUST_DELAY", 1.5,
    "REVERSE_AG",          2,
    "REVERSE_AUTO",       TRUE,
    "REVERSE_MIN_SPEED",   50,
    "REVERSE_CONFIRM_TIME", 0.4,
    "REVERSE_THROTTLE",   0.7,
    "STEER_MAX_SPEED",    30,
    "STEER_TAG",         "steering_gear",
    "PID_CTRL",          TRUE
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
GLOBAL PLANE_APPROACHES  IS LIST(
    LEXICON(
        "name", "KSC Runway",
        "match", "KSC",
        "lat", -0.0500,
        "lng", -74.6000,
        "elev", 70,
        "hdg1", 90,
        "hdg2", 270,
        "gs", 3.0,
        "radius", 25000
    ),
    LEXICON(
        "name", "Island Airfield",
        "match", "ISLAND",
        "lat", -1.5200,
        "lng", -71.9600,
        "elev", 140,
        "hdg1", 90,
        "hdg2", 270,
        "gs", 3.0,
        "radius", 25000
    )
).
LOCAL _rollPid           IS 0.
LOCAL _altPid            IS 0.
LOCAL _pitchPid          IS 0.
LOCAL _spdPid            IS 0.

// Wrap an angle into (-180, 180].
LOCAL FUNCTION _wrap180 {
    PARAMETER a.
    UNTIL a <= 180  { SET a TO a - 360. }
    UNTIL a > -180  { SET a TO a + 360. }
    RETURN a.
}

// Bank angle with wrap protection — FACING:ROLL can report 358
// for a 2-degree left bank, which would slam a raw PID.
LOCAL FUNCTION _bankAngle {
    RETURN _wrap180(SHIP:FACING:ROLL).
}

// Merge the optional runway database (0:/data/approaches.json,
// hand-maintained — same fields as PLANE_APPROACHES entries) into
// the approach table. Synced to the local volume when connected
// so remote-field approaches work offline. No file, no effect.
LOCAL FUNCTION _loadCustomApproaches {
    LOCAL archiveDb IS "0:/data/approaches.json".
    LOCAL localDb IS "1:/data/approaches.json".
    IF HOMECONNECTION:ISCONNECTED AND EXISTS(archiveDb) {
        IF NOT EXISTS("1:/data") { CREATEDIR("1:/data"). }
        COPYPATH(archiveDb, localDb).
    }
    IF NOT EXISTS(localDb) { RETURN. }
    LOCAL db IS ADDONS:JSON:PARSEORELSE(OPEN(localDb):READALL:STRING, LEXICON()).
    LOCAL merged IS 0.
    FOR key IN db:KEYS {
        LOCAL entry IS db[key].
        LOCAL kept IS LIST().
        FOR ap IN PLANE_APPROACHES {
            IF ap["name"] <> entry["name"] { kept:ADD(ap). }
        }
        kept:ADD(entry).
        SET PLANE_APPROACHES TO kept.
        SET merged TO merged + 1.
    }
    IF merged > 0 {
        mLog("Runway database: " + merged + " field(s) merged ("
            + PLANE_APPROACHES:LENGTH + " approaches known).").
    }
}

GLOBAL FUNCTION planeInit {
    SET planeActive TO TRUE.
    _loadCustomApproaches().
    IF PLANE_CFG["PID_CTRL"] {
        mLog("Plane autopilot ready. Modes: off. Stall speed="
            + PLANE_CFG["STALL_SPEED"] + "m/s").
        HUDTEXT("Plane autopilot ready", 3, 2, 13, GREEN, FALSE).
    } ELSE {
        mLog("Plane monitor ready. PID controls disabled. Stall speed="
            + PLANE_CFG["STALL_SPEED"] + "m/s").
        HUDTEXT("Plane monitor ready", 3, 2, 13, GREEN, FALSE).
    }

    LOCAL _stallLogTime IS 0.
    WHEN planeActive AND ALT:RADAR > 2
            AND SHIP:AIRSPEED < PLANE_CFG["STALL_SPEED"]
            AND SHIP:ALTITUDE < 70000 THEN {
        IF TIME:SECONDS - _stallLogTime > 3 {
            HUDTEXT("STALL — " + ROUND(SHIP:AIRSPEED,0) + "m/s", 3, 2, 16, RED, FALSE).
            mLog("Stall warning: airspeed=" + ROUND(SHIP:AIRSPEED,0) + "m/s").
            SET _stallLogTime TO TIME:SECONDS.
        }
        PRESERVE.
    }

    mLog("Plane init: cruise=" + CFG["CRUISE_SPEED"] + " top=" + CFG["TOP_SPEED"] + "m/s").

    IF PLANE_CFG["PID_CTRL"] {
        SET _rollPid  TO PIDLOOP(PLANE_CFG["ROLL_KP"],  PLANE_CFG["ROLL_KI"],
            PLANE_CFG["ROLL_KD"],  -1, 1).
        // _altPid: vertical-speed error -> pitch target.
        SET _altPid   TO PIDLOOP(PLANE_CFG["ALT_VS_KP"], PLANE_CFG["ALT_VS_KI"],
            PLANE_CFG["ALT_VS_KD"],
            PLANE_CFG["ALT_MIN_PITCH"], PLANE_CFG["ALT_MAX_PITCH"]).
        SET _pitchPid TO PIDLOOP(PLANE_CFG["PITCH_KP"], PLANE_CFG["PITCH_KI"],
            PLANE_CFG["PITCH_KD"], -1, 1).
        SET _spdPid   TO PIDLOOP(PLANE_CFG["SPD_KP"],   PLANE_CFG["SPD_KI"],
            PLANE_CFG["SPD_KD"],
            PLANE_CFG["SPD_MIN_THROTTLE"], PLANE_CFG["SPD_MAX_THROTTLE"]).
        mLog("PID controllers initialized (roll/vs/pitch/spd).").
    } ELSE {
        mLog("PID controllers skipped.").
    }

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
    UNLOCK STEERING.
    SET planeActive TO FALSE.
    mLog("Plane autopilot shutdown.").
}

GLOBAL FUNCTION wingLevelerOn {
    IF NOT PLANE_CFG["PID_CTRL"] {
        mLog("Wing leveler unavailable: PID controls disabled.").
        HUDTEXT("PID controls disabled", 2, 2, 13, YELLOW, FALSE).
        RETURN.
    }
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
    IF NOT PLANE_CFG["PID_CTRL"] {
        mLog("Altitude hold unavailable: PID controls disabled.").
        HUDTEXT("PID controls disabled", 2, 2, 13, YELLOW, FALSE).
        RETURN.
    }
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
    IF NOT PLANE_CFG["PID_CTRL"] {
        mLog("Heading hold unavailable: PID controls disabled.").
        HUDTEXT("PID controls disabled", 2, 2, 13, YELLOW, FALSE).
        RETURN.
    }
    SET targetHdg TO hdg.
    _rollPid:RESET().
    SET hdgHoldActive TO TRUE.
    mLog("Heading hold ON at " + ROUND(hdg,0) + "deg (bank-to-turn).").
    HUDTEXT("Hdg hold ON: " + ROUND(hdg,0) + "deg", 2, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION hdgHoldOff {
    SET hdgHoldActive TO FALSE.
    SET SHIP:CONTROL:ROLL TO 0.
    mLog("Heading hold OFF.").
    HUDTEXT("Hdg hold OFF", 2, 2, 13, YELLOW, FALSE).
}

GLOBAL FUNCTION spdHoldOn {
    PARAMETER tSpd IS SHIP:AIRSPEED.
    IF NOT PLANE_CFG["PID_CTRL"] {
        mLog("Speed hold unavailable: PID controls disabled.").
        HUDTEXT("PID controls disabled", 2, 2, 13, YELLOW, FALSE).
        RETURN.
    }
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

// planeCtrlAuthority — single gain schedule for all control output,
// proportional to reference/current dynamic pressure. Replaces both
// the old airspeed-based FBW clamp and the SURFACE_CTRL path that
// poked every surface's "Authority Limiter" part field per tick
// (slow, invisible in logs, and redundant with the clamp).
// Exported so observe.ks logs the same number the loops use.
GLOBAL FUNCTION planeCtrlAuthority {
    LOCAL q_ IS MAX(SHIP:Q, 0.0001).
    RETURN MAX(PLANE_CFG["FBW_MIN_AUTH"],
           MIN(PLANE_CFG["FBW_MAX_AUTH"],
               PLANE_CFG["FBW_REF_Q"] / q_)).
}

// ============================================================
// Automatic thrust reversers
//
// Engages at touchdown instead of waiting for the POSTFLIGHT
// landing assist (by which point the jet is already slow). The
// "really landing" discriminator is BRAKES: a full-stop landing
// holds brakes from touchdown, a touch-and-go never brakes — so
// the old blanket REVERSE_THRUST_DELAY false-positive guard
// shrinks to a short REVERSE_CONFIRM_TIME contact check, and a
// bounce cancels the reversers instantly.
// ============================================================

LOCAL _revState IS "idle".
LOCAL _revConfirmT IS 0.

LOCAL FUNCTION _reverseSet {
    PARAMETER on.
    LOCAL revAG IS PLANE_CFG["REVERSE_AG"].
    IF on {
        IF revAG = 2 { AG2 ON. }
        ELSE IF revAG = 3 { AG3 ON. }
        ELSE IF revAG = 4 { AG4 ON. }
        LOCK THROTTLE TO PLANE_CFG["REVERSE_THROTTLE"].
    } ELSE {
        IF revAG = 2 { AG2 OFF. }
        ELSE IF revAG = 3 { AG3 OFF. }
        ELSE IF revAG = 4 { AG4 OFF. }
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
    }
}

LOCAL FUNCTION _reverseThrustUpdate {
    IF NOT PLANE_CFG["REVERSE_AUTO"] { RETURN. }
    LOCAL onGround IS SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    LOCAL gspd IS SHIP:GROUNDSPEED.

    IF _revState = "idle" {
        IF onGround AND BRAKES AND gspd > PLANE_CFG["REVERSE_MIN_SPEED"] {
            SET _revState TO "confirming".
            SET _revConfirmT TO TIME:SECONDS.
        }
    } ELSE IF _revState = "confirming" {
        IF NOT onGround OR NOT BRAKES {
            SET _revState TO "idle".
        } ELSE IF TIME:SECONDS - _revConfirmT >= PLANE_CFG["REVERSE_CONFIRM_TIME"] {
            _reverseSet(TRUE).
            SET _revState TO "active".
            mLog("Reverse thrust engaged at " + ROUND(gspd, 0)
                + " m/s (AG" + PLANE_CFG["REVERSE_AG"]
                + " thr=" + PLANE_CFG["REVERSE_THROTTLE"] + ").").
            HUDTEXT("REVERSE THRUST", 3, 2, 15, YELLOW, FALSE).
        }
    } ELSE IF _revState = "active" {
        LOCAL reason IS "".
        IF NOT onGround { SET reason TO "airborne again". }
        ELSE IF NOT BRAKES { SET reason TO "brakes released". }
        ELSE IF gspd < PLANE_CFG["BRAKE_STOP_SPEED"] { SET reason TO "stopped". }
        IF reason <> "" {
            _reverseSet(FALSE).
            SET _revState TO "idle".
            mLog("Reverse thrust stowed (" + reason + ") at "
                + ROUND(gspd, 0) + " m/s.").
        }
    }
}

GLOBAL FUNCTION planeUpdate {
    IF NOT planeActive { RETURN. }

    _reverseThrustUpdate().

    LOCAL auth IS planeCtrlAuthority().
    LOCAL clamp IS 0.3 * auth.

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

    // Roll channel: heading hold owns it (bank-to-turn); the wing
    // leveler is the fallback when no heading is commanded.
    IF hdgHoldActive {
        LOCAL hdgError IS _wrap180(targetHdg - SHIP:FACING:YAW).
        LOCAL maxBank IS PLANE_CFG["HDG_MAX_BANK"].
        LOCAL bankTgt IS PLANE_CFG["HDG_BANK_SIGN"]
            * MAX(-maxBank, MIN(maxBank,
                PLANE_CFG["HDG_BANK_PER_DEG"] * hdgError)).
        SET _rollPid:SETPOINT TO bankTgt.
        LOCAL correction IS _rollPid:UPDATE(TIME:SECONDS, _bankAngle()).
        SET SHIP:CONTROL:ROLL TO MAX(-clamp, MIN(clamp, correction)).
    } ELSE IF wingLevelerActive {
        SET _rollPid:SETPOINT TO 0.
        LOCAL correction IS _rollPid:UPDATE(TIME:SECONDS, _bankAngle()).
        SET SHIP:CONTROL:ROLL TO MAX(-clamp, MIN(clamp, correction)).
    }

    IF altHoldActive {
        // alt error -> VS target (proportional, capped) -> pitch
        // target (PID on vertical speed) -> elevator (pitch PID).
        LOCAL vsTarget IS MAX(-PLANE_CFG["ALT_MAX_VS"],
            MIN(PLANE_CFG["ALT_MAX_VS"],
                PLANE_CFG["ALT_VS_PER_M"] * (targetAlt - SHIP:ALTITUDE))).
        SET _altPid:SETPOINT TO vsTarget.
        LOCAL tgtPitch IS _altPid:UPDATE(TIME:SECONDS, SHIP:VERTICALSPEED).
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

    IF spdHoldActive {
        SET _spdPid:SETPOINT TO targetSpd.
        LOCAL thr IS _spdPid:UPDATE(TIME:SECONDS, SHIP:AIRSPEED).
        LOCK THROTTLE TO thr.
    }
}

GLOBAL FUNCTION apOn {
    IF NOT PLANE_CFG["PID_CTRL"] {
        SET apActive TO FALSE.
        mLog("Autopilot unavailable: PID controls disabled.").
        HUDTEXT("PID controls disabled", 3, 2, 14, YELLOW, FALSE).
        RETURN.
    }
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
        IF NOT waypointUseSelected(CFG["CRUISE_ALT"]) {
            mLog("No waypoints loaded and no selected waypoint found.").
            HUDTEXT("Select waypoint first", 3, 2, 14, RED, FALSE).
            RETURN.
        }
    }
    IF PLANE_CFG["PID_CTRL"] AND NOT apActive { apOn(). }
    SET wptIndex TO 0.
    SET wptNavActive TO TRUE.
    LOCAL wp IS wptList[0].
    IF PLANE_CFG["PID_CTRL"] {
        mLog("Waypoint nav ON: " + wptList:LENGTH + " waypoints. First="
            + ROUND(wp["lat"],2) + "," + ROUND(wp["lng"],2) + ".").
        HUDTEXT("WPT NAV ON (" + wptList:LENGTH + " wpts)", 3, 2, 14, GREEN, FALSE).
    } ELSE {
        mLog("Waypoint monitor ON: " + wptList:LENGTH + " waypoints. First="
            + ROUND(wp["lat"],2) + "," + ROUND(wp["lng"],2)
            + ". PID steering disabled.").
        HUDTEXT("WPT MONITOR (" + wptList:LENGTH + " wpts)", 3, 2, 14, CYAN, FALSE).
    }
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
    PARAMETER name_ IS "".
    LOCAL wp IS LEXICON("lat", lat_, "lng", lng_).
    IF alt_ >= 0 { wp:ADD("alt", alt_). }
    IF name_ <> "" { wp:ADD("name", name_). }
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

GLOBAL FUNCTION waypointUseSelected {
    PARAMETER alt_ IS CFG["CRUISE_ALT"].
    LOCAL wp IS selectedWaypoint().
    IF wp = 0 {
        mLog("No selected waypoint on " + SHIP:BODY:NAME + ".").
        RETURN FALSE.
    }

    waypointClear().
    waypointAdd(wp:GEOPOSITION:LAT, wp:GEOPOSITION:LNG, alt_, wp:NAME).
    mLog("Selected waypoint loaded: " + wp:NAME
        + " dist=" + ROUND(wp:GEOPOSITION:DISTANCE / 1000, 1) + "km"
        + " brg=" + ROUND(wp:GEOPOSITION:HEADING, 0) + "deg"
        + " cruiseAlt=" + ROUND(alt_, 0) + "m.").
    HUDTEXT("WPT: " + wp:NAME, 4, 2, 14, CYAN, FALSE).
    planeApproachBrief(wp:GEOPOSITION:LAT, wp:GEOPOSITION:LNG, wp:NAME).
    RETURN TRUE.
}

GLOBAL FUNCTION planeApproachBriefSelected {
    LOCAL wp IS selectedWaypoint().
    IF wp = 0 {
        mLog("Approach brief: no selected waypoint on " + SHIP:BODY:NAME + ".").
        HUDTEXT("No selected waypoint", 3, 2, 14, YELLOW, FALSE).
        RETURN FALSE.
    }
    planeApproachBrief(wp:GEOPOSITION:LAT, wp:GEOPOSITION:LNG, wp:NAME).
    RETURN TRUE.
}

GLOBAL FUNCTION planeApproachBrief {
    PARAMETER lat_.
    PARAMETER lng_.
    PARAMETER name_ IS "".

    LOCAL ap IS _nearestApproach(lat_, lng_, name_).
    IF ap = 0 {
        mLog("Approach brief: no known runway data near " + name_ + ".").
        RETURN FALSE.
    }

    LOCAL gs IS ap["gs"].
    LOCAL elev IS ap["elev"].
    LOCAL distM IS geoDistance(SHIP:LATITUDE, SHIP:LONGITUDE, lat_, lng_).
    LOCAL altAgl IS MAX(0, SHIP:ALTITUDE - elev).
    LOCAL todM IS 0.
    IF gs > 0 {
        SET todM TO altAgl / TAN(gs).
    }

    LOCAL inbound IS LATLNG(lat_, lng_):HEADING.
    LOCAL rwyHdg IS _bestRunwayHeading(ap, inbound).
    LOCAL fieldRange IS geoDistance(lat_, lng_, ap["lat"], ap["lng"]).

    mLog("Approach " + ap["name"]
        + " via " + name_
        + ": rwys " + ROUND(ap["hdg1"],0) + "/" + ROUND(ap["hdg2"],0)
        + " use " + ROUND(rwyHdg,0)
        + " gs=" + ROUND(gs,1)
        + " elev=" + ROUND(elev,0) + "m"
        + " fieldErr=" + ROUND(fieldRange,0) + "m.").
    mLog("Approach TOD: range=" + ROUND(distM / 1000,1) + "km"
        + " altAgl=" + ROUND(altAgl,0) + "m"
        + " descendAt~" + ROUND(todM / 1000,1) + "km.").
    HUDTEXT(ap["name"] + " APP " + ROUND(rwyHdg,0)
        + " TOD " + ROUND(todM / 1000,1) + "km", 5, 2, 13, CYAN, FALSE).
    RETURN TRUE.
}

GLOBAL FUNCTION planeLandingAssist {
    LOCAL stopSpd IS PLANE_CFG["BRAKE_STOP_SPEED"].

    mLog("Landing assist: brakes on, throttle zero.").
    LOCK THROTTLE TO 0.
    SET BRAKES TO TRUE.

    IF PLANE_CFG["REVERSE_AUTO"] {
        // Drive the touchdown reverser state machine until stopped —
        // it engages immediately (brakes are on) and stows itself.
        UNTIL SHIP:VELOCITY:SURFACE:MAG < stopSpd {
            _reverseThrustUpdate().
            WAIT 0.05.
        }
        _reverseThrustUpdate().
        _reverseSet(FALSE).
        SET _revState TO "idle".
    } ELSE {
        // Legacy fixed-delay path for craft with REVERSE_AUTO off.
        LOCAL revDelay IS PLANE_CFG["REVERSE_THRUST_DELAY"].
        mLog("Waiting " + revDelay + "s for reverse thrust.").
        WAIT revDelay.
        _reverseSet(TRUE).
        mLog("Reverse thrust AG" + PLANE_CFG["REVERSE_AG"] + " engaged.").
        WAIT UNTIL SHIP:VELOCITY:SURFACE:MAG < stopSpd.
        _reverseSet(FALSE).
    }

    mLog("Below stop speed — shutting down.").
    SET BRAKES TO TRUE.
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

// planePreflightReset — put the airframe back into takeoff trim.
// Run every leg (multi-leg airline flights land with landing trim,
// stowed-but-armed reversers, and stale control inputs).
GLOBAL FUNCTION planePreflightReset {
    SET SHIP:CONTROL:PILOTPITCHTRIM TO 0.
    SET SHIP:CONTROL:PILOTYAWTRIM TO 0.
    SET SHIP:CONTROL:PILOTROLLTRIM TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    SET SHIP:CONTROL:NEUTRALIZE TO TRUE.
    _reverseSet(FALSE).
    SET _revState TO "idle".
    SET BRAKES TO TRUE.
    mLog("Preflight reset: trims zeroed, reversers stowed, "
        + "throttle idle, brakes hold.").
}

GLOBAL FUNCTION planePreflightChecklist {
    PARAMETER craftName.
    PARAMETER items.

    planePreflightReset().

    LOCAL envRows IS LIST(
        "Airspeed .... " + ROUND(SHIP:AIRSPEED,1) + " m/s",
        "Heading ..... " + ROUND(SHIP:FACING:YAW,1) + " deg",
        "Stall speed . " + PLANE_CFG["STALL_SPEED"] + " m/s",
        "Storage ..... " + CORE:VOLUME:FREESPACE + " bytes free"
    ).
    flightPlanChecklist(
        craftName + " PREFLIGHT CHECKLIST",
        items,
        envRows,
        "Press any key when ready for takeoff"
    ).
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
    LOCAL r_ IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL dlat IS dist * COS(brng) / r_ * (180 / 3.14159265).
    LOCAL dlng IS dist * SIN(brng) / (r_ * COS(lat0)) * (180 / 3.14159265).
    RETURN LEXICON("lat", lat0 + dlat, "lng", lng0 + dlng).
}

LOCAL FUNCTION _angleDiff {
    PARAMETER a.
    PARAMETER b.
    LOCAL d IS a - b.
    IF d > 180 { SET d TO d - 360. }
    IF d < -180 { SET d TO d + 360. }
    RETURN ABS(d).
}

// Public accessors over the approach table (used by lib/ssto.ks).
GLOBAL FUNCTION planeApproachFor {
    PARAMETER name_ IS "".
    RETURN _nearestApproach(SHIP:LATITUDE, SHIP:LONGITUDE, name_).
}

GLOBAL FUNCTION planeRunwayHeading {
    PARAMETER ap.
    PARAMETER inbound.
    RETURN _bestRunwayHeading(ap, inbound).
}

LOCAL FUNCTION _approachNameMatches {
    PARAMETER ap.
    PARAMETER name_.
    IF name_ = "" { RETURN FALSE. }
    LOCAL nm IS name_:TOUPPER.
    LOCAL apName IS ap["name"]:TOUPPER.
    IF nm:CONTAINS(ap["match"]) { RETURN TRUE. }
    IF nm:CONTAINS(apName) { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _nearestApproach {
    PARAMETER lat_.
    PARAMETER lng_.
    PARAMETER name_ IS "".
    LOCAL best IS 0.
    LOCAL bestDist IS 999999999.
    FOR ap IN PLANE_APPROACHES {
        LOCAL d IS geoDistance(lat_, lng_, ap["lat"], ap["lng"]).
        IF _approachNameMatches(ap, name_) { RETURN ap. }
        IF d < bestDist {
            SET best TO ap.
            SET bestDist TO d.
        }
    }
    IF best <> 0 AND bestDist <= best["radius"] { RETURN best. }
    RETURN 0.
}

LOCAL FUNCTION _bestRunwayHeading {
    PARAMETER ap.
    PARAMETER inbound.
    IF _angleDiff(ap["hdg1"], inbound) <= _angleDiff(ap["hdg2"], inbound) {
        RETURN ap["hdg1"].
    }
    RETURN ap["hdg2"].
}

// ============================================================
// airplaneMain — shared flight-computer skeleton
//
// Every aircraft was carrying the same ~120 lines of sequence
// plumbing, science-payload checks, and PREFLIGHT/FLIGHT/
// POSTFLIGHT handlers. Craft scripts now reduce to CFG + a call:
//
//   GLOBAL FUNCTION main {
//       airplaneMain("FJ1A", LEXICON("checklist", LIST(...))).
//   }
//
// opts (all optional):
//   "defaultSeq"    LIST     — fallback when no mission SEQUENCE
//   "checklist"     LIST     — preflight checklist items
//   "configure"     delegate — PLANE_CFG hook, runs at each phase
//   "configRows"    delegate — extra flightPlan rows for the brief
//   "phases"        LEXICON  — extra/override phase handlers
//   "landingAssist" bool     — run planeLandingAssist (default TRUE)
//
// Per-craft behavior comes from CFG instead of bespoke handlers:
//   AIRBORNE_SPEED       — preflight ends past this speed (50)
//   AIRBORNE_RADAR_ALT   — min radar alt to count as flying (0)
//   MIN_FLIGHT_TIME      — seconds aloft before a touchdown can
//                          end FLIGHT (0; FBIJ uses 60 for T&G)
//   FINAL_LANDING_SPEED  — max speed for a final landing (off;
//                          lets touch-and-goes roll through)
// ============================================================

LOCAL _amName IS "".
LOCAL _amOpts IS LEXICON().
LOCAL _amSeq IS LIST().
LOCAL _amHasScience IS FALSE.

LOCAL FUNCTION _amCfgNum {
    PARAMETER key, defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _amConfigure {
    IF _amOpts:HASKEY("configure") { _amOpts["configure"]:CALL(). }
}

LOCAL FUNCTION _amOnGround {
    RETURN SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
}

LOCAL FUNCTION _amFlying {
    IF SHIP:STATUS = "SUB_ORBITAL" OR SHIP:STATUS = "ORBITING" { RETURN TRUE. }
    RETURN SHIP:STATUS = "FLYING"
        AND ALT:RADAR > _amCfgNum("AIRBORNE_RADAR_ALT", 0).
}

LOCAL FUNCTION _amFinalLanding {
    PARAMETER airborneTime.
    IF NOT _amOnGround() { RETURN FALSE. }
    IF TIME:SECONDS - airborneTime < _amCfgNum("MIN_FLIGHT_TIME", 0) {
        RETURN FALSE.
    }
    RETURN SHIP:AIRSPEED <= _amCfgNum("FINAL_LANDING_SPEED", 9999).
}

LOCAL FUNCTION _amPrintConfig {
    flightPlanTitle(_amName + " FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("CRUISE").
    flightPlanRow("ALT", CFG["CRUISE_ALT"] + " m").
    flightPlanRow("SPEED", CFG["CRUISE_SPEED"] + " m/s").
    IF _amOpts:HASKEY("configRows") { _amOpts["configRows"]:CALL(). }
    flightPlanSection("SEQUENCE").
    flightPlanSequence(_amSeq).
}

LOCAL FUNCTION _amPhasePreflight {
    mLogPhase("PREFLIGHT").
    _amConfigure().
    planeInit().
    observeStart().

    LOCAL items IS LIST("Brakes - HOLD until ready",
        "Stage - start engines", "Throttle - FULL").
    IF _amOpts:HASKEY("checklist") { SET items TO _amOpts["checklist"]. }
    planePreflightChecklist(_amName, items).

    WAIT UNTIL _amFlying() OR SHIP:AIRSPEED > _amCfgNum("AIRBORNE_SPEED", 50).
    mLog("Airborne.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _amPhaseFlight {
    mLogPhase("FLIGHT").
    _amConfigure().
    IF NOT planeActive { planeInit(). }
    IF _amHasScience { scienceInit(). }

    // SHIP:STATUS stays LANDED through the takeoff roll — wait for
    // real liftoff before watching for a landing.
    mLog("Waiting for liftoff...").
    WAIT UNTIL _amFlying().
    LOCAL airborneTime IS TIME:SECONDS.
    mLog("Flight active. Monitoring until final landing.").

    UNTIL _amFinalLanding(airborneTime) {
        planeUpdate().
        IF _amHasScience { scienceRunAll(). }
        WAIT 0.1.
    }
    mLog("Final landing detected.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _amPhasePostFlight {
    mLogPhase("POSTFLIGHT").
    _amConfigure().
    IF _amHasScience { scienceTransmitAll(). }
    LOCAL assist IS TRUE.
    IF _amOpts:HASKEY("landingAssist") { SET assist TO _amOpts["landingAssist"]. }
    IF assist { planeLandingAssist(). }
    planeShutdown().
    mLog(_amName + " flight complete.").
    nextPhase(launchSeq).
}

GLOBAL FUNCTION airplaneMain {
    PARAMETER craftName.
    PARAMETER opts IS LEXICON().

    SET _amName TO craftName.
    SET _amOpts TO opts.

    // Mission profile values override the craft's CFG defaults
    // (rocket craft do this at script load; planes do it here).
    applyKnownMissionState().

    LOCAL defaultSeq IS LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "DONE").
    IF opts:HASKEY("defaultSeq") { SET defaultSeq TO opts["defaultSeq"]. }
    SET _amSeq TO defaultSeq.
    IF stateGet("mission_cfg_SEQUENCE", "") <> "" {
        SET _amSeq TO phaseListFromString(stateGet("mission_cfg_SEQUENCE", "")).
    }
    SET launchSeq TO _amSeq.
    SET xferSeq TO _amSeq.

    SET _amHasScience TO missionHasPayload("SCIENCE").

    mLogPhase(craftName + " MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    IF stateGet("phase", "") = "" { stateSet("phase", _amSeq[0]). }

    _amPrintConfig().

    LOCAL phaseMap IS LEXICON(
        "PREFLIGHT",   _amPhasePreflight@,
        "FLIGHT",      _amPhaseFlight@,
        "POSTFLIGHT",  _amPhasePostFlight@,
        "POST_FLIGHT", _amPhasePostFlight@
    ).
    IF opts:HASKEY("phases") {
        FOR key IN opts["phases"]:KEYS {
            phaseMapSet(phaseMap, key, opts["phases"][key]).
        }
    }
    runPhases(phaseMap).
}

// ============================================================
// Binder stubs: PREFLIGHT/FLIGHT/POSTFLIGHT are dispatched by
// airplaneMain's internal phase map, not runPhases — these exist
// so dependencyBindPhase can reference the handler names wherever
// the airplane lib is loaded (e.g. SSTO craft, whose lib depends
// on airplane) without an undefined-name crash. POST_FLIGHT and
// POSTFLIGHT camelCase to the same case-insensitive identifier,
// so one definition serves both.
// ============================================================
GLOBAL FUNCTION phasePreflight {
    mLogWarn("PREFLIGHT is handled by airplaneMain — manual ops.").
    yieldToPrompt().
}
GLOBAL FUNCTION phaseFlight {
    mLogWarn("FLIGHT is handled by airplaneMain — manual ops.").
    yieldToPrompt().
}
GLOBAL FUNCTION phasePostFlight {
    mLogWarn("POSTFLIGHT is handled by airplaneMain — manual ops.").
    yieldToPrompt().
}
