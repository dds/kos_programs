// --- Config defaults owned by this file ---
GLOBAL RELOAD_AFTER_LAND_ASSIST IS 1.
GLOBAL RELOAD_AFTER_LAND IS 1.

// cmd/setlanding.ks — Landing phase/config overrides (0:/cmd/setlanding.ks)
// Replaces setlandassist.ks / setlandingdeorbit.ks.
//
// Usage:
//   RUNPATH("0:/cmd/setlanding.ks", "deorbit").
//       Force targeted-deorbit settings and enter LAND_DEORBIT,
//       then LAND_ASSIST.
//   RUNPATH("0:/cmd/setlanding.ks", "deorbit", "land").
//       Use the older direct LAND path after deorbit.
//   RUNPATH("0:/cmd/setlanding.ks", "assist").
//       Force the emergency LAND_ASSIST profile for a live rover.

PARAMETER mode IS "assist".
PARAMETER arg1 IS "".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

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
    PARAMETER assistPath IS TRUE.
    IF assistPath OR phaseName = "LAND_ASSIST" {
        RETURN LIST("LAND_DEORBIT", "LAND_ASSIST", "DONE").
    }
    IF phaseName = "LAND" {
        RETURN LIST("LAND", "DONE").
    }
    RETURN LIST("LAND_DEORBIT", "LAND", "DONE").
}

LOCAL FUNCTION _assistConfig {
    LOG "SET RELOAD_AFTER_LAND_ASSIST TO " + configLiteral(0) + "." TO missionOverridePath().
    LOG "SET RELOAD_AFTER_LAND TO " + configLiteral(0) + "." TO missionOverridePath().
}

IF mode = "assist" {
    missionOverrideClear().
    stateSet("phase", "LAND_ASSIST").
    stateSet("reload_required", "false").
    stateSet("lib_band", "LANDING").
    _clearLibCache().
    LOG "SET SEQUENCE TO " + configLiteral(LIST("LAND_DEORBIT", "LAND_ASSIST", "DONE")) + "." TO missionOverridePath().
    LOG "SET LANDING_SKIP_TARGET_SEARCH TO " + configLiteral(1) + "." TO missionOverridePath().
    _assistConfig().

    PRINT "Emergency LAND_ASSIST config forced.".
    PRINT "Phase -> LAND_ASSIST. Resume when ready.".

} ELSE IF mode = "deorbit" {
    missionOverrideClear().
    LOCAL phaseName IS "LAND_DEORBIT".
    LOCAL assistPath IS TRUE.
    IF arg1 = "assist" OR arg1 = "LAND_ASSIST" {
        SET assistPath TO TRUE.
    } ELSE IF arg1 = "land" OR arg1 = "LAND" {
        SET assistPath TO FALSE.
    } ELSE IF arg1 <> "" {
        SET phaseName TO arg1.
    }

    stateSet("phase", phaseName).
    stateSet("reload_required", "false").
    stateSet("lib_band", _landingBandForPhase(phaseName)).
    _clearLibCache().
    LOG "SET SEQUENCE TO " + configLiteral(_landingSequenceForPhase(phaseName, assistPath)) + "." TO missionOverridePath().
    IF assistPath { _assistConfig(). }

    PRINT "Landing deorbit settings forced.".
    PRINT "Sequence -> " + _landingSequenceForPhase(phaseName, assistPath):JOIN(" -> ") + ".".
    PRINT "Phase -> " + phaseName + ".".
    PRINT "Landing config synced from mission state.".

} ELSE {
    PRINT "Unknown mode '" + mode + "'. Use: deorbit | assist.".
}
