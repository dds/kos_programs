// cmd/setlandingtag.ks - Set landing assist decoupler tag and phase.
// Usage: RUNPATH("0:/cmd/setlandingtag.ks", "probe_decoupler").

PARAMETER tagName IS "probe_decoupler".
PARAMETER phaseName IS "LAND_DEORBIT".

RUNPATH("1:/lib/boot_lib").
bootPreamble().
stateSet("mission_cfg_LANDING_ASSIST_DECOUPLER_TAG", tagName).
stateSet("phase", phaseName).
stateSet("reload_required", "false").
stateSet("lib_band", "LAND_DEORBIT").

PRINT "Landing decoupler tag -> " + tagName.
PRINT "Phase -> " + phaseName.
