// cmd/scansatdeorbit.ks — Signal the SCANsat CPU to begin its deorbit.
// Run on the SCANsat vessel when scanning is complete.
// Usage: RUNPATH("0:/cmd/scansatdeorbit.ks").
//
// The roles/scansat.ks role polls this state every 5 minutes; the
// deorbit burn fires on the next poll after this cmd runs.

stateSet("scansat_deorbit_requested", "true").
mLog("scansatdeorbit: scansat_deorbit_requested set.").
PRINT "SCANsat deorbit requested. Burn fires on next 5-min poll.".
PRINT "Pe target: 40 km.".
