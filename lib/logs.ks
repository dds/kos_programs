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
    LOCAL persisted IS stateGet("log_path").
    IF persisted <> "" AND EXISTS(persisted) {
        // Reopen existing log
        SET flightLogPath TO persisted.
        mLog("Log reopened after reboot: " + flightLogPath).
    } ELSE {
        // First time — create new log file
        LOCAL safeName IS _sanitizeName(SHIP:NAME).
        SET flightLogPath TO "1:/logs/" + safeName + "_" + ROUND(TIME:SECONDS) + ".log".
        LOG "=== LOG START: " + SHIP:NAME + " ===" TO flightLogPath.
        stateSet("log_path", flightLogPath).
        mLog("Log created: " + flightLogPath).
    }
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
    IF flightLogPath <> "" { LOG line TO flightLogPath. }
}

GLOBAL FUNCTION mLogWarn  { PARAMETER m. mLog(m, "WARN").  }
GLOBAL FUNCTION mLogError { PARAMETER m. mLog(m, "ERROR"). }
GLOBAL FUNCTION mLogPhase {
    PARAMETER m.
    LOCAL sep IS "=== PHASE: " + m + " ===".
    mLog(sep, "PHASE").
}