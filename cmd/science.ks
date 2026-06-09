// cmd/science.ks — Run all available science experiments now
// Usage: RUNPATH("1:/cmd/science.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("science").
scienceInit().
scienceRunAll().
