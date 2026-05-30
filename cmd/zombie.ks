// cmd/zombie.ks — Reboot the other computers.
// Usage: RUNPATH("1:/zombie").

LOCAL all_cores IS LIST().
LIST PROCESSORS IN all_cores.

FOR p IN all_cores {
    IF p:VOLUME:ID <> CORE:VOLUME:ID {
        PRINT "Zombifying core: " + p:NAME + " on volume " + p:VOLUME:ID.
        p:REBOOT().
    }
}
PRINT "All secondary cores successfully sent to the boot window.".
