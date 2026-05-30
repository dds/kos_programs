// cmd/zombie.ks — Reboot the other computers.
// Usage: RUNPATH("1:/zombie").

LOCAL all_cores IS LIST().
LIST PROCESSORS IN all_cores.

FOR p IN all_cores {
    IF p <> CORE {
        p:DOACTION("Toggle Power", true).
        p:DOACTION("Toggle Power", true).
        PRINT "Zombified core: " + p:TOSTRING.
    }
}
PRINT "All secondary cores successfully sent zombied.".
