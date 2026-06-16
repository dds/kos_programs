// cmd/setlanding.ks — Landing phase/config overrides (0:/cmd/setlanding.ks)
// Replaces setlandassist.ks / setlandingdeorbit.ks / setlandingtag.ks.
//
// Usage:
//   RUNPATH("0:/cmd/setlanding.ks", "tag", "probe_decoupler").
//       Set the landing-assist decoupler tag and enter LAND_DEORBIT.
//   RUNPATH("0:/cmd/setlanding.ks", "tag", "probe_decoupler", "LAND").
//       Same, but enter the given phase.
//   RUNPATH("0:/cmd/setlanding.ks", "deorbit").
//       Force safe targeted-deorbit settings and enter LAND_DEORBIT.
//   RUNPATH("0:/cmd/setlanding.ks", "assist", "probe_decoupler").
//       Force the emergency LAND_ASSIST profile for a live rover.

PARAMETER mode IS "tag".
PARAMETER arg1 IS "".
PARAMETER arg2 IS "".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

LOCAL FUNCTION _landingBandForPhase {
    PARAMETER phaseName.
    IF phaseName = "LAND_DEORBIT" { RETURN "LAND_DEORBIT". }
    RETURN "LANDING".
}

IF mode = "assist" {
    LOCAL tagName IS "probe_decoupler".
    IF arg1 <> "" { SET tagName TO arg1. }

    stateSet("phase", "LAND_ASSIST").
    stateSet("reload_required", "false").
    stateSet("lib_band", "LANDING").
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

} ELSE IF mode = "deorbit" {
    LOCAL phaseName IS "LAND_DEORBIT".
    IF arg1 <> "" { SET phaseName TO arg1. }

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
    PRINT "Phase -> " + phaseName + ".".
    PRINT "Scan: 32 orbits / 2048 samples, refine<=250m, Pe=-5km.".

} ELSE IF mode = "tag" {
    LOCAL tagName IS "probe_decoupler".
    IF arg1 <> "" { SET tagName TO arg1. }
    LOCAL phaseName IS "LAND_DEORBIT".
    IF arg2 <> "" { SET phaseName TO arg2. }

    _cfg("LANDING_ASSIST_DECOUPLER_TAG", tagName).
    stateSet("phase", phaseName).
    stateSet("reload_required", "false").
    stateSet("lib_band", _landingBandForPhase(phaseName)).

    PRINT "Landing decoupler tag -> " + tagName + ".".
    PRINT "Phase -> " + phaseName + ".".

} ELSE {
    PRINT "Unknown mode '" + mode + "'. Use: tag | deorbit | assist.".
}
