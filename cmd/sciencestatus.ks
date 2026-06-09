// cmd/sciencestatus.ks — Print science and SCANsat status
// Usage: RUNPATH("1:/cmd/sciencestatus.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("science").
scienceStatus().
