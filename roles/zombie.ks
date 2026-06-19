// ============================================================
// ZOMBIE.ks — Silent backup control unit, power cycles main.
// ============================================================

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
        SET SCANSAT_DECOUPLER_TAG TO "none".
        SET SCANSAT_AUTO_DEORBIT TO 0.
        SET SCANSAT_POWER_GUARD TO 1.
        SET SCANSAT_TARGET_COVERAGE TO 99.1.
        SET SCANSAT_REQUIRED_TYPES TO
            stateGet("zombie_scansat_required_types", LIST("LOW_RES_ALTIMETRY")).
        LOCAL seq IS LIST("SCANSAT_OPS", "DONE").
        SET launchSeq TO seq.
        SET xferSeq TO seq.
        IF stateGet("phase", "") <> "SCANSAT_OPS"
                AND stateGet("phase", "") <> "DONE" {
            stateSet("phase", "SCANSAT_OPS").
        }
        mLog("Zombie core promoted to SCANsat ops.").
        runPhases(LEXICON()).
        WAIT UNTIL FALSE.
        RETURN.
    }

    CORE:DOACTION("Close Terminal", TRUE). // lurk in the shadows.

    // Write a message to the console with the command to run to wake the zombie
    // and shut down.
    PRINT "Run RUNPATH('1:/zombie'). to reboot the other computers.".
}
