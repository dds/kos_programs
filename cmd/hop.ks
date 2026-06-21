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
        "prelaunch_plane_ut", "prelaunch_plane_target",
        "prelaunch_plane_inc", "prelaunch_plane_lan"
    ) {
        stateRemove(key).
    }
}

LOCAL profilePath IS missionProfileBegin(stateGet("vehicle", ""), "hop").
missionOverrideClear().
LOG "SET MISSION_ID TO " + configLiteral("hop") + "." TO profilePath.
LOG "SET MISSION_NAME TO " + configLiteral("Hop") + "." TO profilePath.
LOG "SET TARGET_ TO " + configLiteral(SHIP:BODY:NAME:TOUPPER) + "." TO profilePath.
LOG "SET SEQUENCE TO " + configLiteral(LIST("PRELAUNCH", "HOP", "LAND_ASSIST", "DONE")) + "." TO profilePath.
LOG "SET LAUNCH_PLANE_MODE TO " + configLiteral("SUBORBITAL") + "." TO profilePath.
LOG "SET HOP_TARGET_LAT TO " + configLiteral(targetLat) + "." TO profilePath.
LOG "SET HOP_TARGET_LNG TO " + configLiteral(targetLng) + "." TO profilePath.
LOG "SET HOP_TOLERANCE TO " + configLiteral(toleranceM) + "." TO profilePath.
LOG "SET HOP_PITCH TO " + configLiteral(pitchDeg) + "." TO profilePath.
LOG "SET HOP_MAX_BURN_SECONDS TO " + configLiteral(maxBurnSeconds) + "." TO profilePath.
LOG "SET HOP_MAX_AP_KM TO " + configLiteral(maxApKm) + "." TO profilePath.
LOG "SET HOP_TWR TO " + configLiteral(hopTwr) + "." TO profilePath.
LOG "SET RELOAD_AFTER_LAND_ASSIST TO " + configLiteral(0) + "." TO profilePath.

stateSet("mission_id", "hop").
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
