// cmd/crash.ks - Put the current craft on an impact trajectory.
// Usage: RUNPATH("0:/cmd/crash.ks").       // target Pe = -1 km
//        RUNPATH("0:/cmd/crash.ks", 2).    // target Pe = 2 km

PARAMETER targetKm IS -1.

LOCAL HAS_LINK IS HOMECONNECTION:ISCONNECTED.
LOCAL targetPe IS targetKm * 1000.
IF ABS(targetKm) > 1000 { SET targetPe TO targetKm. }

LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    IF NOT HAS_LINK { RETURN. }
    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dstKsm IS "1:/lib/" + libName + ".ksm".
    IF EXISTS(dstKsm) { RETURN. }
    IF EXISTS(src) { COMPILE src TO dstKsm. }
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
stateInit().
_syncLib("logs").
_loadLib("logs").
initLog().
_syncLib("countdown").
_loadLib("countdown").
_syncLib("maneuver").
_loadLib("maneuver").

PRINT "CRASH: target Pe " + ROUND(targetPe/1000,1) + " km".
mLogWarn("STATS crash setup targetPeKm=" + ROUND(targetPe/1000,1)
    + " body=" + SHIP:ORBIT:BODY:NAME
    + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
    + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
    + " etaAp=" + ROUND(ETA:APOAPSIS,0)
    + " thrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).

IF SHIP:PERIAPSIS <= targetPe {
    PRINT "Already at or below target Pe.".
    mLogWarn("STATS crash result status=already-impact PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)).
    RETURN.
}

IF SHIP:AVAILABLETHRUST <= 0 {
    PRINT "No available thrust. Cannot crash-burn.".
    mLogError("Crash command aborted: no available thrust.").
    RETURN.
}

UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
planLowerPe(targetPe).
LOCAL ok IS executeManeuver().

IF ok {
    PRINT "Impact course set. Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + " km.".
    mLogWarn("STATS crash result status=complete PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
} ELSE {
    PRINT "Crash burn failed or was interrupted.".
    mLogError("Crash command failed or was interrupted.").
}
