// cmd/setlandassist.ks - Force emergency LAND_ASSIST config for live rover.
// Usage: RUNPATH("0:/cmd/setlandassist.ks").

PARAMETER tagName IS "probe_decoupler".

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
stateSet("phase", "LAND_ASSIST").
stateSet("reload_required", "false").
stateSet("lib_band", "LAND_DEORBIT").
stateSet("mission_cfg_LANDING_ASSIST_DECOUPLER_TAG", tagName).
_cfg("SEQUENCE", "LAND_DEORBIT,LAND_ASSIST,DONE").
_cfg("LANDING_ASSIST_DECOUPLER_TAG", tagName).
_cfg("LANDING_ASSIST_MAX_TILT", "12").
_cfg("LANDING_ASSIST_SURFACE_SETTLE_TIME", "2").
_cfg("LANDING_ASSIST_SURFACE_TIPOVER", "1").
_cfg("LANDING_ASSIST_SURFACE_TIP_TIME", "1.5").
_cfg("LANDING_DEORBIT_OVERSHOOT", "1500").
_cfg("LANDING_DEORBIT_OVERSHOOT_TOLERANCE", "1200").
_cfg("RELOAD_AFTER_LAND_ASSIST", "0").
_cfg("RELOAD_AFTER_LAND", "0").

PRINT "Emergency LAND_ASSIST config forced.".
PRINT "Tag -> " + tagName.
PRINT "Phase -> LAND_ASSIST. Resume when ready.".
