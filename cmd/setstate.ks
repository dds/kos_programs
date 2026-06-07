// cmd/setstate.ks — Force mission phase
// Usage: RUNPATH("1:/cmd/setstate.ks", "TRANSFER").
PARAMETER newPhase.

LOCAL HAS_LINK IS HOMECONNECTION:ISCONNECTED.
LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    IF NOT HAS_LINK { RETURN. }

    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dst IS "1:/lib/" + libName + ".ks".
    LOCAL dstKsm IS "1:/lib/" + libName + ".ksm".

    IF EXISTS(src) {
        COMPILE src TO dstKsm.
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

_syncLib("state").
_loadLib("state").
_syncLib("logs").
_loadLib("logs").
initLog().

LOCAL phaseName IS newPhase:TOUPPER.
stateSet("phase", phaseName).
PRINT "Phase -> " + phaseName.
mLog("Phase forced: " + phaseName).
