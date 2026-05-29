// cmd/science.ks — Run all available science experiments now
// Usage: RUNPATH("1:/cmd/science.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
RUNPATH("1:/lib/science.ks").
scienceInit().
scienceRunAll().
