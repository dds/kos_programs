// cmd/scansatops.ks - Force released SCANsat mapper into ops/recovery phase.
// Usage: RUNPATH("0:/cmd/scansatops.ks").

IF EXISTS("1:/lib/state.ksm") {
    RUNONCEPATH("1:/lib/state.ksm").
} ELSE IF EXISTS("1:/lib/state.ks") {
    RUNONCEPATH("1:/lib/state.ks").
} ELSE {
    RUNONCEPATH("0:/lib/state.ks").
}

stateInit().

LOCK THROTTLE TO 0.
UNLOCK THROTTLE.
UNLOCK STEERING.
SET SAS TO TRUE.
UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }

IF stateGet("scansat_released_time", "") = "" {
    stateSet("scansat_released_time", TIME:SECONDS).
}
stateSet("scansat_staged", "true").
stateSet("scansat_recovered", "false").
stateSet("mission_cfg_TARGET_PE", "70000").
stateSet("mission_cfg_TARGET_AP", "70000").
stateSet("mission_cfg_SCANSAT_RECOVERY_PE", "70000").
stateSet("mission_cfg_SCANSAT_RECOVERY_AP", "70000").
stateSet("reload_required", "false").
stateSet("phase", "SCANSAT_OPS").

PRINT "SCANsat state forced to SCANSAT_OPS.".
PRINT "Recovery target forced to 70 x 70 km.".
PRINT "Throttle off, nodes cleared. Rebooting.".
WAIT 1.
REBOOT.
