// cmd/scanstart.ks — Start all SCANsat scanners
// Usage: RUNPATH("1:/cmd/scanstart.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
RUNPATH("1:/lib/science.ks").
scienceStartScanners().
