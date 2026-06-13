// cmd/scansatdeorbit.ks - Request immediate SCANsat self-deorbit.
// Run on the SCANsat vessel only as a manual override; normal
// SCANSAT_OPS waits for required map coverage first.
// Usage: RUNPATH("0:/cmd/scansatdeorbit.ks").
//
// The SCANSAT_OPS mapping loop polls this state and starts the
// deorbit burn on the next loop tick.

stateSet("scansat_deorbit_requested", "true").
mLog("scansatdeorbit: scansat_deorbit_requested set.").
PRINT "SCANsat deorbit override requested.".
PRINT "Burn starts on the next SCANSAT_OPS loop tick.".
