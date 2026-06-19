// ============================================================
// logs.ks  —  Flight logging  (0:/lib/logs.ks)
// ============================================================
LOCAL FUNCTION _logPath {
    LOCAL flightDir IS localFlightLogDir().
    IF NOT EXISTS(flightDir) { CREATEDIR(flightDir). }
    RETURN flightDir + "/" + bootLogName().
}

GLOBAL FUNCTION flightLogPath {
    LOCAL path_ IS _logPath().
    IF NOT EXISTS(path_) {
        LOG "=== BOOT LOG START: " + logId() + " ===" TO path_.
    }
    RETURN path_.
}

GLOBAL FUNCTION codeVersion {
    IF NOT EXISTS("1:/run") { CREATEDIR("1:/run"). }
    LOCAL versionPath IS "1:/run/code_version.state".
    IF EXISTS(versionPath) {
        RETURN OPEN(versionPath):READALL:STRING:TRIM.
    }
    IF HOMECONNECTION:ISCONNECTED AND EXISTS("0:/VERSION") {
        RETURN OPEN("0:/VERSION"):READALL:STRING:TRIM.
    }
    RETURN "unknown".
}

GLOBAL FUNCTION initLog {
    mLog("Boot log: " + flightLogPath()).
    mLog("CODE version=" + codeVersion(), "CODE").
}

GLOBAL FUNCTION flightSlug {
    LOCAL logName IS stateGet("vessel_name", "").
    IF logName = "" { SET logName TO SHIP:NAME. }
    RETURN _sanitizeName(logName).
}

GLOBAL FUNCTION coreSlug {
    LOCAL safeCoreTag IS _sanitizeName(CORE:TAG).
    IF safeCoreTag <> "" {
        RETURN safeCoreTag.
    }
    IF SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA") { RETURN "EVA". }
    RETURN "core".
}

GLOBAL FUNCTION slug {
    LOCAL safeName IS flightSlug().
    LOCAL safeCoreTag IS coreSlug().
    IF safeCoreTag <> "core" {
        RETURN "{0}_{1}":FORMAT(safeName, safeCoreTag).
    }
    RETURN safeName.
}

GLOBAL FUNCTION flightStamp {
    LOCAL launchT IS ROUND(stateGetNum("launch_time", 0)).
    IF launchT <> 0 {
        LOCAL launchStamp IS "" + launchT.
        IF stateGet("log_flight_stamp", "") <> launchStamp {
            stateSet("log_flight_stamp", launchStamp).
        }
        RETURN launchStamp.
    }

    LOCAL stored IS stateGet("log_flight_stamp", "").
    IF stored <> "" { RETURN stored. }

    IF launchT = 0 {
        SET launchT TO ROUND(TIME:SECONDS / 10, 0) * 10.
    }
    SET stored TO "" + launchT.
    stateSet("log_flight_stamp", stored).
    RETURN stored.
}

GLOBAL FUNCTION flightLogId {
    RETURN "{0}_{1}":FORMAT(flightSlug(), flightStamp()).
}

GLOBAL FUNCTION bootLogNumber {
    LOCAL bootNum IS stateGetNum("boot_log_count", 0).
    IF bootNum = 0 { SET bootNum TO stateGetNum("boot_count", 0). }
    IF bootNum = 0 { SET bootNum TO 1. }
    RETURN bootNum.
}

LOCAL FUNCTION _pad3 {
    PARAMETER n.
    LOCAL out IS "" + n.
    UNTIL out:LENGTH >= 3 {
        SET out TO "0" + out.
    }
    RETURN out.
}

GLOBAL FUNCTION bootLogName {
    RETURN "boot_" + _pad3(bootLogNumber()) + "_" + coreSlug() + ".log".
}

GLOBAL FUNCTION localFlightLogDir {
    IF NOT EXISTS("1:/run") { CREATEDIR("1:/run"). }
    IF NOT EXISTS("1:/run/logs") { CREATEDIR("1:/run/logs"). }
    RETURN "1:/run/logs/" + flightLogId().
}

GLOBAL FUNCTION logId {
    LOCAL bootName IS bootLogName().
    RETURN flightLogId() + "_" + bootName:SUBSTRING(0, bootName:LENGTH - 4).
}

GLOBAL FUNCTION archiveLog {
    IF NOT HOMECONNECTION:ISCONNECTED {
        RETURN FALSE.
    }
    LOCAL shipDir IS "0:/logs/archive/" + flightLogId().
    IF NOT EXISTS("0:/logs") { CREATEDIR("0:/logs"). }
    IF NOT EXISTS("0:/logs/archive") { CREATEDIR("0:/logs/archive"). }
    IF NOT EXISTS(shipDir) { CREATEDIR(shipDir). }

    LOCAL localPath IS flightLogPath().
    IF localPath = "" OR NOT EXISTS(localPath) { RETURN FALSE. }

    LOCAL archivePath IS shipDir + "/" + bootLogName().
    LOCAL raw IS OPEN(localPath):READALL:STRING.
    IF raw:TRIM = "" { RETURN FALSE. }

    IF EXISTS(archivePath) {
        DELETEPATH(archivePath).
    }
    COPYPATH(localPath, archivePath).
    RETURN TRUE.
}

LOCAL FUNCTION _sanitizeName {
    PARAMETER raw.
    LOCAL out IS "".
    LOCAL i IS 0.
    UNTIL i >= raw:LENGTH {
        LOCAL c IS raw:SUBSTRING(i,1).
        IF c:MATCHESPATTERN("[a-zA-Z0-9_\\-]") { SET out TO out + c. }
        ELSE IF c = " "                         { SET out TO out + "_". }
        SET i TO i + 1.
    }
    RETURN out.
}

LOCAL FUNCTION _fmtTime {
    LOCAL ts IS "" + ROUND(TIME:SECONDS, 1).
    IF NOT ts:CONTAINS(".") { SET ts TO ts + ".0". }
    RETURN ts.
}

GLOBAL FUNCTION mLog {
    PARAMETER message.
    PARAMETER level IS "INFO".
    LOCAL l IS level:SUBSTRING(0,1).
    LOCAL line IS l + _fmtTime() + " " + message.
    PRINT line.

    LOCAL wroteLocal IS FALSE.
    IF LEVEL <> "INFO" AND flightLogPath() <> "" AND CORE:VOLUME:FREESPACE > 150 {
        LOG line TO flightLogPath().
        SET wroteLocal TO TRUE.
    }

    IF wroteLocal AND level = "WARN" AND message:LENGTH >= 5
            AND message:SUBSTRING(0,5) = "STATS"
            AND HOMECONNECTION:ISCONNECTED {
        archiveLog().
    }
}

GLOBAL FUNCTION mLogWarn  { PARAMETER m. mLog(m, "WARN").  }
GLOBAL FUNCTION mLogError { PARAMETER m. mLog(m, "ERROR"). }
GLOBAL FUNCTION mLogPhase {
    PARAMETER m.
    LOCAL sep IS "=== PHASE: " + m + " ===".
    mLog(sep, "PHASE").
}
