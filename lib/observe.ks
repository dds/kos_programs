// ============================================================
// observe.ks  —  Periodic telemetry logger  (0:/lib/observe.ks)
//
// Streams telemetry STRAIGHT TO THE ARCHIVE when a KSC link is
// up (0:/logs/obs/<ship>_<launchtime>.log, append-style like
// archiveLog), so the data survives instead of dying unread in
// 1:/run when the local volume gets cleaned. Without a link
// (Island Airfield legs, far side of the Mun) lines buffer in
// 1:/run and flush to the archive at the next connected entry.
//
// Local storage is only consumed while offline, so MIN_FREE only
// gates the offline buffer — a connected session can log at 1s
// intervals indefinitely (used by cmd/airtest.ks for PID work).
// ============================================================

GLOBAL OBS_CFG IS LEXICON(
    "INTERVAL",   120,
    "MIN_FREE",  2000,
    "STOP_FILE", "1:/run/obs_off"
).

GLOBAL obsActive IS FALSE.
LOCAL  obsBufferPath IS "".
LOCAL  obsArchivePath IS "".
LOCAL  obsNextTime IS 0.

GLOBAL FUNCTION observeStart {
    IF EXISTS(OBS_STOP_FILE) { DELETEPATH(OBS_STOP_FILE). }
    LOCAL safeName IS SHIP:NAME:REPLACE(" ","_").
    LOCAL ts IS ROUND(stateGetNum("launch_time", 0)).
    IF ts = 0 { SET ts TO ROUND(TIME:SECONDS). }
    SET obsBufferPath TO "1:/run/obs_" + safeName + "_" + ts + ".log".
    SET obsArchivePath TO "0:/logs/obs/" + safeName + "_" + ts + ".log".
    SET obsActive TO TRUE.
    SET obsNextTime TO TIME:SECONDS.
    _observeLog().
    SET obsNextTime TO TIME:SECONDS + OBS_INTERVAL.
    mLog("Observation started: " + obsArchivePath).
    PRINT " ".
    PRINT "  -- OBSERVATION ACTIVE --".
    PRINT "  Archive ... " + obsArchivePath.
    PRINT "  Offline ... buffers to " + obsBufferPath.
    PRINT "  Interval .. every " + OBS_INTERVAL + "s".
    PRINT "  Tracking .. spd gspd alt vs hdg pit rol thr".
    IF planeActive {
        PRINT "            + auth wlev/ahld/hhld/shld + ctrl/targets".
    }
    PRINT "  Auto-stop . abort, low offline storage, sentinel file".
    PRINT " ".
    WHEN obsActive THEN {
        IF EXISTS(OBS_STOP_FILE) {
            SET obsActive TO FALSE.
            mLog("Observation stopped (sentinel file).").
            RETURN.
        }
        IF TIME:SECONDS >= obsNextTime {
            _observeLog().
            SET obsNextTime TO TIME:SECONDS + OBS_INTERVAL.
        }
        PRESERVE.
    }
}

GLOBAL FUNCTION observeStop {
    LOG "" TO OBS_STOP_FILE.
    IF obsActive {
        _observeLog().
        SET obsActive TO FALSE.
        mLog("Observation stopped (manual).").
    }
}

// Flush any offline buffer to the archive, then delete it.
LOCAL FUNCTION _observeFlushBuffer {
    IF NOT EXISTS(obsBufferPath) { RETURN. }
    LOCAL raw IS OPEN(obsBufferPath):READALL:STRING.
    FOR bufLine IN raw:SPLIT(CHAR(10)) {
        LOCAL clean IS bufLine:REPLACE(CHAR(13), "").
        IF clean <> "" { LOG clean TO obsArchivePath. }
    }
    DELETEPATH(obsBufferPath).
    mLog("Observation buffer flushed to archive.").
}

LOCAL FUNCTION _observeWrite {
    PARAMETER line.
    IF HOMECONNECTION:ISCONNECTED {
        IF NOT EXISTS("0:/logs") { CREATEDIR("0:/logs"). }
        IF NOT EXISTS("0:/logs/obs") { CREATEDIR("0:/logs/obs"). }
        _observeFlushBuffer().
        LOG line TO obsArchivePath.
        RETURN.
    }
    // Offline: buffer locally, but never eat the volume.
    IF CORE:VOLUME:FREESPACE < OBS_MIN_FREE {
        LOG "" TO OBS_STOP_FILE.
        SET obsActive TO FALSE.
        mLog("Observation stopped (low storage, offline).").
        RETURN.
    }
    LOG line TO obsBufferPath.
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
        + " thr=" + ROUND(SHIP:CONTROL:PILOTMAINTHROTTLE,2).
    IF planeActive {
        // Tuning fields: mode flags, commanded surface outputs, and
        // the live targets, so PID response is readable from the log.
        SET line TO line
            + " auth=" + ROUND(planeCtrlAuthority(),2)
            + " wlev=" + wingLevelerActive
            + " ahld=" + altHoldActive
            + " hhld=" + hdgHoldActive
            + " shld=" + spdHoldActive
            + " cp=" + ROUND(SHIP:CONTROL:PITCH,3)
            + " cr=" + ROUND(SHIP:CONTROL:ROLL,3)
            + " tAlt=" + ROUND(targetAlt,0)
            + " tHdg=" + ROUND(targetHdg,1)
            + " tSpd=" + ROUND(targetSpd,1).
    }
    _observeWrite(line).
}
