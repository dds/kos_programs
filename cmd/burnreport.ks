// ============================================================
// Print the most recent maneuver cutoff report after a phase reboot.
// Usage: RUNPATH("0:/cmd/burnreport.ks").
// ============================================================
RUNPATH("1:/lib/boot_lib").
bootPreamble().
PRINT "Latest completed cutoff (may be from an earlier maneuver):".
PRINT stateGet("last_burn_report", "No saved cutoff report; the last attempt may not have reached cutoff.").
PRINT "Saved attempt: phase=" + stateGet("phase", "")
    + " status=" + stateGet("burn_status", "")
    + " started=" + stateGet("burn_started", "false")
    + " reason=" + stateGet("burn_abort_reason", "").
PRINT "Current hardware: stage=" + STAGE:NUMBER + " ready=" + STAGE:READY
    + " thrust=" + ROUND(SHIP:THRUST,3).
FOR eng IN SHIP:ENGINES {
    PRINT eng:NAME + " stage=" + eng:STAGE + " decoupledIn=" + eng:DECOUPLEDIN
        + " ignition=" + eng:IGNITION + " flameout=" + eng:FLAMEOUT
        + " limit=" + ROUND(eng:THRUSTLIMIT,1)
        + " available=" + ROUND(eng:AVAILABLETHRUST,3)
        + " possible=" + ROUND(eng:POSSIBLETHRUST,3).
}
