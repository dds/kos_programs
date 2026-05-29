// cmd/scanstatus.ks — Print SCANsat coverage status
// Usage: RUNPATH("1:/cmd/scanstatus.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
RUNPATH("1:/lib/science.ks").
scienceScanStatus().
