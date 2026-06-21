// ============================================================
// airplane.ks - Aircraft autopilot library (0:/lib/airplane.ks)
// ============================================================

// --- Mission-facing config (craft/profile scripts override these) ---
GLOBAL CRUISE_ALT IS 2500.
GLOBAL CRUISE_SPEED IS 180.
GLOBAL TOP_SPEED IS 250.
GLOBAL SPLASHDOWN_SPEED IS 50.
GLOBAL FINAL_LANDING_SPEED IS 25.
GLOBAL MIN_FLIGHT_TIME IS 30.
GLOBAL FLAP_AG IS 1.
GLOBAL AIRBORNE_RADAR_ALT IS 0.
GLOBAL AIRBORNE_SPEED IS 50.

// --- Assist/PID config (flat globals; craft scripts SET to tune) ---
// House style is flat globals read directly by the loops; airtest.ks
// pokes PLANE_HDG_BANK_SIGN live and bakes the result into a craft.

// Roll PID tracks a bank-angle target (0 for wing leveler, computed
// from heading error for heading hold).
GLOBAL PLANE_ROLL_KP IS 0.02.
GLOBAL PLANE_ROLL_KI IS 0.001.
GLOBAL PLANE_ROLL_KD IS 0.01.
// Altitude hold flies vertical speed like a real autopilot: alt error
// -> VS target (proportional) -> pitch target (PID) -> elevator (pitch
// PID). Direct alt->pitch invited phugoid.
GLOBAL PLANE_ALT_VS_PER_M IS 0.15.
GLOBAL PLANE_ALT_MAX_VS IS 20.
GLOBAL PLANE_ALT_VS_KP IS 0.40.
GLOBAL PLANE_ALT_VS_KI IS 0.05.
GLOBAL PLANE_ALT_VS_KD IS 0.05.
GLOBAL PLANE_ALT_MAX_PITCH IS 8.
GLOBAL PLANE_ALT_MIN_PITCH IS -6.
GLOBAL PLANE_PITCH_KP IS 0.05.
GLOBAL PLANE_PITCH_KI IS 0.005.
GLOBAL PLANE_PITCH_KD IS 0.02.
// Heading hold turns by BANKING (like a real airplane), not by yawing:
// heading error -> bank target -> roll channel. HDG_BANK_SIGN is an
// airframe escape hatch if a cockpit's FACING:ROLL convention is
// inverted (airtest.ks flips it empirically).
GLOBAL PLANE_HDG_BANK_PER_DEG IS 2.0.
GLOBAL PLANE_HDG_MAX_BANK IS 25.
GLOBAL PLANE_HDG_BANK_SIGN IS 1.
GLOBAL PLANE_SPD_KP IS 0.01.
GLOBAL PLANE_SPD_KI IS 0.002.
GLOBAL PLANE_SPD_KD IS 0.005.
GLOBAL PLANE_SPD_MIN_THROTTLE IS 0.0.
GLOBAL PLANE_SPD_MAX_THROTTLE IS 1.0.
GLOBAL PLANE_WPT_RADIUS IS 500.
GLOBAL PLANE_STALL_SPEED IS 50.
GLOBAL PLANE_STALL_AOA IS 20.
GLOBAL PLANE_AOA_LIMIT IS 15.
GLOBAL PLANE_SURVEY_ALT IS 2000.
GLOBAL PLANE_SURVEY_SPACING IS 500.
GLOBAL PLANE_SURVEY_SPEED IS 150.
GLOBAL PLANE_SURVEY_LANE_LENGTH IS 10000.
// Control authority gain-schedules with dynamic pressure (real FBW
// practice): full deflection at/below FBW_REF_Q, scaled down as Q
// grows. Q accounts for altitude where speed alone does not (thin air
// needs MORE deflection, not less).
GLOBAL PLANE_FBW_REF_Q IS 0.06.
GLOBAL PLANE_FBW_MIN_AUTH IS 0.15.
GLOBAL PLANE_FBW_MAX_AUTH IS 1.0.
// Surface-deflection cap: the loops never command more than this
// fraction of travel (times the Q authority schedule above) — soft,
// stable inputs instead of bang-bang. Lower = gentler/laggier.
GLOBAL PLANE_CTRL_DAMPING IS 0.3.
GLOBAL PLANE_BRAKE_REF_SPEED IS 80.
GLOBAL PLANE_BRAKE_STOP_SPEED IS 3.
GLOBAL PLANE_REVERSE_THRUST_DELAY IS 1.5.
GLOBAL PLANE_REVERSE_AG IS 2.
GLOBAL PLANE_REVERSE_AUTO IS TRUE.
GLOBAL PLANE_REVERSE_MIN_SPEED IS 50.
GLOBAL PLANE_REVERSE_CONFIRM_TIME IS 0.4.
GLOBAL PLANE_REVERSE_THROTTLE IS 0.7.
// Nosewheel steering fades with speed and hard-cuts for the takeoff
// roll/landing rollout: authority is disabled above OFF_SPEED and
// re-enabled (hysteresis gap) below ON_SPEED, so rudder at speed can't
// twitch the nose. STEER_TAG optionally marks the steering wheels; if
// nothing is tagged we auto-detect parts with a wheel-steering module.
GLOBAL PLANE_STEER_OFF_SPEED IS 30.
GLOBAL PLANE_STEER_ON_SPEED IS 15.
GLOBAL PLANE_STEER_TAG IS "steering_gear".
// Operator action-group toggles for the two flight-director modes
// (kOS AG numbers): AP = wing-leveler+alt+hdg, NAV = waypoint nav.
// Defaults 7/8; a craft can move them within reach but must keep them
// clear of PLANE_REVERSE_AG (the auto reverser fires that group on
// touchdown, which would otherwise read as a toggle press).
GLOBAL PLANE_AP_AG IS 7.
GLOBAL PLANE_WPTNAV_AG IS 8.
// Assists are monitor-only until a craft opts in (SET PLANE_PID_CTRL).
GLOBAL PLANE_PID_CTRL IS FALSE.

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

