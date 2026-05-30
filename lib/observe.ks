// ============================================================
// observe.ks  —  Periodic telemetry logger  (0:/lib/observe.ks)
// ============================================================

GLOBAL OBS_CFG IS LEXICON(
    "INTERVAL",   120,
    "MIN_FREE",  2000,
    "STOP_FILE", "1:/state/obs_off"
).

GLOBAL obsActive IS FALSE.
LOCAL  obsLogPath IS "".
LOCAL  obsNextTime IS 0.

GLOBAL FUNCTION observeStart {
    IF EXISTS(OBS_CFG["STOP_FILE"]) { DELETEPATH(OBS_CFG["STOP_FILE"]). }
    LOCAL ts IS ROUND(TIME:SECONDS).
    LOCAL safeName IS SHIP:NAME:REPLACE(" ","_").
    SET obsLogPath TO "1:/logs/obs_" + safeName + "_" + ts + ".log".
    SET obsActive TO TRUE.
    SET obsNextTime TO TIME:SECONDS.
    _observeLog().
    SET obsNextTime TO TIME:SECONDS + OBS_CFG["INTERVAL"].
    mLog("Observation started: " + obsLogPath).
    WHEN obsActive THEN {
        IF EXISTS(OBS_CFG["STOP_FILE"]) {
            SET obsActive TO FALSE.
            mLog("Observation stopped (sentinel file).").
            RETURN.
        }
        IF CORE:VOLUME:FREESPACE < OBS_CFG["MIN_FREE"] {
            LOG "" TO OBS_CFG["STOP_FILE"].
            SET obsActive TO FALSE.
            mLog("Observation stopped (low storage).").
            RETURN.
        }
        IF TIME:SECONDS >= obsNextTime {
            _observeLog().
            SET obsNextTime TO TIME:SECONDS + OBS_CFG["INTERVAL"].
        }
        PRESERVE.
    }
}

GLOBAL FUNCTION observeStop {
    LOG "" TO OBS_CFG["STOP_FILE"].
    IF obsActive {
        _observeLog().
        SET obsActive TO FALSE.
        mLog("Observation stopped (manual).").
    }
}

LOCAL FUNCTION _observeLog {
    LOCAL line IS "T=" + ROUND(TIME:SECONDS,1)
        + " spd=" + ROUND(SHIP:AIRSPEED,1)
        + " gspd=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " alt=" + ROUND(SHIP:ALTITUDE,0)
        + " vs=" + ROUND(SHIP:VERTICALSPEED,1)
        + " hdg=" + ROUND(SHIP:FACING:YAW,1)
        + " pit=" + ROUND(SHIP:FACING:PITCH,1)
        + " rol=" + ROUND(SHIP:FACING:ROLL,1)
        + " thr=" + ROUND(SHIP:CONTROL:PILOTMAINTHROTTLE,2)
        + " free=" + CORE:VOLUME:FREESPACE.
    IF planeActive {
        LOCAL auth IS MAX(PLANE_CFG["FBW_MIN_AUTH"],
            MIN(PLANE_CFG["FBW_MAX_AUTH"],
                PLANE_CFG["FBW_REF_SPEED"] / MAX(SHIP:AIRSPEED, 1))).
        SET line TO line
            + " auth=" + ROUND(auth,2)
            + " wbrk=" + ROUND(SHIP:CONTROL:WHEELBRAKES,2)
            + " wstr=" + ROUND(SHIP:CONTROL:WHEELSTEER,2)
            + " wlev=" + wingLevelerActive
            + " ahld=" + altHoldActive
            + " hhld=" + hdgHoldActive.
    }
    LOG line TO obsLogPath.
}
