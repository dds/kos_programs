// ============================================================
// logs.ks  —  Logging library  (0:/lib/logs.ks)
//
// Log file is created ONCE per mission. Path is persisted in
// 1:/state/state.json via the state lib so reboots reopen the
// same file rather than creating a new one.
//
// Depends on: state.ks (stateGet / stateSet) — load that first.
// ============================================================

GLOBAL flightLogPath IS "".

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

LOCAL FUNCTION _newLogPath {
    PARAMETER logPathFile.
    LOCAL safeName IS _sanitizeName(SHIP:NAME).
    LOCAL p IS "1:/logs/" + safeName + "_" + ROUND(TIME:SECONDS) + ".log".
    LOG "=== FAULT LOG START: " + SHIP:NAME + " ===" TO p.
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

GLOBAL FUNCTION mLog {
    PARAMETER message.
    PARAMETER level IS "INFO".
    LOCAL line IS "[" + ROUND(TIME:SECONDS,1) + "][" + level + "] " + message.
    PRINT line.

    // Persist warnings and errors to fault log only
    IF level = "WARN" OR level = "ERROR" OR level = "PHASE" {
        IF flightLogPath <> "" AND CORE:VOLUME:FREESPACE > 500 {
            LOG line TO flightLogPath.
        }
    }
}

GLOBAL FUNCTION mLogWarn  { PARAMETER m. mLog(m, "WARN").  }
GLOBAL FUNCTION mLogError { PARAMETER m. mLog(m, "ERROR"). }
GLOBAL FUNCTION mLogPhase {
    PARAMETER m.
    LOCAL sep IS "=== PHASE: " + m + " ===".
    mLog(sep, "PHASE").
}