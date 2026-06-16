// ============================================================
// cmd/landat.ks  —  Land at picked coordinates from Kerbin orbit
// (0:/cmd/landat.ks)
//
// Generic point landing: sets up an automated
// KSC_DEORBIT,DESCENT,DONE mission and reboots into it. The
// deorbit burn is Trajectories-targeted at the chosen
// coordinates; DESCENT handles chutes/decoupler/fairing by tag
// through touchdown. Reboot-safe at every step.
//
// Picking the target (first match wins):
//   1. LEX("lat", x, "lng", y)       — explicit coordinates
//   2. LEX("waypoint", "Site B")     — Waypoint Manager waypoint
//      by name (must be on the current body)
//   3. no coords at all              — the waypoint currently
//      selected in Waypoint Manager ('activate navigation')
//
// Usage:
//   RUNPATH("0:/cmd/landat.ks").                  // selected waypoint
//   RUNPATH("0:/cmd/landat.ks", LEX("waypoint", "Drop Zone")).
//   RUNPATH("0:/cmd/landat.ks", LEX("lat", 12.5, "lng", -38.7)).
//
// Options (all optional, with defaults):
//   lat / lng        — impact target coordinates
//   waypoint         — Waypoint Manager waypoint name
//   name             — mission display name (default from target)
//   entry_pe / pe    — atmosphere-entry Pe in m (default 30000)
//   tolerance        — impact tolerance in m (default 15000)
//   max_orbits       — deorbit window scan limit (default 4)
//   samples          — coarse scan samples (default 32 per orbit)
//   refine           — TRUE re-enables iterative impact refinement
//   strict           — TRUE = hold unless a pass inside tolerance
//                      exists; default FALSE = fly the best pass
//   descent_fairing / descent_decoupler / descent_chutes — part
//       tags for DESCENT. Unset, craft CFG defaults (then lib
//       defaults) apply; 'none' disables a step outright.
//
// Reachability: the current orbit must overfly the target
// latitude (|lat| <= inclination) — checked up front, the
// command refuses rather than scanning forever.
//
// Requires Kerbin orbit and archive access.
// (cmd/landatksc.ks is the offshore-KSC preset wrapper.)
// ============================================================

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL FUNCTION _findWaypoint {
    PARAMETER wpName.   // "" = the selected waypoint
    FOR wp IN ALLWAYPOINTS() {
        IF wp:BODY:NAME = SHIP:BODY:NAME {
            IF (wpName <> "" AND wp:NAME = wpName)
                    OR (wpName = "" AND wp:ISSELECTED) {
                RETURN wp.
            }
        }
    }
    RETURN 0.
}

LOCAL targetLat IS 0.
LOCAL targetLng IS 0.
LOCAL targetLabel IS "".
LOCAL haveTarget IS FALSE.
LOCAL entryPe IS 30000.
LOCAL tolerance IS 15000.
LOCAL maxOrbits IS 4.
LOCAL scanSamples IS 0.
LOCAL strict IS FALSE.
LOCAL doRefine IS FALSE.
// Empty = leave mission state untouched so craft CFG defaults
// (then lib defaults) decide; "none" = explicitly disabled.
LOCAL descentFairingTag IS "".
LOCAL descentDecouplerTag IS "".
LOCAL descentChutesTag IS "".
LOCAL err IS FALSE.

// --- Resolve the target ---
IF opts:HASKEY("lat") AND opts:HASKEY("lng") {
    SET targetLat TO opts["lat"].
    SET targetLng TO opts["lng"].
    SET targetLabel TO ROUND(targetLat, 3) + "," + ROUND(targetLng, 3).
    SET haveTarget TO TRUE.
} ELSE IF opts:HASKEY("waypoint") {
    LOCAL wp IS _findWaypoint(opts["waypoint"]).
    IF wp:ISTYPE("Waypoint") {
        SET targetLat TO wp:GEOPOSITION:LAT.
        SET targetLng TO wp:GEOPOSITION:LNG.
        SET targetLabel TO wp:NAME.
        SET haveTarget TO TRUE.
    } ELSE {
        PRINT "ERROR: waypoint '" + opts["waypoint"] + "' not found on "
            + SHIP:BODY:NAME + ".".
        SET err TO TRUE.
    }
} ELSE {
    LOCAL wp IS _findWaypoint("").
    IF wp:ISTYPE("Waypoint") {
        SET targetLat TO wp:GEOPOSITION:LAT.
        SET targetLng TO wp:GEOPOSITION:LNG.
        SET targetLabel TO wp:NAME.
        SET haveTarget TO TRUE.
        PRINT "Using selected waypoint: " + wp:NAME.
    } ELSE {
        PRINT "ERROR: no target. Select a waypoint in Waypoint Manager,".
        PRINT "or pass LEX('lat', x, 'lng', y) or LEX('waypoint', 'Name').".
        SET err TO TRUE.
    }
}

LOCAL missionName IS "Land at " + targetLabel.
IF opts:HASKEY("name")              { SET missionName TO opts["name"]. }
IF opts:HASKEY("pe")                { SET entryPe TO opts["pe"]. }
IF opts:HASKEY("entry_pe")          { SET entryPe TO opts["entry_pe"]. }
IF opts:HASKEY("tolerance")         { SET tolerance TO opts["tolerance"]. }
IF opts:HASKEY("max_orbits")        { SET maxOrbits TO opts["max_orbits"]. }
IF opts:HASKEY("strict")            { SET strict TO opts["strict"]. }
IF opts:HASKEY("samples")           { SET scanSamples TO opts["samples"]. }
IF opts:HASKEY("refine")            { SET doRefine TO opts["refine"]. }
IF scanSamples <= 0 { SET scanSamples TO maxOrbits * 32. }
IF opts:HASKEY("descent_fairing")   { SET descentFairingTag TO opts["descent_fairing"]. }
IF opts:HASKEY("descent_decoupler") { SET descentDecouplerTag TO opts["descent_decoupler"]. }
IF opts:HASKEY("descent_chutes")    { SET descentChutesTag TO opts["descent_chutes"]. }

