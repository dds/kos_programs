// cmd/exnode.ks — Execute next maneuver.
// Usage: RUNPATH("0:/cmd/exnode.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoadList(LIST("countdown", "maneuver")).
executeManeuver().
