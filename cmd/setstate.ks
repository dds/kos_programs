// cmd/setstate.ks — Force mission phase
// Usage: RUNPATH("1:/cmd/setstate.ks", "TMI").
PARAMETER newPhase.
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
stateSet("phase", newPhase).
PRINT "Phase set to: " + newPhase.
mLog("Phase manually forced to: " + newPhase).
