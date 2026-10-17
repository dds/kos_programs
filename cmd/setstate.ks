// cmd/setstate.ks
PARAMETER key.
PARAMETER value.

LOCAL FUNCTION _cmdSetstate {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().

    stateSet(key, value).
    PRINT key + " -> " + value.
}

_cmdSetstate().
