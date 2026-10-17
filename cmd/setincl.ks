// cmd/setincl.ks — Plan and execute inclination correction.
// Usage: RUNPATH("0:/cmd/setincl.ks", 180).
PARAMETER targetInc.

LOCAL FUNCTION _cmdSetincl {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoadList(LIST("countdown", "maneuver", "lib_navigation", "inclination")).
    planInclinationChange(targetInc).
    executeManeuver().
}

_cmdSetincl().
