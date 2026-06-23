// ============================================================
// cmd/freespace.ks — emergency free of a full probe volume
// (0:/cmd/freespace.ks)
//
// Recovers a boot wedged by a near-full local volume. Drops the
// archive-only solar lib (6KB, runs from 0:/ now), sweeps flight logs
// to the archive, and trims finished-phase scratch from state — then
// reboots so the libs re-sync (compile-on-archive + copy) into the
// freed space. Does NOT delete band libs: with the keep-list and
// delete-first copy, an existing .ksm re-syncs in place; deleting it
// forces a full-size copy that may not fit.
//
// Run while linked: RUNPATH("0:/cmd/freespace.ks").
// ============================================================

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL before IS CORE:VOLUME:FREESPACE.

IF EXISTS("1:/lib/solar.ksm") {
    DELETEPATH("1:/lib/solar.ksm").
    PRINT "  dropped solar.ksm (archive-only).".
}

LOCAL swept IS bootSweepLogs("1:/run/logs", "0:/logs/archive",
    HOMECONNECTION:ISCONNECTED).
PRINT "  swept " + swept + " log file(s) to archive.".

IF DEFINED stateRemovePrefix {
    LOCAL n IS stateRemovePrefix("midcourse_refine_")
        + stateRemovePrefix("xing_arrival_").
    IF n > 0 { PRINT "  trimmed " + n + " stale state key(s).". }
}

PRINT " ".
PRINT "  Free: " + before + " -> " + CORE:VOLUME:FREESPACE + " bytes.".
IF NOT HOMECONNECTION:ISCONNECTED {
    PRINT "  WARNING: no link — libs can't re-sync. Reconnect first.".
}
PRINT "  Rebooting in 3s...".
WAIT 3.
REBOOT.
