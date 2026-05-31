// ============================================================
// logs.ks  —  Flight logging  (0:/lib/logs.ks)
// ============================================================
LOCAL FUNCTION _loadLib {
    PARAMETER libName.
    RUNONCEPATH("1:/lib/" + libName + ".ks").
}

GLOBAL FUNCTION flightLogPath {
    LOCAL launchT IS ROUND(stateGetNum("launch_time", 0)).
    IF launchT = 0 { SET launchT TO ROUND(TIME:SECONDS). }
    LOCAL baseId IS "{0}_{1}":FORMAT(slug(), launchT).

    LOCAL logPathFile IS "1:/state/log_path.state".
    LOCAL _flightLogPath IS "".
    IF EXISTS(logPathFile) {
        SET _flightLogPath TO OPEN(logPathFile):READALL:STRING:TRIM.
    }
    IF _flightLogPath = "" {
        SET _flightLogPath TO _logPath().
        LOG "=== FAULT LOG START: " + logId() + " ===" TO p.
        LOG _flightLogPath TO logPathFile.
    }
    RETURN _flightLogPath.
}

GLOBAL FUNCTION initLog {
    mLog("Fault log: " + flightLogPath()).
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
    LOCAL baseId IS slug().
    
    LOCAL isEVA IS SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA").
    IF isEVA {
        // TODO: support multiple EVAs.
        RETURN baseId + "_EVA".
    }

    RETURN baseId.
}

LOCAL FUNCTION _logPath {
    RETURN "1:/logs/" + logId().
}

GLOBAL FUNCTION archiveLog {
    LOCAL launchT IS ROUND(stateGetNum("launch_time", 0)).
    IF launchT = 0 { SET launchT TO ROUND(TIME:SECONDS). }
    LOCAL shipDir IS "0:/logs/archive/" + SHIP:NAME + "_" + launchT.
    IF NOT EXISTS("0:/logs/archive") { CREATEDIR("0:/logs/archive"). }
    IF NOT EXISTS(shipDir) { CREATEDIR(shipDir). }
    COPYPATH(flightLogPath(), shipDir + "/" + logId()).
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

    IF flightLogPath() <> "" AND CORE:VOLUME:FREESPACE > 500 {
        LOG line TO flightLogPath().
    }
}

GLOBAL FUNCTION mLogWarn  { PARAMETER m. mLog(m, "WARN").  }
GLOBAL FUNCTION mLogError { PARAMETER m. mLog(m, "ERROR"). }
GLOBAL FUNCTION mLogPhase {
    PARAMETER m.
    LOCAL sep IS "=== PHASE: " + m + " ===".
    mLog(sep, "PHASE").
}
