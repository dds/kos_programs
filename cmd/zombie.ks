// cmd/zombie.ks — Reboot the other computers.
// Usage: RUNPATH("1:/zombie").

LOCAL FUNCTION _zombieCmdLoadLib {
    PARAMETER libName.
    LOCAL compiled IS "1:/lib/" + libName + ".ksm".
    LOCAL cached IS "1:/lib/" + libName + ".ks".
    LOCAL archive IS "0:/lib/" + libName + ".ks".
    IF EXISTS(compiled) {
        RUNONCEPATH(compiled).
    } ELSE IF EXISTS(cached) {
        RUNONCEPATH(cached).
    } ELSE IF EXISTS(archive) {
        RUNONCEPATH(archive).
    } ELSE {
        PRINT "  WARN: " + libName + " unavailable".
    }
}

_zombieCmdLoadLib("boot_lib").

LOCAL roots IS LIST("zombie").
LOCAL libs IS roots.
IF DEFINED bootLibResolve {
    SET libs TO bootLibResolve(roots).
}

FOR libName IN libs {
    _zombieCmdLoadLib(libName).
}

IF DEFINED zombieRebootOtherCores {
    zombieRebootOtherCores().
} ELSE {
    PRINT "  WARN: zombieRebootOtherCores unavailable".
}
