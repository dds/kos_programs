// ============================================================
// munrecover.ks — switch the in-flight RO8 to capture-only recovery.
// Run with an archive link: RUNPATH("0:/cmd/munrecover.ks").
// ============================================================
RUNPATH("1:/lib/boot_lib").
bootPreamble().

IF stateGet("vehicle", "") <> "RO8" {
    PRINT "Mun recovery is for RO8; vehicle state does not match.".
} ELSE IF SHIP:BODY:NAME <> "Kerbin" AND SHIP:BODY:NAME <> "Mun" {
    PRINT "Mun recovery requires a Kerbin approach or a vessel at the Mun.".
} ELSE IF SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED"
        OR SHIP:STATUS = "SPLASHED" {
    PRINT "Mun recovery is an in-flight mission.".
} ELSE {
    // Cache the profile before changing intent so a disconnected reboot
    // can still find it. Connected boot refreshes the flight libraries.
    LOCAL profilePath IS missionProfileBegin("RO8", "mun_capture_recovery").
    COPYPATH("0:/missions/RO8/mun_capture_recovery.ks", profilePath).
    SET WARP TO 0.
    LOCK THROTTLE TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    missionOverrideClear().
    // This explicitly abandons old maneuver intent, never its fuel ledger.
    stateRemovePrefix("burn_").
    FOR key IN LIST("xing_arrival_ut", "midcourse_refine_ut",
            "midcourse_refine_arrival_ut", "lib_band_libs") {
        stateRemove(key).
    }
    stateSet("target", "Mun").
    stateSet("mission_id", "mun_capture_recovery").
    stateSet("mission_name", "RO8 Mun Capture Recovery").
    stateSet("phase", "BPLANE").
    IF SHIP:BODY:NAME = "Mun" { stateSet("phase", "CAPTURE"). }
    stateSet("reload_required", "false").
    stateSet("reload_reason", "").
    stateSet("reload_next_phase", "").
    stateSet("reload_next_band", "").
    PRINT "Mun recovery selected: 15 x 100 km capture, science, then hold.".
    PRINT "REBOOT with the archive link available to load the fix.".
}