IF SHIP:BODY:NAME <> "Kerbin" {
    PRINT "ERROR: Must be in Kerbin orbit (body: " + SHIP:BODY:NAME + ").".
    SET err TO TRUE.
}
IF SHIP:STATUS <> "ORBITING" {
    PRINT "ERROR: Must be in stable orbit (status: " + SHIP:STATUS + ").".
    SET err TO TRUE.
}
IF haveTarget {
    LOCAL reachInc IS SHIP:ORBIT:INCLINATION.
    IF reachInc > 90 { SET reachInc TO 180 - reachInc. }
    IF ABS(targetLat) > reachInc + 0.5 {
        PRINT "ERROR: target lat " + ROUND(targetLat, 2)
            + " is outside this orbit's reach (inc "
            + ROUND(SHIP:ORBIT:INCLINATION, 2) + ").".
        PRINT "Change the orbital plane first (cmd/setincl.ks).".
        SET err TO TRUE.
    }
}

IF NOT err {

    archiveLog().

    // Mission identity with no matching .json so boot skips the
    // selector and leaves this state alone (returntokerbin trick).
    stateSet("target", "KERBIN").
    stateSet("mission_type", "kerbin_return").
    // Must NOT match any missions/<craft>/*.json filename, or boot
    // re-applies that cfg over this command's state (flight-found:
    // 'point_landing' collided with point_landing.json).
    stateSet("mission_id", "land_at_target").
    stateSet("mission_name", missionName).
    stateSet("payloads", "RETURN").

    stateSet("mission_cfg_SEQUENCE", "KSC_DEORBIT,DESCENT,DONE").
    // DESCENT is its own (lean) band; preloading descent lets it
    // bind during KSC_DEORBIT with no band-change reboot.
    stateSet("mission_cfg_LIBS_EXTRA", "descent").
    stateSet("mission_cfg_LANDING_TARGET_LAT", targetLat).
    stateSet("mission_cfg_LANDING_TARGET_LNG", targetLng).
    stateSet("mission_cfg_REENTRY_PE", entryPe).
    stateSet("mission_cfg_LANDING_TARGET_TOLERANCE", tolerance).
    // The waypoint is resolved to numbers above; clear any stale
    // name so the phase doesn't re-resolve something else.
    stateRemove("mission_cfg_LANDING_TARGET_WAYPOINT").

    // Targeted-deorbit scan settings (the proven landatksc recipe).
    stateSet("mission_cfg_TARGET_DEORBIT_SCAN_ORBITS", maxOrbits).
    stateSet("mission_cfg_TARGET_DEORBIT_SCAN_SAMPLES", scanSamples).
    stateSet("mission_cfg_TARGET_DEORBIT_COARSE_STOP_DIST", tolerance).
    stateSet("mission_cfg_TARGET_DEORBIT_REFINE_TOLERANCE", 1000).
    stateSet("mission_cfg_TARGET_DEORBIT_SKIP_REFINE",
        CHOOSE 0 IF doRefine ELSE 1).
    stateSet("mission_cfg_TARGET_DEORBIT_PROCEED_ON_MISS",
        CHOOSE 0 IF strict ELSE 1).
    // 300s, not 90: a small reaction wheel (no SAS core) needs
    // real time to despin and align — flight-found: a 36s-out
    // node arrived with the craft pointing the wrong way.
    stateSet("mission_cfg_TARGET_DEORBIT_MIN_LEAD", 300).

    IF descentFairingTag <> "" {
        stateSet("mission_cfg_DESCENT_FAIRING_TAG", descentFairingTag).
    } ELSE {
        stateRemove("mission_cfg_DESCENT_FAIRING_TAG").
    }
    IF descentDecouplerTag <> "" {
        stateSet("mission_cfg_DESCENT_DECOUPLER_TAG", descentDecouplerTag).
    } ELSE {
        stateRemove("mission_cfg_DESCENT_DECOUPLER_TAG").
    }
    IF descentChutesTag <> "" {
        stateSet("mission_cfg_DESCENT_CHUTES_TAG", descentChutesTag).
    } ELSE {
        stateRemove("mission_cfg_DESCENT_CHUTES_TAG").
    }

    stateSet("phase", "KSC_DEORBIT").
    stateSet("launch_time", ROUND(TIME:SECONDS)).

    PRINT " ".
    PRINT "Point landing configured:".
    PRINT "  Mission:   " + missionName.
    PRINT "  Sequence:  KSC_DEORBIT,DESCENT,DONE".
    PRINT "  Target:    " + ROUND(targetLat, 4) + ", " + ROUND(targetLng, 4)
        + "  (tol " + ROUND(tolerance / 1000, 0) + "km)".
    PRINT "  Window:    next " + maxOrbits + " orbits  ("
        + (CHOOSE "strict: hold on miss" IF strict
           ELSE "best pass flies") + ")".
    PRINT "  Entry PE:  " + entryPe + "m (" + ROUND(entryPe / 1000, 1) + "km)".
    PRINT "  Descent:   fairing=" + (CHOOSE descentFairingTag IF descentFairingTag <> "" ELSE "(craft default)")
        + " decoupler=" + (CHOOSE descentDecouplerTag IF descentDecouplerTag <> "" ELSE "(craft default)")
        + " chutes=" + (CHOOSE descentChutesTag IF descentChutesTag <> "" ELSE "(craft default)").
    PRINT " ".
    PRINT "Reboot to begin the landing.".
}
