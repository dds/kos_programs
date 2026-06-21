// cmd/scansatops.ks - Force released SCANsat mapper into ops phase.
// Usage:
//   RUNPATH("0:/cmd/scansatops.ks").
//   RUNPATH("0:/cmd/scansatops.ks", LIST("LOW_RES_ALTIMETRY")).

PARAMETER requiredTypes IS LIST("LOW_RES_ALTIMETRY").

RUNPATH("1:/lib/boot_lib").
bootPreamble().

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
SET TARGET_PE TO 70000.
SET TARGET_AP TO 70000.
SET SCANSAT_RECOVERY_PE TO 70000.
SET SCANSAT_RECOVERY_AP TO 70000.
SET SCANSAT_DECOUPLER_TAG TO "none".
SET SCANSAT_AUTO_DEORBIT TO 0.
SET SCANSAT_POWER_GUARD TO 1.
SET SCANSAT_TARGET_COVERAGE TO 99.1.
SET SCANSAT_REQUIRED_TYPES TO requiredTypes.
missionOverrideClear().
LOG "SET TARGET_PE TO " + configLiteral(TARGET_PE) + "." TO missionOverridePath().
LOG "SET TARGET_AP TO " + configLiteral(TARGET_AP) + "." TO missionOverridePath().
LOG "SET SCANSAT_RECOVERY_PE TO " + configLiteral(SCANSAT_RECOVERY_PE) + "." TO missionOverridePath().
LOG "SET SCANSAT_RECOVERY_AP TO " + configLiteral(SCANSAT_RECOVERY_AP) + "." TO missionOverridePath().
LOG "SET SCANSAT_DECOUPLER_TAG TO " + configLiteral(SCANSAT_DECOUPLER_TAG) + "." TO missionOverridePath().
LOG "SET SCANSAT_AUTO_DEORBIT TO " + configLiteral(SCANSAT_AUTO_DEORBIT) + "." TO missionOverridePath().
LOG "SET SCANSAT_POWER_GUARD TO " + configLiteral(SCANSAT_POWER_GUARD) + "." TO missionOverridePath().
LOG "SET SCANSAT_TARGET_COVERAGE TO " + configLiteral(SCANSAT_TARGET_COVERAGE) + "." TO missionOverridePath().
LOG "SET SCANSAT_REQUIRED_TYPES TO " + configLiteral(SCANSAT_REQUIRED_TYPES) + "." TO missionOverridePath().
stateSet("zombie_scansat_active", "true").
stateSet("zombie_scansat_required_types", requiredTypes).
stateSet("reload_required", "false").
stateSet("phase", "SCANSAT_OPS").

PRINT "SCANsat state forced to SCANSAT_OPS for " + requiredTypes:JOIN(", ") + ".".
PRINT "Throttle off, nodes cleared. Rebooting into zombie SCANsat mode.".
WAIT 1.
REBOOT.
