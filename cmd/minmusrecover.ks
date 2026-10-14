// ============================================================
// minmusrecover.ks — select RO8 landing recovery from Minmus orbit.
// Run connected: RUNPATH("0:/cmd/minmusrecover.ks"). Then REBOOT.
// For a visually chosen, selected Minmus waypoint (no SCANsat required):
// RUNPATH("0:/cmd/minmusrecover.ks", "waypoint"). Then REBOOT.
// All library calls run inside this script, not from the console prompt.
// ============================================================

PARAMETER siteMode IS "auto".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

// Snapshot the operator's choice now; later waypoint selection changes
// must not redirect the probe after reboot.
LOCAL selected IS 0.
IF siteMode = "waypoint" {
    FOR wp IN ALLWAYPOINTS() {
        IF wp:ISSELECTED AND wp:BODY:NAME = "Minmus" {
            SET selected TO wp.
            BREAK.
        }
    }
}

IF stateGet("vehicle", "") <> "RO8" {
    PRINT "Minmus landing recovery requires an RO8 vessel.".
} ELSE IF SHIP:BODY:NAME <> "Minmus" OR SHIP:STATUS <> "ORBITING" {
    PRINT "Minmus landing recovery requires a stable Minmus orbit.".
} ELSE IF HASNODE {
    PRINT "Remove the old maneuver node before selecting landing recovery, then rerun this command.".
} ELSE IF siteMode <> "auto" AND siteMode <> "waypoint" {
    PRINT "Use auto for a scanned site, or waypoint for a visually chosen selected site.".
} ELSE IF siteMode = "waypoint" AND selected = 0 {
    PRINT "Select your landing waypoint on Minmus first, then rerun with waypoint mode.".
} ELSE IF NOT HOMECONNECTION:ISCONNECTED {
    PRINT "Connect to the archive before selecting landing recovery.".
} ELSE IF NOT EXISTS("0:/missions/RO8/minmus_landing_recovery.ks") {
    PRINT "Sync the archive first: Minmus landing recovery profile is missing.".
} ELSE {
    // Cache the profile before changing mission intent.
    LOCAL profilePath IS missionProfileBegin("RO8", "minmus_landing_recovery").
    COPYPATH("0:/missions/RO8/minmus_landing_recovery.ks", profilePath).
    missionOverrideClear().
    IF siteMode = "waypoint" {
        LOG "SET TARGET_LAT TO " + configLiteral(selected:GEOPOSITION:LAT) + "." TO missionOverridePath().
        LOG "SET TARGET_LNG TO " + configLiteral(selected:GEOPOSITION:LNG) + "." TO missionOverridePath().
        LOG "SET TARGET_LOCK TO 1." TO missionOverridePath().
        LOG "SET TARGET_WAYPOINT TO " + configLiteral("") + "." TO missionOverridePath().
        LOG "SET LANDING_USE_WAYPOINTS TO 0." TO missionOverridePath().
        LOG "SET LANDING_AUTO_TARGET TO 0." TO missionOverridePath().
        // Explicit visual selection replaces the map-coverage requirement.
        // Keep Trajectories, approach/terrain checks and powered descent.
        LOG "SET LANDING_SITE_SCAN_ENABLE TO 0." TO missionOverridePath().
        LOG "SET LANDING_REQUIRE_SITE TO 0." TO missionOverridePath().
        PRINT "Landing waypoint: " + selected:NAME + " lat="
            + ROUND(selected:GEOPOSITION:LAT,4)
            + " lng=" + ROUND(selected:GEOPOSITION:LNG,4).
        PRINT "Visual site selected; SCANsat coverage not required. Terrain checks remain enabled.".
    }
    stateSet("target", "Minmus").
    stateSet("mission_id", "minmus_landing_recovery").
    stateSet("mission_name", "RO8 Minmus Landing Recovery and Return").
    stateSet("phase", "LAND_DEORBIT").
    stateSet("reload_required", "false").
    stateSet("reload_reason", "").
    stateSet("reload_next_phase", "").
    stateSet("reload_next_band", "").
    PRINT "Minmus landing recovery selected; old mission overrides cleared.".
    IF siteMode = "auto" { PRINT "Automatic site selection requires SCANsat coverage.". }
    PRINT "Landing is followed by surface science and a fuel-review hold.".
    PRINT "REBOOT with the archive link available to load the landing libraries.".
}
