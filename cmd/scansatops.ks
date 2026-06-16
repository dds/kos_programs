// cmd/scansatops.ks - Force released SCANsat mapper into ops phase.
// Usage:
//   RUNPATH("0:/cmd/scansatops.ks").
//   RUNPATH("0:/cmd/scansatops.ks", "LOW_RES_ALTIMETRY").

PARAMETER requiredTypes IS "LOW_RES_ALTIMETRY".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

IF NOT (DEFINED CFG) {
    GLOBAL CFG IS LEXICON().
}

LOCK THROTTLE TO 0.
UNLOCK THROTTLE.
UNLOCK STEERING.
SET SAS TO TRUE.
UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }

IF stateGet("scansat_released_time", "") = "" {
    stateSet("scansat_released_time", TIME:SECONDS).
}
stateSet("scansat_staged", "true").
stateSet("scansat_recovered", "true").
stateSet("mission_cfg_TARGET_PE", "70000").
stateSet("mission_cfg_TARGET_AP", "70000").
stateSet("mission_cfg_SCANSAT_RECOVERY_PE", "70000").
stateSet("mission_cfg_SCANSAT_RECOVERY_AP", "70000").
stateSet("mission_cfg_SCANSAT_DECOUPLER_TAG", "none").
stateSet("mission_cfg_SCANSAT_AUTO_DEORBIT", 0).
stateSet("mission_cfg_SCANSAT_POWER_GUARD", 1).
stateSet("mission_cfg_SCANSAT_TARGET_COVERAGE", 99.1).
stateSet("mission_cfg_SCANSAT_REQUIRED_TYPES", requiredTypes).
stateSet("zombie_scansat_active", "true").
stateSet("zombie_scansat_required_types", requiredTypes).
stateSet("reload_required", "false").
stateSet("phase", "SCANSAT_OPS").

PRINT "SCANsat state forced to SCANSAT_OPS for " + requiredTypes + ".".
PRINT "Throttle off, nodes cleared. Rebooting into zombie SCANsat mode.".
WAIT 1.
REBOOT.
