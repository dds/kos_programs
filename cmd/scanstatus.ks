// cmd/scanstatus.ks — Print SCANsat coverage status
// Usage: RUNPATH("1:/cmd/scanstatus.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("science").
scienceScanStatus().
