// cmd/scantransmit.ks — Transmit all stored science
// Usage: RUNPATH("1:/cmd/scantransmit.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
RUNPATH("1:/lib/science.ks").
scienceTransmitAll().
