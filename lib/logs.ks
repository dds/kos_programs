// ============================================================
// logs.ks  —  Flight logging  (0:/lib/logs.ks)
// ============================================================

DECLARE GLOBAL flightLogPath IS "".

GLOBAL FUNCTION initLog {
    LOCAL logPathFile IS "1:/state/log_path.state".
    IF EXISTS(logPathFile) {
        SET flightLogPath TO OPEN(logPathFile):READALL:STRING:TRIM.
        IF flightLogPath = "" { SET flightLogPath TO _newLogPath(logPathFile). }
    } ELSE {
        SET flightLogPath TO _newLogPath(logPathFile).
    }
    mLog("Fault log: " + flightLogPath).
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
    IF launchT = 0 { SET launchT TO ROUND(TIME:SECONDS). }

    LOCAL baseId IS "{0}_{1}":FORMAT(slug(), launchT).
    
    LOCAL isEVA IS SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA").
    IF isEVA {
        // TODO: support multiple EVAs.
        RETURN baseId + "_EVA".
    }

    RETURN baseId.
}

LOCAL FUNCTION _newLogPath {
    PARAMETER logPathFile.
    LOCAL p IS "1:/logs/" + logId().
    LOG "=== FAULT LOG START: " + logId() + " ===" TO p.
    LOG p TO logPathFile.
    RETURN p.
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

    IF flightLogPath <> "" AND CORE:VOLUME:FREESPACE > 500 {
        LOG line TO flightLogPath.
    }
}

GLOBAL FUNCTION mLogWarn  { PARAMETER m. mLog(m, "WARN").  }
GLOBAL FUNCTION mLogError { PARAMETER m. mLog(m, "ERROR"). }
GLOBAL FUNCTION mLogPhase {
    PARAMETER m.
    LOCAL sep IS "=== PHASE: " + m + " ===".
    mLog(sep, "PHASE").
}
