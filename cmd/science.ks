// cmd/science.ks — Run all available science experiments now
// Usage: RUNPATH("0:/cmd/science.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("science").
scienceInit().
scienceRunAll().
