// ============================================================
// cmd/freespace.ks — emergency free of a full probe volume
// (0:/cmd/freespace.ks)
//
// Recovers the deadlock where the volume is so full that a band lib
// (or the new boot_lib) can't compile, which blocks the very change
// that would free space. Drops the archive-only solar lib and the
// largest band lib (both reload/recompile from 0:/ on the next linked
// boot), sweeps logs to the archive, then reboots.
//
// Run while linked: RUNPATH("0:/cmd/freespace.ks").
// ============================================================

RUNPATH("1:/lib/boot_lib").

LOCAL before IS CORE:VOLUME:FREESPACE.

// solar is archive-only now (runs from 0:/); maneuver re-compiles from
// the archive on reboot. Deleting both gives the boot room to compile.
FOR f IN LIST("1:/lib/solar.ksm", "1:/lib/maneuver.ksm") {
    IF EXISTS(f) {
        DELETEPATH(f).
        PRINT "  removed " + f + ".".
    }
}

LOCAL swept IS bootSweepLogs("1:/run/logs", "0:/logs/archive",
    HOMECONNECTION:ISCONNECTED).
PRINT "  swept " + swept + " log file(s) to archive.".

PRINT " ".
PRINT "  Free: " + before + " -> " + CORE:VOLUME:FREESPACE + " bytes.".
IF NOT HOMECONNECTION:ISCONNECTED {
    PRINT "  WARNING: no link — maneuver can't recompile. Reconnect first.".
}
PRINT "  Rebooting in 3s...".
WAIT 3.
REBOOT.
