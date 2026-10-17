// cmd/returncheck.ks - Plan a fuel-first 53 km Kerbin return without burning.
// Leaves the node for map review; does not change the saved mission/phase.
// RUNPATH("0:/cmd/returncheck.ks").

LOCAL FUNCTION _cmdReturncheck {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("return_escape").
    previewReturnEscape(53000).
}

_cmdReturncheck().
