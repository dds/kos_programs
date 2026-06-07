// cmd/setlandingtag.ks - Set landing assist decoupler tag and phase.
// Usage: RUNPATH("0:/cmd/setlandingtag.ks", "probe_decoupler").

PARAMETER tagName IS "probe_decoupler".
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

_loadState().
stateSet("mission_cfg_LANDING_ASSIST_DECOUPLER_TAG", tagName).
stateSet("phase", phaseName:TOUPPER).
stateSet("reload_required", "false").
stateSet("lib_band", "LAND_ASSIST").

PRINT "Landing decoupler tag -> " + tagName.
PRINT "Phase -> " + phaseName:TOUPPER.
