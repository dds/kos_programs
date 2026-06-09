// cmd/scanstart.ks — Start all SCANsat scanners
// Usage: RUNPATH("1:/cmd/scanstart.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("science").
scienceStartScanners().
