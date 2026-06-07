// cmd/setlandingdeorbit.ks - Force safe targeted landing deorbit settings.
// Usage: RUNPATH("0:/cmd/setlandingdeorbit.ks").

PARAMETER phaseName IS "LAND_DEORBIT".

LOCAL FUNCTION _loadState {
    IF EXISTS("1:/lib/state.ksm") {
        RUNONCEPATH("1:/lib/state.ksm").
    } ELSE IF EXISTS("1:/lib/state.ks") {
        RUNONCEPATH("1:/lib/state.ks").
    } ELSE IF EXISTS("0:/lib/state.ks") {
        RUNONCEPATH("0:/lib/state.ks").
    } ELSE {
        PRINT "No state library found.".
        WAIT UNTIL FALSE.
    }
    stateInit().
}

LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

_loadState().
stateSet("phase", phaseName:TOUPPER).
stateSet("reload_required", "false").
stateSet("lib_band", "LAND_ASSIST").
_cfg("LANDING_TARGET_TOLERANCE", "2500").
_cfg("TARGET_DEORBIT_SCAN_ORBITS", "32").
_cfg("TARGET_DEORBIT_SCAN_SAMPLES", "2048").
_cfg("TARGET_DEORBIT_PROCEED_ON_MISS", "0").
_cfg("LANDING_DEORBIT_PE", "-5000").

PRINT "Landing deorbit settings forced.".
PRINT "Phase -> " + phaseName:TOUPPER.
PRINT "Scan: 32 orbits / 2048 samples, Pe=-5km, no proceed on miss.".
