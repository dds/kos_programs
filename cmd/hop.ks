// cmd/hop.ks - Configure a ballistic surface hop phase.
// Usage:
//   RUNPATH("0:/cmd/hop.ks", 0, -98.39).
//   RUNPATH("0:/cmd/hop.ks", 0, -98.39, 750, 45, 90, 10).
//
// Args: lat, lng, tolerance meters, pitch deg, max burn sec, max Ap km.

PARAMETER targetLat.
PARAMETER targetLng.
PARAMETER toleranceM IS 750.
PARAMETER pitchDeg IS 45.
PARAMETER maxBurnSeconds IS 90.
PARAMETER maxApKm IS 10.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL maxApM IS maxApKm * 1000.
IF maxApKm > 1000 { SET maxApM TO maxApKm. }

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

_cfg("SEQUENCE", "HOP,LAND_ASSIST,DONE").
_cfg("HOP_TARGET_LAT", targetLat).
_cfg("HOP_TARGET_LNG", targetLng).
_cfg("HOP_TOLERANCE", toleranceM).
_cfg("HOP_PITCH", pitchDeg).
_cfg("HOP_MAX_BURN_SECONDS", maxBurnSeconds).
_cfg("HOP_MAX_AP_KM", maxApKm).
_cfg("RELOAD_AFTER_LAND_ASSIST", 0).

stateSet("phase", "HOP").
stateSet("lib_band", "LAUNCH").
stateSet("reload_required", "false").
stateSet("launch_time", ROUND(TIME:SECONDS)).
_clearLibCache().
_clearHopLegState().

PRINT "Hop phase armed.".
PRINT "Sequence -> HOP,LAND_ASSIST,DONE.".
PRINT "Target   -> " + ROUND(targetLat, 5) + ", " + ROUND(targetLng, 5) + ".".
PRINT "Limits   -> Ap " + ROUND(maxApM / 1000, 1)
    + " km, burn " + ROUND(maxBurnSeconds, 0) + " s.".
PRINT "Rebooting to load HOP phase.".

mLog("Hop command armed: target=" + ROUND(targetLat, 5)
    + "," + ROUND(targetLng, 5)
    + " tolerance=" + ROUND(toleranceM, 0)
    + "m pitch=" + ROUND(pitchDeg, 1)
    + " maxBurn=" + ROUND(maxBurnSeconds, 0)
    + "s maxApKm=" + ROUND(maxApM / 1000, 1) + ".").

REBOOT.
