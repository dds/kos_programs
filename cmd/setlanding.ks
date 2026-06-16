// cmd/setlanding.ks — Landing phase/config overrides (0:/cmd/setlanding.ks)
// Replaces setlandassist.ks / setlandingdeorbit.ks.
//
// Usage:
//   RUNPATH("0:/cmd/setlanding.ks", "deorbit").
//       Force safe targeted-deorbit settings and enter LAND_DEORBIT,
//       then LAND.
//   RUNPATH("0:/cmd/setlanding.ks", "deorbit", "assist").
//       Same, but continue into LAND_ASSIST after deorbit.
//   RUNPATH("0:/cmd/setlanding.ks", "assist").
//       Force the emergency LAND_ASSIST profile for a live rover.

PARAMETER mode IS "assist".
PARAMETER arg1 IS "".

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

LOCAL FUNCTION _clearLibCache {
    stateRemove("lib_band_libs").
    stateRemove("lib_band_phase").
}

LOCAL FUNCTION _landingSequenceForPhase {
    PARAMETER phaseName.
    PARAMETER assistPath IS FALSE.
    IF assistPath OR phaseName = "LAND_ASSIST" {
        RETURN "LAND_DEORBIT,LAND_ASSIST,DONE".
    }
    IF phaseName = "LAND" {
        RETURN "LAND,DONE".
    }
    RETURN "LAND_DEORBIT,LAND,DONE".
}

LOCAL FUNCTION _assistConfig {
    _cfg("MAX_TILT", "12").
    _cfg("DEORBIT_OVERSHOOT", "1500").
    _cfg("DEORBIT_OVERSHOOT_TOLERANCE", "1200").
    _cfg("RELOAD_AFTER_LAND_ASSIST", "0").
    _cfg("RELOAD_AFTER_LAND", "0").
}

IF mode = "assist" {
    stateSet("phase", "LAND_ASSIST").
    stateSet("reload_required", "false").
    stateSet("lib_band", "LANDING").
    _clearLibCache().
    _cfg("SEQUENCE", "LAND_DEORBIT,LAND_ASSIST,DONE").
    _assistConfig().

    PRINT "Emergency LAND_ASSIST config forced.".
    PRINT "Phase -> LAND_ASSIST. Resume when ready.".

} ELSE IF mode = "deorbit" {
    LOCAL phaseName IS "LAND_DEORBIT".
    LOCAL assistPath IS FALSE.
    IF arg1 = "assist" OR arg1 = "LAND_ASSIST" {
        SET assistPath TO TRUE.
    } ELSE IF arg1 <> "" {
        SET phaseName TO arg1.
    }

    stateSet("phase", phaseName).
    stateSet("reload_required", "false").
    stateSet("lib_band", _landingBandForPhase(phaseName)).
    _clearLibCache().
    _cfg("SEQUENCE", _landingSequenceForPhase(phaseName, assistPath)).
    IF assistPath { _assistConfig(). }
    _cfg("TARGET_TOLERANCE", "2500").
    _cfg("TARGET_DEORBIT_SCAN_ORBITS", "2").
    _cfg("TARGET_DEORBIT_SCAN_SAMPLES", "32").
    _cfg("TARGET_DEORBIT_COARSE_STOP_DIST", "4000").
    _cfg("TARGET_DEORBIT_REFINE_TOLERANCE", "250").
    _cfg("TARGET_DEORBIT_PROCEED_ON_MISS", "0").
    _cfg("DEORBIT_PE", "-1000").

    PRINT "Landing deorbit settings forced.".
    PRINT "Sequence -> " + stateGet("mission_cfg_SEQUENCE", "") + ".".
    PRINT "Phase -> " + phaseName + ".".
    PRINT "Scan: 2 orbits / 32 samples, refine<=250m, Pe=-1km.".

} ELSE {
    PRINT "Unknown mode '" + mode + "'. Use: deorbit | assist.".
}
