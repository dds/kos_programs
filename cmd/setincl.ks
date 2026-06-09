// cmd/setincl.ks — Plan and execute inclination correction.
// Usage: RUNPATH("1:/cmd/setincl.ks", 180).
PARAMETER targetInc.
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoadList(LIST("countdown", "maneuver", "lib_navigation", "inclination")).
planInclinationChange(targetInc).
executeManeuver().
