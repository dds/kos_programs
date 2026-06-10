// ============================================================
// ZOMBIE.ks — Silent backup control unit, power cycles main.
// ============================================================

GLOBAL CFG IS LEXICON().
GLOBAL FUNCTION bootVehicleLibs {
    // The zombie lib loads ONLY here — backup cores must be able
    // to reboot the others offline; main cores get it on demand
    // from the archive (cmd/zombie.ks bootLibLoads it).
    RETURN LIST("logs", "zombie").
}

GLOBAL FUNCTION main {
    CORE:DOACTION("Close Terminal", TRUE). // lurk in the shadows.

    // Write a message to the console with the command to run to wake the zombie
    // and shut down.
    PRINT "Run RUNPATH('1:/zombie'). to reboot the other computers.".
}
