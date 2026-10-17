// cmd/sciencestatus.ks — Print science and SCANsat status
// Usage: RUNPATH("0:/cmd/sciencestatus.ks").

LOCAL FUNCTION _cmdSciencestatus {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("science").
    scienceStatus().
}

_cmdSciencestatus().
