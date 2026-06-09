// ============================================================
// logs.ks  —  Flight logging  (0:/lib/logs.ks)
// ============================================================
LOCAL FUNCTION _logPath {
    IF NOT EXISTS("1:/run") { CREATEDIR("1:/run"). }
    RETURN "1:/run/" + logId() + ".log".
}

GLOBAL FUNCTION flightLogPath {
    IF NOT EXISTS("1:/run") { CREATEDIR("1:/run"). }
    LOCAL logPathFile IS "1:/run/log_path.state".
    LOCAL _flightLogPath IS "".
    IF EXISTS(logPathFile) {
        SET _flightLogPath TO OPEN(logPathFile):READALL:STRING:TRIM.
    }
    IF _flightLogPath = "" {
        SET _flightLogPath TO _logPath().
        LOG "=== FAULT LOG START: " + logId() + " ===" TO _flightLogPath.
        LOG _flightLogPath TO logPathFile.
    }
    RETURN _flightLogPath.
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
    mLog("Fault log: " + flightLogPath()).
    mLog("CODE version=" + codeVersion(), "CODE").
}

GLOBAL FUNCTION slug {
    LOCAL safeName IS _sanitizeName(SHIP:NAME).
    LOCAL safeCoreTag IS _sanitizeName(CORE:TAG).
    IF safeCoreTag <> "" {
        RETURN "{0}_{1}":FORMAT(safeName, safeCoreTag).
    } 
    RETURN safeName.
}

GLOBAL FUNCTION logId {
    LOCAL launchT IS ROUND(stateGetNum("launch_time", 0)).
    IF launchT = 0 { 
        SET launchT TO ROUND(TIME:SECONDS / 10, 0) * 10. 
        stateSetNum("launch_time", launchT).
    }

    LOCAL baseId IS "{0}_{1}":FORMAT(slug(), launchT).
    
    LOCAL isEVA IS SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA").
    IF isEVA {
        // TODO: support multiple EVAs.
        RETURN baseId + "_EVA".
    }

    RETURN baseId.
}

GLOBAL FUNCTION archiveLog {
    IF NOT HOMECONNECTION:ISCONNECTED {
        RETURN FALSE.
    }
    LOCAL launchT IS ROUND(stateGetNum("launch_time", 0)).
    IF launchT = 0 { 
        PRINT "archiveLog: launch time is 0.".
        RETURN FALSE.
    }
    LOCAL shipDir IS "0:/logs/archive/" + SHIP:NAME + "_" + launchT.
    IF NOT EXISTS("0:/logs/archive") { CREATEDIR("0:/logs/archive"). }
    IF NOT EXISTS(shipDir) { CREATEDIR(shipDir). }

    LOCAL localPath IS flightLogPath().
    IF localPath = "" OR NOT EXISTS(localPath) { RETURN FALSE. }

    LOCAL archivePath IS shipDir + "/" + logId() + ".log".
    LOCAL raw IS OPEN(localPath):READALL:STRING.
    IF raw:TRIM = "" { RETURN FALSE. }

    IF NOT EXISTS(archivePath) {
        LOG "=== ARCHIVE LOG START: " + logId() + " ===" TO archivePath.
    }
    FOR line IN raw:SPLIT(CHAR(10)) {
        LOCAL clean IS line:REPLACE(CHAR(13), "").
        IF clean <> "" { LOG clean TO archivePath. }
    }

    DELETEPATH(localPath).
    LOG "=== LOCAL LOG ROTATED: " + ROUND(TIME:SECONDS,1) + " ===" TO localPath.
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
    LOCAL line IS "[" + _fmtTime() + "][" + level + "] " + message.
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
