// ============================================================
// plane.ks  —  Aircraft autopilot library  (0:/lib/plane.ks)
// ============================================================

GLOBAL PLANE_CFG IS LEXICON(
    "ROLL_KP",          0.02,
    "ROLL_DEADBAND",     1.0,
    "ALT_KP",           0.003,
    "ALT_DEADBAND",      10,
    "ALT_MAX_PITCH",      8,
    "ALT_MIN_PITCH",     -6,
    "HDG_KP",           0.03,
    "HDG_DEADBAND",      1.0,
    "STALL_SPEED",       60,
    "STALL_AOA",         20,
    "SURVEY_ALT",      2000,
    "SURVEY_SPACING",  500,
    "SURVEY_SPEED",    150
).

GLOBAL planeActive      IS FALSE.
GLOBAL wingLevelerActive IS FALSE.
GLOBAL altHoldActive    IS FALSE.
GLOBAL hdgHoldActive    IS FALSE.
GLOBAL targetAlt        IS 0.
GLOBAL targetHdg        IS 0.

GLOBAL FUNCTION planeInit {
    SET planeActive TO TRUE.
    mLog("Plane autopilot ready. Modes: off. Stall speed="
        + PLANE_CFG["STALL_SPEED"] + "m/s").
    HUDTEXT("Plane autopilot ready", 3, 2, 13, GREEN, FALSE).

    WHEN planeActive AND SHIP:AIRSPEED < PLANE_CFG["STALL_SPEED"]
            AND SHIP:ALTITUDE < 70000 THEN {
        HUDTEXT("STALL WARNING — " + ROUND(SHIP:AIRSPEED,0) + "m/s", 2, 2, 16, RED, FALSE).
        mLog("Stall warning: airspeed=" + ROUND(SHIP:AIRSPEED,0) + "m/s").
        PRESERVE.
    }
}

GLOBAL FUNCTION planeShutdown {
    wingLevelerOff().
    altHoldOff().
    hdgHoldOff().
    UNLOCK STEERING.
    SET planeActive TO FALSE.
    mLog("Plane autopilot shutdown.").
}

GLOBAL FUNCTION wingLevelerOn {
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
    PARAMETER alt IS SHIP:ALTITUDE.
    SET targetAlt TO alt.
    SET altHoldActive TO TRUE.
    mLog("Altitude hold ON at " + ROUND(alt,0) + "m.").
    HUDTEXT("Alt hold ON: " + ROUND(alt,0) + "m", 2, 2, 13, CYAN, FALSE).
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

GLOBAL FUNCTION planeUpdate {
    IF NOT planeActive { RETURN. }

    IF wingLevelerActive {
        LOCAL roll IS SHIP:FACING:ROLL.
        IF ABS(roll) > PLANE_CFG["ROLL_DEADBAND"] {
            LOCAL correction IS -roll * PLANE_CFG["ROLL_KP"].
            SET SHIP:CONTROL:ROLL TO MAX(-0.3, MIN(0.3, correction)).
        } ELSE {
            SET SHIP:CONTROL:ROLL TO 0.
        }
    }

    IF altHoldActive {
        LOCAL altError IS targetAlt - SHIP:ALTITUDE.
        IF ABS(altError) > PLANE_CFG["ALT_DEADBAND"] {
            LOCAL pitchCorr IS altError * PLANE_CFG["ALT_KP"].
            SET pitchCorr TO MAX(PLANE_CFG["ALT_MIN_PITCH"],
                             MIN(PLANE_CFG["ALT_MAX_PITCH"], pitchCorr)).
            LOCAL currentPitch IS SHIP:FACING:PITCH.
            LOCAL pitchErr IS pitchCorr - currentPitch.
            SET SHIP:CONTROL:PITCH TO MAX(-0.3, MIN(0.3, pitchErr * 0.05)).
        } ELSE {
            SET SHIP:CONTROL:PITCH TO 0.
        }
    }

    IF hdgHoldActive {
        LOCAL hdgError IS targetHdg - SHIP:FACING:YAW.
        IF hdgError > 180  { SET hdgError TO hdgError - 360. }
        IF hdgError < -180 { SET hdgError TO hdgError + 360. }
        IF ABS(hdgError) > PLANE_CFG["HDG_DEADBAND"] {
            LOCAL correction IS hdgError * PLANE_CFG["HDG_KP"].
            SET SHIP:CONTROL:YAW TO MAX(-0.3, MIN(0.3, correction)).
        } ELSE {
            SET SHIP:CONTROL:YAW TO 0.
        }
    }
}

GLOBAL FUNCTION surveyStart {
    PARAMETER startLat.
    PARAMETER startLng.
    PARAMETER heading.
    PARAMETER laneCount IS 4.

    mLog("Survey start: " + laneCount + " lanes  hdg=" + heading
        + "  alt=" + PLANE_CFG["SURVEY_ALT"] + "m").
    HUDTEXT("Survey mode active", 3, 2, 14, CYAN, FALSE).

    altHoldOn(SHIP:ALTITUDE).
    hdgHoldOn(heading).

    LOCAL lane IS 0.
    UNTIL lane >= laneCount {
        mLog("Survey lane " + (lane+1) + " of " + laneCount).
        HUDTEXT("Survey lane " + (lane+1) + "/" + laneCount, 3, 2, 13, CYAN, FALSE).

        LOCAL laneStart IS TIME:SECONDS.
        UNTIL TIME:SECONDS > laneStart + 60 {
            planeUpdate().
            WAIT 0.05.
        }

        IF lane < laneCount - 1 {
            LOCAL newHdg IS heading + 90.
            IF newHdg >= 360 { SET newHdg TO newHdg - 360. }
            hdgHoldOn(newHdg).
            WAIT 10.
            hdgHoldOn(heading + 180).
            WAIT 5.
            hdgHoldOn(heading).
        }
        SET lane TO lane + 1.
    }

    mLog("Survey complete.").
    HUDTEXT("Survey complete", 3, 2, 14, GREEN, FALSE).
    altHoldOff().
    hdgHoldOff().
}

GLOBAL FUNCTION planeStatus {
    mLog("Plane status:"
        + " airspeed=" + ROUND(SHIP:AIRSPEED,0) + "m/s"
        + " alt=" + ROUND(SHIP:ALTITUDE,0) + "m"
        + " hdg=" + ROUND(SHIP:FACING:YAW,0) + "deg"
        + " pitch=" + ROUND(SHIP:FACING:PITCH,1) + "deg"
        + " roll=" + ROUND(SHIP:FACING:ROLL,1) + "deg"
        + " wingLeveler=" + wingLevelerActive
        + " altHold=" + altHoldActive
        + " hdgHold=" + hdgHoldActive).
}
