// cmd/setstate.ks — Force mission phase
// Usage: RUNPATH("1:/cmd/setstate.ks", "TRANSFER").
PARAMETER newPhase.
stateSet("phase", newPhase).
PRINT "Phase -> " + newPhase.
mLog("Phase forced: " + newPhase).
