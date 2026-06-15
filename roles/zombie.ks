// ============================================================
// ZOMBIE.ks — Silent backup control unit, power cycles main.
// ============================================================

GLOBAL CFG IS LEXICON().
GLOBAL FUNCTION bootVehicleLibs {
    IF stateGet("zombie_scansat_active", "false") = "true" {
        RETURN missionLibsForPhases(LIST("SCANSAT_OPS", "DONE"),
            LIST("orbit", "solar", "science")).
    }
    // The zombie lib loads ONLY here — backup cores must be able
    // to reboot the others offline; main cores get it on demand
    // from the archive (cmd/zombie.ks bootLibLoads it).
    RETURN LIST("logs", "zombie").
}

GLOBAL FUNCTION main {
    IF stateGet("zombie_scansat_active", "false") = "true" {
        applyKnownMissionState().
        cfgSet("SCANSAT_DECOUPLER_TAG", "none").
        cfgSet("SCANSAT_AUTO_DEORBIT", 0).
        cfgSet("SCANSAT_POWER_GUARD", 1).
        cfgSet("SCANSAT_TARGET_COVERAGE", 99.1).
        cfgSet("SCANSAT_REQUIRED_TYPES",
            stateGet("zombie_scansat_required_types", "LOW_RES_ALTIMETRY")).
        LOCAL seq IS LIST("SCANSAT_OPS", "DONE").
        SET launchSeq TO seq.
        SET xferSeq TO seq.
        IF stateGet("phase", "") <> "SCANSAT_OPS"
                AND stateGet("phase", "") <> "DONE" {
            stateSet("phase", "SCANSAT_OPS").
        }
        mLog("Zombie core promoted to SCANsat ops.").
        runPhases(phaseHandlerMap()).
        WAIT UNTIL FALSE.
        RETURN.
    }

    CORE:DOACTION("Close Terminal", TRUE). // lurk in the shadows.

    // Write a message to the console with the command to run to wake the zombie
    // and shut down.
    PRINT "Run RUNPATH('1:/zombie'). to reboot the other computers.".
}
