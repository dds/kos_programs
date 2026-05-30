// ============================================================
// ZOMBIE.ks — Silent backup control unit, power cycles main.
// ============================================================

GLOBAL CFG IS LEXICON().
GLOBAL LIBS IS LIST ("logs").

GLOBAL FUNCTION main {
    // Write a message to the console with the command to run to wake the zombie
    // and shut down.
    PRINT "Run RUNPATH('1:/zombie'). to reboot the other computers.".
}
