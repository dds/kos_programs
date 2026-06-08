// cmd/files.ks — Print local storage status and file listing
// Usage: RUNPATH("1:/cmd/files.ks").

LOCAL FUNCTION _filesCmdLoadLib {
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

_filesCmdLoadLib("boot_lib").

LOCAL roots IS LIST("core").
LOCAL libs IS LIST("files").
IF DEFINED bootLibResolve {
    SET libs TO bootLibResolve(roots).
}

FOR libName IN libs {
    _filesCmdLoadLib(libName).
}

IF DEFINED printStorageStatus {
    printStorageStatus().
} ELSE {
    PRINT "  WARN: printStorageStatus unavailable".
}
