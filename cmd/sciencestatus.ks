// cmd/sciencestatus.ks — Print science and SCANsat status
// Usage: RUNPATH("1:/cmd/sciencestatus.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
RUNPATH("1:/lib/science.ks").
scienceStatus().
