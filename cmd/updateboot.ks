// Install the current archive bootstrap; leave reboot timing to the operator.
@LAZYGLOBAL OFF.
LOCAL FUNCTION _cmdUpdateBoot {
    IF NOT HOMECONNECTION:ISCONNECTED {
        PRINT "Boot update needs an archive connection.". RETURN.
    }
    IF NOT (SHIP:THRUST <= 0.001) OR NOT (SHIP:CONTROL:MAINTHROTTLE <= 0)
            OR NOT (SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
        PRINT "Boot update deferred: thrust/throttle must be zero.". RETURN.
    }
    IF NOT EXISTS("0:/boot/boot.ks") {
        PRINT "Archive bootstrap source missing.". RETURN.
    }
    // Compile on the archive; do not overwrite the selected boot file.
    // Use ignored build output, not the tracked VAB bootstrap bytecode.
    IF EXISTS("0:/boot/boot_update.ksm") { DELETEPATH("0:/boot/boot_update.ksm"). }
    COMPILE "0:/boot/boot.ks" TO "0:/boot/boot_update.ksm".
    LOCAL dest IS "1:/boot/boot_updated.ksm".
    IF "boot/boot_updated.ksm" = CORE:BOOTFILENAME
            OR "/boot/boot_updated.ksm" = CORE:BOOTFILENAME
            OR "1:/boot/boot_updated.ksm" = CORE:BOOTFILENAME {
        SET dest TO "1:/boot/boot.ksm".
    }
    IF NOT EXISTS("1:/boot") { CREATEDIR("1:/boot"). }
    IF EXISTS(dest) { DELETEPATH(dest). }
    COPYPATH("0:/boot/boot_update.ksm", dest).
    IF NOT EXISTS(dest) { PRINT "Boot copy failed; previous boot remains selected.". RETURN. }
    SET CORE:BOOTFILENAME TO dest:SUBSTRING(3,dest:LENGTH-3).
    PRINT "Boot installed: " + CORE:BOOTFILENAME + ". Reboot when ready.".
}
_cmdUpdateBoot().
