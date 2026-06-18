// cmd/hop.ks - Configure a ballistic surface hop phase.
// Usage:
//   RUNPATH("0:/cmd/hop.ks", 0, -98.39).
//   RUNPATH("0:/cmd/hop.ks", 0, -98.39, 750, 45, 90, 5, 1.15).
//
// Args: lat, lng, tolerance meters, pitch deg, max burn sec, max Ap km,
//       vertical-component TWR.

PARAMETER targetLat.
PARAMETER targetLng.
PARAMETER toleranceM IS 750.
PARAMETER pitchDeg IS 45.
PARAMETER maxBurnSeconds IS 90.
PARAMETER maxApKm IS 5.
PARAMETER hopTwr IS 1.15.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL maxApM IS maxApKm * 1000.
IF maxApKm > 1000 { SET maxApM TO maxApKm. }
LOCAL clearedAbort IS FALSE.
IF ABORT {
    SET ABORT TO FALSE.
    SET clearedAbort TO TRUE.
}

LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

LOCAL FUNCTION _clearLibCache {
    FOR key IN LIST(
        "lib_band_libs", "lib_band_phase", "reload_reason",
        "reload_next_phase", "reload_next_band"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _clearHopLegState {
    FOR key IN LIST(
        "landing_state", "landing_lat", "landing_lng", "landing_time",
        "mission_cfg_TARGET_LAT", "mission_cfg_TARGET_LNG",
        "mission_cfg_TARGET_LOCK", "mission_cfg_TARGET_WAYPOINT"
    ) {
        stateRemove(key).
    }
}

_cfg("SEQUENCE", LIST("PRELAUNCH", "HOP", "LAND_ASSIST", "DONE")).
_cfg("LAUNCH_PLANE_MODE", "SUBORBITAL").
_cfg("HOP_TARGET_LAT", targetLat).
_cfg("HOP_TARGET_LNG", targetLng).
_cfg("HOP_TOLERANCE", toleranceM).
_cfg("HOP_PITCH", pitchDeg).
_cfg("HOP_MAX_BURN_SECONDS", maxBurnSeconds).
_cfg("HOP_MAX_AP_KM", maxApKm).
_cfg("HOP_TWR", hopTwr).
_cfg("RELOAD_AFTER_LAND_ASSIST", 0).

stateSet("phase", "PRELAUNCH").
stateSet("lib_band", "PRELAUNCH").
stateSet("reload_required", "false").
stateSet("launch_time", ROUND(TIME:SECONDS)).
_clearLibCache().
_clearHopLegState().

PRINT "Hop phase armed.".
PRINT "Sequence -> PRELAUNCH,HOP,LAND_ASSIST,DONE.".
PRINT "Target   -> " + ROUND(targetLat, 5) + ", " + ROUND(targetLng, 5) + ".".
PRINT "Limits   -> Ap " + ROUND(maxApM / 1000, 1)
    + " km, burn " + ROUND(maxBurnSeconds, 0)
    + " s, vertical TWR " + ROUND(hopTwr, 2) + ".".
IF clearedAbort { PRINT "Sticky ABORT cleared for hop ignition.". }
PRINT "Rebooting to load PRELAUNCH phase.".

mLog("Hop command armed: target=" + ROUND(targetLat, 5)
    + "," + ROUND(targetLng, 5)
    + " tolerance=" + ROUND(toleranceM, 0)
    + "m pitch=" + ROUND(pitchDeg, 1)
    + " maxBurn=" + ROUND(maxBurnSeconds, 0)
    + "s maxApKm=" + ROUND(maxApM / 1000, 1)
    + " hopTwr=" + ROUND(hopTwr, 2)
    + " clearedAbort=" + clearedAbort + ".").

REBOOT.
