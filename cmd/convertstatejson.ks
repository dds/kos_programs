// cmd/convertstatejson.ks - Convert legacy SimpleJSON state to native kOS JSON.
// Usage: RUNPATH("0:/cmd/convertstatejson.ks").
//
// Standalone by design: do not bootPreamble() here. The whole point is to
// repair 1:/run/state.json before the normal state loader reads it.

PARAMETER statePath IS "1:/run/state.json".
PARAMETER backupPath IS "1:/run/state.simplejson.bak".

LOCAL FUNCTION _looksNumeric {
    PARAMETER value.
    IF value:TYPENAME <> "STRING" { RETURN FALSE. }
    LOCAL s IS value:TRIM.
    IF s = "" { RETURN FALSE. }

    LOCAL idx IS 0.
    LOCAL sawDigit IS FALSE.
    LOCAL sawDot IS FALSE.
    IF s:SUBSTRING(0, 1) = "-" {
        SET idx TO 1.
        IF s:LENGTH = 1 { RETURN FALSE. }
    }

    UNTIL idx >= s:LENGTH {
        LOCAL ch IS s:SUBSTRING(idx, 1).
        IF ch = "." {
            IF sawDot { RETURN FALSE. }
            SET sawDot TO TRUE.
        } ELSE IF "0123456789":CONTAINS(ch) {
            SET sawDigit TO TRUE.
        } ELSE {
            RETURN FALSE.
        }
        SET idx TO idx + 1.
    }

    RETURN sawDigit.
}

LOCAL FUNCTION _nativeValue {
    PARAMETER value.
    IF _looksNumeric(value) { RETURN value:TONUMBER(0). }
    RETURN value.
}

IF NOT EXISTS("1:/run") { CREATEDIR("1:/run"). }

IF NOT EXISTS(statePath) {
    PRINT "No state file at " + statePath + ".".
} ELSE {
    LOCAL raw IS OPEN(statePath):READALL:STRING.
    LOCAL oldState IS LEXICON().
    IF raw:TRIM <> "" {
        SET oldState TO ADDONS:JSON:PARSE(raw).
    }

    LOCAL newState IS LEXICON().
    LOCAL converted IS 0.
    FOR key IN oldState:KEYS {
        LOCAL oldValue IS oldState[key].
        LOCAL newValue IS _nativeValue(oldValue).
        IF oldValue:TYPENAME = "STRING" AND newValue:ISTYPE("Scalar") {
            SET converted TO converted + 1.
        }
        newState:ADD(key, newValue).
    }

    IF EXISTS(backupPath) { DELETEPATH(backupPath). }
    LOG raw TO backupPath.
    IF EXISTS(statePath) { DELETEPATH(statePath). }
    WRITEJSON(newState, statePath).

    PRINT "Converted " + statePath + " to native WRITEJSON format.".
    PRINT "Backup: " + backupPath + ".".
    PRINT "Numeric strings converted: " + converted + ".".
}
