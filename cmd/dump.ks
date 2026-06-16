// cmd/dump.ks — Print all persisted state
// Usage: RUNPATH("0:/cmd/dump.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
stateDump().
