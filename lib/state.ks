// ============================================================
// state.ks  —  Persistent mission state  (0:/lib/state.ks)
//
// Uses simplejson addon for clean JSON round-trips.
// Single file: 1:/state/state.json
// Survives reboots and quicksave/quickload.
//
// API:
//   stateInit()              — call once at boot
//   stateGet(key)            — returns string, "" if missing
//   stateGet(key, default)   — returns default if missing
//   stateGetNum(key)         — coerce to number
//   stateGetNum(key, default)
//   stateSet(key, value)     — string or number, flushes to disk
//   stateSetNum(key, value)  — alias, same behavior
//   stateDump()              — print all keys to console
// ============================================================

LOCAL STATE_PATH  IS "1:/state/state.json".
LOCAL _cache      IS LEXICON().

GLOBAL FUNCTION stateInit {
    IF EXISTS(STATE_PATH) {
        LOCAL raw IS OPEN(STATE_PATH):READALL:STRING:TRIM.
        IF raw <> "" {
            SET _cache TO ADDONS:JSON:PARSEORELSE(raw, LEXICON()).
            RETURN.
        }
    }
    SET _cache TO LEXICON().
    _flush().
}

GLOBAL FUNCTION stateGet {
    PARAMETER key.
    PARAMETER dflt IS "".
    IF _cache:HASKEY(key) { RETURN _cache[key]. }
    RETURN dflt.
}

GLOBAL FUNCTION stateGetNum {
    PARAMETER key.
    PARAMETER dflt IS 0.
    IF _cache:HASKEY(key) { 
        LOCAL val IS _cache[key].
        IF val:ISTYPE("Scalar") { RETURN val. }
        RETURN val:TONUMBER(dflt).
    }
    RETURN dflt.
}

GLOBAL FUNCTION stateSet {
    PARAMETER key.
    PARAMETER value.
    IF _cache:HASKEY(key) { _cache:REMOVE(key). }
    _cache:ADD(key, value).
    _flush().
}

GLOBAL FUNCTION stateSetNum {
    PARAMETER key.
    PARAMETER value.
    stateSet(key, value).
}

GLOBAL FUNCTION stateDump {
    PRINT "=== STATE DUMP ===".
    FOR k IN _cache:KEYS { PRINT "  " + k + " = " + _cache[k]. }
    PRINT "==================".
}

LOCAL FUNCTION _flush {
    IF EXISTS(STATE_PATH) { DELETEPATH(STATE_PATH). }
    LOG ADDONS:JSON:STRINGIFY(_cache) TO STATE_PATH.
}
