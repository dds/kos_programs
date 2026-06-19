// cmd/trimstate.ks - Remove bulky nonessential state entries.
// Usage: RUNONCEPATH("0:/cmd/trimstate.ks").

LOCAL loadedStateLib IS FALSE.

IF EXISTS("1:/lib/state.ksm") {
    RUNONCEPATH("1:/lib/state.ksm").
    SET loadedStateLib TO TRUE.
} ELSE IF EXISTS("1:/lib/state.ks") {
    RUNONCEPATH("1:/lib/state.ks").
    SET loadedStateLib TO TRUE.
} ELSE {
    PRINT "ERROR: cached state library not found.".
}

IF loadedStateLib {
    stateInit().
    IF stateRemove("lib_band_libs") {
        PRINT "Removed state key: lib_band_libs.".
    } ELSE {
        PRINT "State key not present: lib_band_libs.".
    }
}
