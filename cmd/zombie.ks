// cmd/zombie.ks — Reboot the other computers.
// Usage: RUNPATH("1:/zombie").

LOCAL all_cores IS LIST().
LIST PROCESSORS IN all_cores.

FOR p IN all_cores {
    IF p:PART:CID <> CORE:PART:CID {
        PRINT "Devouring core: {0}({1})":FORMAT(p:PART:NAME, p:PART:CID).
        p:DOACTION("Toggle Power", TRUE).
        p:DOACTION("Toggle Power", TRUE).
    }
}
PRINT "All other cores have had their brains eaten and are reborn. Have a nice day.".
