// ============================================================
// state.ks  —  Persistent mission state  (0:/lib/state.ks)
// ============================================================

LOCAL STATE_PATH  IS "1:/run/state.json".
LOCAL _cache      IS LEXICON().

GLOBAL FUNCTION stateInit {
    IF NOT EXISTS("1:/run") { CREATEDIR("1:/run"). }
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

GLOBAL FUNCTION stateRemove {
    PARAMETER key.
    IF _cache:HASKEY(key) {
        _cache:REMOVE(key).
        _flush().
        RETURN TRUE.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION stateKeys {
    LOCAL keys IS LIST().
    FOR k IN _cache:KEYS { keys:ADD(k). }
    RETURN keys.
}

GLOBAL FUNCTION stateRemovePrefix {
    PARAMETER prefix.
    LOCAL keys IS LIST().
    LOCAL removed IS 0.
    FOR k IN _cache:KEYS {
        keys:ADD(k).
    }
    FOR k IN keys {
        IF k:LENGTH >= prefix:LENGTH
                AND k:SUBSTRING(0, prefix:LENGTH) = prefix {
            _cache:REMOVE(k).
            SET removed TO removed + 1.
        }
    }
    IF removed > 0 {
        _flush().
    }
    RETURN removed.
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
