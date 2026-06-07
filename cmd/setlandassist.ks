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
stateSet("lib_band", "LAND_ASSIST").
_cfg("SEQUENCE", "LAND_DEORBIT,LAND_ASSIST,ROVER,DONE").
_cfg("LANDING_ASSIST_DECOUPLER_TAG", tagName).
_cfg("LANDING_ASSIST_RELEASE_ON_SURFACE", "1").
_cfg("LANDING_ASSIST_DESCENT_SPEED", "8").
_cfg("LANDING_ASSIST_MAX_TILT", "12").
_cfg("LANDING_ASSIST_SURFACE_FINAL_SPEED", "0.8").
_cfg("LANDING_ASSIST_SURFACE_SETTLE_TIME", "5").
_cfg("LANDING_ASSIST_SURFACE_TIPOVER", "1").
_cfg("LANDING_ASSIST_SURFACE_TIP_TIME", "4").
_cfg("RELOAD_AFTER_LAND_ASSIST", "1").
_cfg("RELOAD_AFTER_LAND", "0").

PRINT "Emergency LAND_ASSIST config forced.".
PRINT "Tag -> " + tagName.
PRINT "Phase -> LAND_ASSIST. Reboot to continue.".
