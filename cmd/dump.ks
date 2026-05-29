// cmd/dump.ks — Print all persisted state
// Usage: RUNPATH("1:/cmd/dump.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
stateDump().
