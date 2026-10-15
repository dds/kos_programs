// ============================================================
// Print the most recent maneuver cutoff report after a phase reboot.
// Usage: RUNPATH("0:/cmd/burnreport.ks").
// ============================================================
RUNPATH("1:/lib/boot_lib").
bootPreamble().
PRINT stateGet("last_burn_report", "No saved burn report; this burn predates the independent watchdog.").
