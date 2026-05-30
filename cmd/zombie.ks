// cmd/zombie.ks — Reboot the other computers.
// Usage: RUNPATH("1:/zombie").

LOCAL all_cores IS LIST().
LIST PROCESSORS IN all_cores.

FOR p IN all_cores {
    IF p:TAG <> CORE:TAG {
        p:DOACTION("Toggle Power", TRUE).
        p:DOACTION("Toggle Power", TRUE).
        PRINT "Zombified core: " + p:TOSTRING.
    }
}
PRINT "All other cores have had their brains eaten and are reborn. Have a nice day.".
