// cmd/directreturn.ks - Preview a direct surface-to-Kerbin ascent, no burn.
// RUNPATH("0:/cmd/directreturn.ks"). // Kerbin Pe 53 km, reserve 20 m/s
// RUNPATH("0:/cmd/directreturn.ks", "status"). // quick measured inputs
// RUNPATH("0:/cmd/directreturn.ks", "plan", 53000, 20).
@LAZYGLOBAL OFF.
PARAMETER action IS "plan".
PARAMETER targetPe IS 53000.
PARAMETER reserveDv IS 20.

LOCAL FUNCTION _cmdDirectreturn {
    IF action <> "plan" AND action <> "status" { PRINT "Use plan or status.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("return_direct").
    previewDirectReturn(targetPe, reserveDv, action = "plan").
}

_cmdDirectreturn().