// Read an action group's state by number — kOS exposes AG1..AG10 as
// distinct bound names, so a numeric config needs this dispatch.
LOCAL FUNCTION _agState {
    PARAMETER n.
    IF n = 1  { RETURN AG1.  }
    IF n = 2  { RETURN AG2.  }
    IF n = 3  { RETURN AG3.  }
    IF n = 4  { RETURN AG4.  }
    IF n = 5  { RETURN AG5.  }
    IF n = 6  { RETURN AG6.  }
    IF n = 7  { RETURN AG7.  }
    IF n = 8  { RETURN AG8.  }
    IF n = 9  { RETURN AG9.  }
    IF n = 10 { RETURN AG10. }
    RETURN FALSE.
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
    IF OPEN(localDb):READALL:STRING:TRIM = "" { RETURN. }
    LOCAL db IS READJSON(localDb).
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
    IF PLANE_PID_CTRL {
        mLog("Plane autopilot ready. Modes: off. Stall speed="
            + PLANE_STALL_SPEED + "m/s").
        HUDTEXT("Plane autopilot ready", 3, 2, 13, GREEN, FALSE).
    } ELSE {
        mLog("Plane monitor ready. PID controls disabled. Stall speed="
            + PLANE_STALL_SPEED + "m/s").
        HUDTEXT("Plane monitor ready", 3, 2, 13, GREEN, FALSE).
    }

    LOCAL _stallLogTime IS 0.
    WHEN planeActive AND ALT:RADAR > 2
            AND SHIP:AIRSPEED < PLANE_STALL_SPEED
            AND SHIP:ALTITUDE < 70000 THEN {
        IF TIME:SECONDS - _stallLogTime > 3 {
            HUDTEXT("STALL — " + ROUND(SHIP:AIRSPEED,0) + "m/s", 3, 2, 16, RED, FALSE).
            mLog("Stall warning: airspeed=" + ROUND(SHIP:AIRSPEED,0) + "m/s").
            SET _stallLogTime TO TIME:SECONDS.
        }
        PRESERVE.
    }

    mLog("Plane init: cruise=" + CRUISE_SPEED + " top=" + TOP_SPEED + "m/s").

    IF PLANE_PID_CTRL {
        SET _rollPid  TO PIDLOOP(PLANE_ROLL_KP,  PLANE_ROLL_KI,
            PLANE_ROLL_KD,  -1, 1).
        // _altPid: vertical-speed error -> pitch target.
        SET _altPid   TO PIDLOOP(PLANE_ALT_VS_KP, PLANE_ALT_VS_KI,
            PLANE_ALT_VS_KD,
            PLANE_ALT_MIN_PITCH, PLANE_ALT_MAX_PITCH).
        SET _pitchPid TO PIDLOOP(PLANE_PITCH_KP, PLANE_PITCH_KI,
            PLANE_PITCH_KD, -1, 1).
        SET _spdPid   TO PIDLOOP(PLANE_SPD_KP,   PLANE_SPD_KI,
            PLANE_SPD_KD,
            PLANE_SPD_MIN_THROTTLE, PLANE_SPD_MAX_THROTTLE).
        mLog("PID controllers initialized (roll/vs/pitch/spd).").
    } ELSE {
        mLog("PID controllers skipped.").
    }

    LOCAL _prevApAg IS _agState(PLANE_AP_AG).
    LOCAL _prevNavAg IS _agState(PLANE_WPTNAV_AG).
    mLog("Toggles: autopilot=AG" + PLANE_AP_AG
        + " waypoint-nav=AG" + PLANE_WPTNAV_AG + ".").
    WHEN planeActive THEN {
        LOCAL apAg IS _agState(PLANE_AP_AG).
        LOCAL navAg IS _agState(PLANE_WPTNAV_AG).
        IF apAg <> _prevApAg {
            SET _prevApAg TO apAg.
            IF apActive { apOff(). } ELSE { apOn(). }
        }
        IF navAg <> _prevNavAg {
            SET _prevNavAg TO navAg.
            IF wptNavActive { wptNavOff(). } ELSE { wptNavOn(). }
        }
        PRESERVE.
    }

    // Prefer explicitly tagged steering wheels; otherwise auto-detect
    // any wheel with a steering module (the gear is often left untagged).
    LOCAL steerParts IS SHIP:PARTSTAGGED(PLANE_STEER_TAG).
    IF steerParts:LENGTH = 0 {
        FOR p IN SHIP:PARTS {
            IF p:MODULES:CONTAINS("ModuleWheelSteering") { steerParts:ADD(p). }
        }
    }
    IF steerParts:LENGTH > 0 {
        mLog("Nosewheel steering: " + steerParts:LENGTH + " steerable wheel(s); "
            + "off >" + PLANE_STEER_OFF_SPEED
            + " on <" + PLANE_STEER_ON_SPEED + " m/s (ground).").
        LOCAL _steerEnabled IS TRUE.
        WHEN planeActive THEN {
            LOCAL gspd IS SHIP:GROUNDSPEED.
            // Hysteresis: cut once fast, restore only well back down.
            IF _steerEnabled AND gspd > PLANE_STEER_OFF_SPEED {
                SET _steerEnabled TO FALSE.
                SET SHIP:CONTROL:WHEELSTEER TO 0.
                mLog("Nosewheel steering OFF at " + ROUND(gspd, 0) + " m/s.").
            } ELSE IF (NOT _steerEnabled) AND gspd < PLANE_STEER_ON_SPEED {
                SET _steerEnabled TO TRUE.
                mLog("Nosewheel steering ON (taxi) at " + ROUND(gspd, 0) + " m/s.").
            }
            IF _steerEnabled {
                // Taper authority toward zero as the cutoff nears.
                LOCAL factor IS MAX(0, 1.0 - gspd / PLANE_STEER_OFF_SPEED).
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
    IF NOT PLANE_PID_CTRL {
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
    IF NOT PLANE_PID_CTRL {
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
    IF NOT PLANE_PID_CTRL {
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
    IF NOT PLANE_PID_CTRL {
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
    RETURN MAX(PLANE_FBW_MIN_AUTH,
           MIN(PLANE_FBW_MAX_AUTH,
               PLANE_FBW_REF_Q / q_)).
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
    LOCAL revAG IS PLANE_REVERSE_AG.
    IF on {
        IF revAG = 2 { AG2 ON. }
        ELSE IF revAG = 3 { AG3 ON. }
        ELSE IF revAG = 4 { AG4 ON. }
        LOCK THROTTLE TO PLANE_REVERSE_THROTTLE.
    } ELSE {
        IF revAG = 2 { AG2 OFF. }
        ELSE IF revAG = 3 { AG3 OFF. }
        ELSE IF revAG = 4 { AG4 OFF. }
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
    }
}

LOCAL FUNCTION _reverseThrustUpdate {
    IF NOT PLANE_REVERSE_AUTO { RETURN. }
    LOCAL onGround IS SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    LOCAL gspd IS SHIP:GROUNDSPEED.

    IF _revState = "idle" {
        IF onGround AND BRAKES AND gspd > PLANE_REVERSE_MIN_SPEED {
            SET _revState TO "confirming".
            SET _revConfirmT TO TIME:SECONDS.
        }
    } ELSE IF _revState = "confirming" {
        IF NOT onGround OR NOT BRAKES {
            SET _revState TO "idle".
        } ELSE IF TIME:SECONDS - _revConfirmT >= PLANE_REVERSE_CONFIRM_TIME {
            _reverseSet(TRUE).
            SET _revState TO "active".
            mLog("Reverse thrust engaged at " + ROUND(gspd, 0)
                + " m/s (AG" + PLANE_REVERSE_AG
                + " thr=" + PLANE_REVERSE_THROTTLE + ").").
            HUDTEXT("REVERSE THRUST", 3, 2, 15, YELLOW, FALSE).
        }
    } ELSE IF _revState = "active" {
        LOCAL reason IS "".
        IF NOT onGround { SET reason TO "airborne again". }
        ELSE IF NOT BRAKES { SET reason TO "brakes released". }
        ELSE IF gspd < PLANE_BRAKE_STOP_SPEED { SET reason TO "stopped". }
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
    LOCAL clamp IS PLANE_CTRL_DAMPING * auth.

    IF wptNavActive AND wptIndex < wptList:LENGTH {
        LOCAL wp IS wptList[wptIndex].
        LOCAL geo IS LATLNG(wp["lat"], wp["lng"]).
        IF geo:DISTANCE < PLANE_WPT_RADIUS {
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
        LOCAL maxBank IS PLANE_HDG_MAX_BANK.
        LOCAL bankTgt IS PLANE_HDG_BANK_SIGN
            * MAX(-maxBank, MIN(maxBank,
                PLANE_HDG_BANK_PER_DEG * hdgError)).
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
        LOCAL vsTarget IS MAX(-PLANE_ALT_MAX_VS,
            MIN(PLANE_ALT_MAX_VS,
                PLANE_ALT_VS_PER_M * (targetAlt - SHIP:ALTITUDE))).
        SET _altPid:SETPOINT TO vsTarget.
        LOCAL tgtPitch IS _altPid:UPDATE(TIME:SECONDS, SHIP:VERTICALSPEED).
        LOCAL aoa IS VANG(SHIP:VELOCITY:SURFACE, SHIP:FACING:FOREVECTOR).
        IF aoa > PLANE_AOA_LIMIT AND tgtPitch > 0 {
            LOCAL aoaMargin IS PLANE_STALL_AOA - aoa.
            IF aoaMargin < 0 { SET aoaMargin TO 0. }
            SET tgtPitch TO tgtPitch
                * aoaMargin / (PLANE_STALL_AOA - PLANE_AOA_LIMIT).
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
    IF NOT PLANE_PID_CTRL {
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
        IF NOT waypointUseSelected(CRUISE_ALT) {
            mLog("No waypoints loaded and no selected waypoint found.").
            HUDTEXT("Select waypoint first", 3, 2, 14, RED, FALSE).
            RETURN.
        }
    }
    IF PLANE_PID_CTRL AND NOT apActive { apOn(). }
    SET wptIndex TO 0.
    SET wptNavActive TO TRUE.
    LOCAL wp IS wptList[0].
    IF PLANE_PID_CTRL {
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
    PARAMETER alt_ IS CRUISE_ALT.
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
    LOCAL stopSpd IS PLANE_BRAKE_STOP_SPEED.

    mLog("Landing assist: brakes on, throttle zero.").
    LOCK THROTTLE TO 0.
    SET BRAKES TO TRUE.

    IF PLANE_REVERSE_AUTO {
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
        LOCAL revDelay IS PLANE_REVERSE_THRUST_DELAY.
        mLog("Waiting " + revDelay + "s for reverse thrust.").
        WAIT revDelay.
        _reverseSet(TRUE).
        mLog("Reverse thrust AG" + PLANE_REVERSE_AG + " engaged.").
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
    PARAMETER laneLength IS PLANE_SURVEY_LANE_LENGTH.

    LOCAL survAlt IS PLANE_SURVEY_ALT.
    LOCAL spacing IS PLANE_SURVEY_SPACING.

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
//
// NOTE: kOS has two trim layers. The settable SHIP:CONTROL:*TRIM is
// kOS's own; the SHIP:CONTROL:PILOT*TRIM layer (keyboard Mod+arrows,
// joystick trim) is read-only — kOS can SEE it but cannot clear it.
// The old code wrote to PILOT*TRIM, which silently did nothing. We
// zero our own layer and, if a pilot trim is left standing (the usual
// cause of post-reboot yaw/pitch drift), tell the operator to press
// the in-game Reset Trim key (Mod+X) — only that clears it.
GLOBAL FUNCTION planePreflightReset {
    SET SHIP:CONTROL:PITCHTRIM TO 0.
    SET SHIP:CONTROL:YAWTRIM TO 0.
    SET SHIP:CONTROL:ROLLTRIM TO 0.
    SET SHIP:CONTROL:NEUTRALIZE TO TRUE.
    // boot.ks forces SAS on — right for a rocket on the pad, wrong for
    // a plane: the cockpit reaction wheel then holds heading and fights
    // the rudder, "sticking" the yaw. Planes fly on aero controls + our
    // PID assists, so start every leg SAS-off. boot.ks can't be patched
    // remotely; this lib re-syncs, so the override lives here.
    SET SAS TO FALSE.
    _reverseSet(FALSE).
    SET _revState TO "idle".
    SET BRAKES TO TRUE.

    LOCAL pTrim IS ABS(SHIP:CONTROL:PILOTYAWTRIM)
        + ABS(SHIP:CONTROL:PILOTPITCHTRIM)
        + ABS(SHIP:CONTROL:PILOTROLLTRIM).
    IF pTrim > 0.01 {
        mLogWarn("STATS preflight pilotTrim yaw="
            + ROUND(SHIP:CONTROL:PILOTYAWTRIM, 3)
            + " pitch=" + ROUND(SHIP:CONTROL:PILOTPITCHTRIM, 3)
            + " roll=" + ROUND(SHIP:CONTROL:PILOTROLLTRIM, 3)
            + " — press Mod+X (kOS cannot clear pilot trim).").
        HUDTEXT("PILOT TRIM SET — press Mod+X to reset",
            6, 2, 16, YELLOW, FALSE).
    }
    mLog("Preflight reset: kOS trims zeroed, SAS off, reversers "
        + "stowed, throttle idle, brakes hold.").
}

GLOBAL FUNCTION planePreflightChecklist {
    PARAMETER craftName.
    PARAMETER items.

    planePreflightReset().

    LOCAL envRows IS LIST(
        "Airspeed .... " + ROUND(SHIP:AIRSPEED,1) + " m/s",
        "Heading ..... " + ROUND(SHIP:FACING:YAW,1) + " deg",
        "Stall speed . " + PLANE_STALL_SPEED + " m/s",
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
    // COS(lat0) -> 0 at the poles would blow up the longitude step;
    // floor it (~89.4 deg) so a high-latitude lane projects sanely.
    LOCAL cosLat IS MAX(COS(lat0), 0.01).
    LOCAL degPerM IS CONSTANT:RADTODEG / r_.
    LOCAL dlat IS dist * COS(brng) * degPerM.
    LOCAL dlng IS dist * SIN(brng) * degPerM / cosLat.
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
// POSTFLIGHT handlers. Craft scripts now reduce to globals + a call:
//
//   GLOBAL FUNCTION main {
//       airplaneMain("FJ1A", LEXICON("checklist", LIST(...))).
//   }
//
// opts (all optional):
//   "defaultSeq"    LIST     — fallback when no mission SEQUENCE
//   "checklist"     LIST     — preflight checklist items
//   "configure"     delegate — assist-tuning hook, runs at each phase
//   "configRows"    delegate — extra flightPlan rows for the brief
//   "phases"        LEXICON  — extra/override phase handlers
//   "landingAssist" bool     — run planeLandingAssist (default TRUE)
//
// Per-craft behavior comes from globals instead of bespoke handlers:
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

LOCAL FUNCTION _amConfigure {
    IF _amOpts:HASKEY("configure") { _amOpts["configure"]:CALL(). }
}

LOCAL FUNCTION _amOnGround {
    RETURN SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
}

LOCAL FUNCTION _amFlying {
    IF SHIP:STATUS = "SUB_ORBITAL" OR SHIP:STATUS = "ORBITING" { RETURN TRUE. }
    RETURN SHIP:STATUS = "FLYING"
        AND ALT:RADAR > AIRBORNE_RADAR_ALT.
}

LOCAL FUNCTION _amFinalLanding {
    PARAMETER airborneTime.
    IF NOT _amOnGround() { RETURN FALSE. }
    IF TIME:SECONDS - airborneTime < MIN_FLIGHT_TIME {
        RETURN FALSE.
    }
    RETURN SHIP:AIRSPEED <= FINAL_LANDING_SPEED.
}

LOCAL FUNCTION _amPrintConfig {
    flightPlanTitle(_amName + " FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("CRUISE").
    flightPlanRow("ALT", CRUISE_ALT + " m").
    flightPlanRow("SPEED", CRUISE_SPEED + " m/s").
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

    WAIT UNTIL _amFlying() OR SHIP:AIRSPEED > AIRBORNE_SPEED.
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

    // Mission profile values override the craft's global defaults
    // (rocket craft do this at script load; planes do it here).
    applyKnownMissionState().

    LOCAL defaultSeq IS LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "DONE").
    IF opts:HASKEY("defaultSeq") { SET defaultSeq TO opts["defaultSeq"]. }
    SET _amSeq TO defaultSeq.
    IF SEQUENCE:LENGTH > 0 {
        SET _amSeq TO phaseList(SEQUENCE).
    }
    SET launchSeq TO _amSeq.
    SET xferSeq TO _amSeq.

    SET _amHasScience TO missionHasPayload("SCIENCE").

    mLogPhase(craftName + " MAIN").
    mLog("Target: " + getTarget() + "  Payloads: " + PAYLOADS).
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

// Airplane phases normally dispatch through airplaneMain's local map.
// These fallbacks keep generated dependency binding operator-friendly.
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
