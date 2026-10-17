// ============================================================
// landlight.ks — Preview/apply a lit ground-track site from moon orbit.
// RUNPATH("0:/cmd/landlight.ks").
// RUNPATH("0:/cmd/landlight.ks", "apply", "MORNING", 1).
// RUNPATH("0:/cmd/landlight.ks", "preview", "AFTERNOON", 1).
// RUNPATH("0:/cmd/landlight.ks", "status"). // saved policy/site, live geometry
// Final argument: 1 requires direct Kerbin view; 0 permits relay coverage.
// Apply replaces the unflown deorbit node/target, preserving mission intent.
// ============================================================
@LAZYGLOBAL OFF.
PARAMETER action IS "preview", mode IS "MORNING", requireKerbin IS 1.

LOCAL FUNCTION _cmdLandlight {
    IF action <> "preview" AND action <> "apply" AND action <> "status" {
        PRINT "Use status/preview/apply, mode ANY/SUNLIT/MORNING/AFTERNOON, Kerbin view 0/1.". RETURN.
    }
    IF (mode <> "ANY" AND mode <> "SUNLIT" AND mode <> "MORNING" AND mode <> "AFTERNOON")
            OR (requireKerbin <> 0 AND requireKerbin <> 1) {
        PRINT "Invalid light mode or Kerbin-view flag.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("landing_deorbit").
    // Current flights can still have an older dependency manifest until
    // reboot. Load explicitly after the existing landing config/math deps.
    bootLibLoad("landing_light_math").
    bootLibLoad("landing_light").
    LOCAL profilePath IS "1:/missions/" + stateGet("vehicle", "")
        + "/" + stateGet("mission_id", "") + ".ks".
    IF NOT EXISTS(profilePath) { PRINT "Cached mission profile missing; cannot preserve mission context.". RETURN. }
    RUNPATH(profilePath).
    applyMissionOverrides().
    IF action = "status" {
        PRINT "Saved light policy=" + LANDING_LIGHT_MODE + "; require Kerbin=" + LANDING_REQUIRE_KERBIN
            + "; minimum Kerbin elevation=" + LANDING_KERBIN_MIN_ELEV + " deg.".
        LOCAL targetInfo IS landingResolveTarget().
        IF NOT targetInfo["FOUND"] { PRINT "No saved landing target resolved.". RETURN. }
        LOCAL geo IS LATLNG(targetInfo["LAT"], targetInfo["LNG"]).
        LOCAL liveKerbin IS landingKerbinElevationNow(geo:LAT, geo:LNG).
        LOCAL predicted IS landingLightAt(geo:LAT, geo:LNG, TIME:SECONDS + 1800).
        PRINT "Saved target=" + ROUND(geo:LAT,4) + "," + ROUND(geo:LNG,4).
        PRINT "Kerbin elevation at target NOW (live positions)=" + ROUND(liveKerbin,2) + " deg.".
        PRINT "Target T+1800s: Kerbin=" + ROUND(predicted["KERBIN"],2)
            + " Sun=" + ROUND(predicted["SUN"],2) + " deg; reason=" + predicted["REASON"].
        PRINT "Current vessel home connection=" + HOMECONNECTION:ISCONNECTED + " (not a surface-site forecast).".
        RETURN.
    }
    IF stateGet("phase", "") <> "LAND_DEORBIT"
            OR stateGet("deorbit_burn_started", "false") = "true"
            OR (SHIP:BODY:NAME <> "Mun" AND SHIP:BODY:NAME <> "Minmus")
            OR SHIP:STATUS <> "ORBITING" OR SHIP:PERIAPSIS <= 0
            OR SHIP:ORBIT:ECCENTRICITY >= 1 {
        PRINT "Requires LAND_DEORBIT in a bound Mun/Minmus parking orbit. Do not use after deorbit ignition.". RETURN.
    }
    IF ABORT OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Requires abort clear, zero throttle and zero thrust.". RETURN.
    }
    SET WARP TO 0.
    UNTIL KUNIVERSE:TIMEWARP:ISSETTLED { WAIT 0.1. }
    SET LANDING_LIGHT_MODE TO mode.
    SET LANDING_REQUIRE_KERBIN TO requireKerbin.
    PRINT "Searching ground track: " + mode + ", require Kerbin=" + requireKerbin.
    LOCAL site IS landingLitGroundTrack().
    IF NOT site["FOUND"] {
        PRINT "No eligible site within " + LANDING_LIGHT_SCAN_ORBITS + " orbits; last rejection=" + site["REASON"].
        PRINT "Node, target overrides and phase preserved. Review orbit/policy or wait for another solar phase.". RETURN.
    }
    PRINT "Site " + ROUND(site["LAT"],4) + ", " + ROUND(site["LNG"],4)
        + "  pass T+" + ROUND(site["UT"] - TIME:SECONDS,0) + "s".
    PRINT "Sun elevation=" + ROUND(site["SUN"],1) + " deg; Kerbin=" + ROUND(site["KERBIN"],1) + " deg.".
    LOCAL kerbinNow IS landingKerbinElevationNow(site["LAT"], site["LNG"]).
    PRINT "Kerbin at this site NOW (independent live positions)=" + ROUND(kerbinNow,1) + " deg.".
    PRINT "Geometric screen only: terrain shadows, antenna range and relay routing are not verified.".
    IF action = "preview" {
        PRINT "Preview complete; node and saved mission unchanged. Use apply to select, then REBOOT.". RETURN.
    }
    // Recheck live conditions after the search, before changing saved intent.
    IF ABORT OR SHIP:STATUS <> "ORBITING" OR SHIP:THRUST > 0.001
            OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Vehicle state changed during search; nothing applied.". RETURN.
    }
    missionOverrideUpdate(LEXICON("TARGET_LAT", site["LAT"], "TARGET_LNG", site["LNG"],
        "TARGET_LOCK", 1, "TARGET_WAYPOINT", "", "LANDING_USE_WAYPOINTS", 0,
        "LANDING_SKIP_TARGET_SEARCH", 0, "LANDING_LIGHT_MODE", mode,
        "LANDING_REQUIRE_KERBIN", requireKerbin)).
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    PRINT "Applied site; old unflown deorbit node removed. Mission/return sequence preserved.".
    PRINT "REBOOT when ready to plan and execute the new deorbit. No burn was started by this command.".
}

_cmdLandlight().
