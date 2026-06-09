// cmd/scantransmit.ks — Transmit all stored science
// Usage: RUNPATH("1:/cmd/scantransmit.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("science").
scienceTransmitAll().
