// cmd/exnode.ks — Execute next maneuver.
// Usage: RUNPATH("0:/cmd/exnode.ks").
LOCAL HAS_LINK IS HOMECONNECTION:ISCONNECTED.
LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    IF NOT HAS_LINK { RETURN. }

    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dst IS "1:/lib/" + libName + ".ks".
    LOCAL dstKsm IS "1:/lib/" + libName + ".ksm".

    IF EXISTS(src) {
        IF NOT KSM_SKIP:CONTAINS(libName) {
            COMPILE src TO dstKsm.
        } ELSE {
            COPYPATH(src, dst).
        }
    }
}

LOCAL FUNCTION _loadLib {
    PARAMETER libName.
    IF EXISTS("1:/lib/" + libName + ".ksm") {
        RUNONCEPATH("1:/lib/" + libName + ".ksm").
    } ELSE {
        RUNONCEPATH("1:/lib/" + libName + ".ks").
    }
}

_syncLib("logs").
_loadLib("logs").
initLog().

_syncLib("maneuver").
_loadLib("maneuver").
_syncLib("countdown").
_loadLib("countdown").
countdown(1).
executeManeuver().
