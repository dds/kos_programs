// cmd/setlandingdeorbit.ks - Force safe targeted landing deorbit settings.
// Usage: RUNPATH("0:/cmd/setlandingdeorbit.ks").

PARAMETER phaseName IS "LAND_DEORBIT".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}
stateSet("phase", phaseName).
stateSet("reload_required", "false").
stateSet("lib_band", "LAND_DEORBIT").
_cfg("LANDING_TARGET_TOLERANCE", "2500").
_cfg("TARGET_DEORBIT_SCAN_ORBITS", "32").
_cfg("TARGET_DEORBIT_SCAN_SAMPLES", "2048").
_cfg("TARGET_DEORBIT_COARSE_STOP_DIST", "4000").
_cfg("TARGET_DEORBIT_REFINE_TOLERANCE", "250").
_cfg("TARGET_DEORBIT_PROCEED_ON_MISS", "0").
_cfg("LANDING_DEORBIT_PE", "-5000").

PRINT "Landing deorbit settings forced.".
PRINT "Phase -> " + phaseName.
PRINT "Scan: 32 orbits / 2048 samples, refine<=250m, Pe=-5km.".
