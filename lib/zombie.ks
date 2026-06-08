// ============================================================
// zombie.ks - Helpers for rebooting companion kOS processors
// ============================================================

GLOBAL FUNCTION zombieRebootOtherCores {
    LOCAL allCores IS LIST().
    LIST PROCESSORS IN allCores.

    FOR p IN allCores {
        IF p:PART:CID <> CORE:PART:CID {
            PRINT "Devouring core: {0}({1})":FORMAT(p:PART:NAME, p:PART:CID).
            p:DOACTION("Toggle Power", TRUE).
            p:DOACTION("Toggle Power", TRUE).
        }
    }
    PRINT "All other cores have had their brains eaten and are reborn. Have a nice day.".
}
