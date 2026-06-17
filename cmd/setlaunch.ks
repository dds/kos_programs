// cmd/setlaunch.ks - Prep a landed craft for a fresh MJ2 ascent.
// Usage:
//   RUNPATH("0:/cmd/setlaunch.ks").          // 20 km equatorial orbit
//   RUNPATH("0:/cmd/setlaunch.ks", 25).      // 25 km orbit
//   RUNPATH("0:/cmd/setlaunch.ks", 25, 6).   // 25 km, 6 deg inclination

PARAMETER parkingKm IS 20.
PARAMETER launchInc IS 0.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL parkingAlt IS parkingKm * 1000.
IF parkingKm > 1000 { SET parkingAlt TO parkingKm. }

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

LOCAL FUNCTION _clearLaunchLegState {
    FOR key IN LIST(
        "fairing_deployed", "launch_vs_nonpos_logged",
        "orbit_start_time", "prelaunch_plane_ut",
        "prelaunch_plane_target", "prelaunch_plane_inc",
        "prelaunch_plane_lan", "landing_state",
        "landing_lat", "landing_lng", "landing_time"
    ) {
        stateRemove(key).
    }
}

_cfg("SEQUENCE", "LAUNCH,FAIR,ANTS,PARK,DONE").
_cfg("PARKING_ALT", parkingAlt).
_cfg("LAUNCH_INCLINATION", launchInc).
_cfg("LAUNCH_AZIMUTH", 0).
_cfg("ORBIT_STAY_TIME", 0).

stateSet("phase", "LAUNCH").
stateSet("lib_band", "LAUNCH").
stateSet("reload_required", "false").
stateSet("launch_time", ROUND(TIME:SECONDS)).
_clearLibCache().
_clearLaunchLegState().

PRINT "Launch reset for " + SHIP:BODY:NAME + ".".
PRINT "Sequence -> LAUNCH,FAIR,ANTS,PARK,DONE.".
PRINT "Orbit    -> " + ROUND(parkingAlt / 1000, 1)
    + " km, inc " + ROUND(launchInc, 2) + " deg.".
PRINT "Reboot to load launch band, then resume.".

mLog("Launch reset: body=" + SHIP:BODY:NAME
    + " parkingKm=" + ROUND(parkingAlt / 1000, 1)
    + " inc=" + ROUND(launchInc, 2)
    + " sequence=LAUNCH,FAIR,ANTS,PARK,DONE.").
