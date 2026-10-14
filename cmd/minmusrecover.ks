// ============================================================
// minmusrecover.ks — select RO8 landing recovery from Minmus orbit.
// Run connected: RUNPATH("0:/cmd/minmusrecover.ks"). Then REBOOT.
// All library calls run inside this script, not from the console prompt.
// ============================================================

RUNPATH("1:/lib/boot_lib").
bootPreamble().

IF stateGet("vehicle", "") <> "RO8" {
    PRINT "Minmus landing recovery requires an RO8 vessel.".
} ELSE IF SHIP:BODY:NAME <> "Minmus" OR SHIP:STATUS <> "ORBITING" {
    PRINT "Minmus landing recovery requires a stable Minmus orbit.".
} ELSE IF HASNODE {
    PRINT "Remove the old maneuver node before selecting landing recovery, then rerun this command.".
} ELSE IF NOT HOMECONNECTION:ISCONNECTED {
    PRINT "Connect to the archive before selecting landing recovery.".
} ELSE IF NOT EXISTS("0:/missions/RO8/minmus_landing_recovery.ks") {
    PRINT "Sync the archive first: Minmus landing recovery profile is missing.".
} ELSE {
    // Cache the profile before changing mission intent.
    LOCAL profilePath IS missionProfileBegin("RO8", "minmus_landing_recovery").
    COPYPATH("0:/missions/RO8/minmus_landing_recovery.ks", profilePath).
    missionOverrideClear().
    stateSet("target", "Minmus").
    stateSet("mission_id", "minmus_landing_recovery").
    stateSet("mission_name", "RO8 Minmus Landing Recovery and Return").
    stateSet("phase", "LAND_DEORBIT").
    stateSet("reload_required", "false").
    stateSet("reload_reason", "").
    stateSet("reload_next_phase", "").
    stateSet("reload_next_band", "").
    PRINT "Minmus landing recovery selected; old mission overrides cleared.".
    PRINT "Nearby scanned site, then surface science and fuel-review hold.".
    PRINT "REBOOT with the archive link available to load the landing libraries.".
}
