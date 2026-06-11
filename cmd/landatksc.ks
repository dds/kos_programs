// ============================================================
// cmd/landatksc.ks  —  Land near KSC from Kerbin orbit
// (0:/cmd/landatksc.ks)
//
// The from-orbit sibling of returntokerbin: sets up an automated
// KSC_DEORBIT,DESCENT,DONE mission and reboots into it. The
// deorbit burn is Trajectories-targeted at the water just
// offshore of KSC; DESCENT handles chutes/decoupler/fairing by
// tag through touchdown. Reboot-safe at every step.
//
// (cmd/kscsplash.ks remains the one-shot version: it flies only
// the burn and leaves entry to the operator.)
//
// Usage:
//   RUNPATH("0:/cmd/landatksc.ks").
//   RUNPATH("0:/cmd/landatksc.ks", LEX("entry_pe", 25000)).
//   RUNPATH("0:/cmd/landatksc.ks", LEX(
//       "lat", -0.10, "lng", -74.25,
//       "tolerance", 10000,
//       "descent_decoupler", "descent_decoupler",
//       "descent_chutes", "descent_chutes"
//   )).
//
// Options (all optional, with defaults):
//   lat / lng        — impact target (default offshore KSC)
//   entry_pe / pe    — atmosphere-entry Pe in m (default 30000)
//   tolerance        — impact tolerance in m (default 15000)
//   max_orbits       — deorbit window scan limit (default 4)
//   samples          — coarse scan samples across the window
//       (default 32 per orbit — each costs a Trajectories sim)
//   refine           — TRUE re-enables the iterative impact
//       refinement (off by default: slow, sometimes
//       non-converging, and chute landings don't need ~1km)
//   strict           — TRUE = hold unless a pass inside tolerance
//       exists in the window. Default FALSE: fly the BEST pass
//       found — essential from polar orbits, where the ground
//       track shifts ~40 deg/pass and sub-15km KSC overflights
//       can be many hours apart (flight-found: 18h of scanning
//       with the best pass still 96km out).
//   descent_fairing / descent_decoupler / descent_chutes — part
//       tags for the DESCENT phase (defaults match returntokerbin)
//
// Requires Kerbin orbit and archive access.
// ============================================================

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL targetLat IS -0.10.
LOCAL targetLng IS -74.25.
LOCAL entryPe IS 30000.
LOCAL tolerance IS 15000.
LOCAL maxOrbits IS 4.
LOCAL scanSamples IS 0.
LOCAL strict IS FALSE.
LOCAL doRefine IS FALSE.
LOCAL descentFairingTag IS "descent_fairing".
LOCAL descentDecouplerTag IS "descent_decoupler".
LOCAL descentChutesTag IS "descent_chutes".
LOCAL err IS FALSE.

IF opts:HASKEY("lat")               { SET targetLat TO opts["lat"]. }
IF opts:HASKEY("lng")               { SET targetLng TO opts["lng"]. }
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

IF NOT err {

    archiveLog().

    // Mission identity with no matching .cfg so boot skips the
    // selector and leaves this state alone (returntokerbin trick).
    stateSet("target", "KERBIN").
    stateSet("mission_type", "kerbin_return").
    stateSet("mission_id", "ksc_landing").
    stateSet("mission_name", "Land at KSC").
    stateSet("payloads", "RETURN").

    stateSet("mission_cfg_SEQUENCE", "KSC_DEORBIT,DESCENT,DONE").
    stateSetNum("mission_cfg_LANDING_TARGET_LAT", targetLat).
    stateSetNum("mission_cfg_LANDING_TARGET_LNG", targetLng).
    stateSetNum("mission_cfg_REENTRY_PE", entryPe).
    stateSetNum("mission_cfg_LANDING_TARGET_TOLERANCE", tolerance).

    // Targeted-deorbit scan settings (kscsplash recipe, but a
    // tighter window: 32 orbits could schedule the burn most of
    // a day out and doubled the scan's compute time).
    stateSetNum("mission_cfg_TARGET_DEORBIT_SCAN_ORBITS", maxOrbits).
    // Coarse samples only need to FIND the close-approach dip
    // (refine polishes it to ~1km); 2048 was one Trajectories
    // simulation every ~10s of trajectory and took forever.
    stateSetNum("mission_cfg_TARGET_DEORBIT_SCAN_SAMPLES", scanSamples).
    stateSetNum("mission_cfg_TARGET_DEORBIT_COARSE_STOP_DIST", tolerance).
    stateSetNum("mission_cfg_TARGET_DEORBIT_REFINE_TOLERANCE", 1000).
    // Fast by default: fly the coarse+pass result without the
    // iterative impact refinement (LEX("refine", TRUE) re-enables).
    stateSetNum("mission_cfg_TARGET_DEORBIT_SKIP_REFINE",
        CHOOSE 0 IF doRefine ELSE 1).
    stateSetNum("mission_cfg_TARGET_DEORBIT_PROCEED_ON_MISS",
        CHOOSE 0 IF strict ELSE 1).
    stateSetNum("mission_cfg_TARGET_DEORBIT_MIN_LEAD", 90).

    stateSet("mission_cfg_DESCENT_FAIRING_TAG", descentFairingTag).
    stateSet("mission_cfg_DESCENT_DECOUPLER_TAG", descentDecouplerTag).
    stateSet("mission_cfg_DESCENT_CHUTES_TAG", descentChutesTag).

    stateSet("phase", "KSC_DEORBIT").
    stateSetNum("launch_time", ROUND(TIME:SECONDS)).

    PRINT " ".
    PRINT "KSC landing configured:".
    PRINT "  Sequence:  KSC_DEORBIT,DESCENT,DONE".
    PRINT "  Target:    " + ROUND(targetLat, 4) + ", " + ROUND(targetLng, 4)
        + "  (tol " + ROUND(tolerance / 1000, 0) + "km)".
    PRINT "  Window:    next " + maxOrbits + " orbits  ("
        + (CHOOSE "strict: hold on miss" IF strict
           ELSE "best pass flies") + ")".
    PRINT "  Entry PE:  " + entryPe + "m (" + ROUND(entryPe / 1000, 1) + "km)".
    PRINT "  Descent:   fairing=" + descentFairingTag
        + " decoupler=" + descentDecouplerTag
        + " chutes=" + descentChutesTag.
    PRINT " ".
    PRINT "Reboot to begin the landing.".
}
