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
LOCAL descentFairingTag IS "descent_fairing".
LOCAL descentDecouplerTag IS "descent_decoupler".
LOCAL descentChutesTag IS "descent_chutes".
LOCAL err IS FALSE.

IF opts:HASKEY("lat")               { SET targetLat TO opts["lat"]. }
IF opts:HASKEY("lng")               { SET targetLng TO opts["lng"]. }
IF opts:HASKEY("pe")                { SET entryPe TO opts["pe"]. }
IF opts:HASKEY("entry_pe")          { SET entryPe TO opts["entry_pe"]. }
IF opts:HASKEY("tolerance")         { SET tolerance TO opts["tolerance"]. }
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

    // Targeted-deorbit scan settings (same recipe as kscsplash).
    stateSetNum("mission_cfg_TARGET_DEORBIT_SCAN_ORBITS", 32).
    stateSetNum("mission_cfg_TARGET_DEORBIT_SCAN_SAMPLES", 2048).
    stateSetNum("mission_cfg_TARGET_DEORBIT_COARSE_STOP_DIST", tolerance).
    stateSetNum("mission_cfg_TARGET_DEORBIT_REFINE_TOLERANCE", 1000).
    stateSetNum("mission_cfg_TARGET_DEORBIT_PROCEED_ON_MISS", 0).
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
    PRINT "  Entry PE:  " + entryPe + "m (" + ROUND(entryPe / 1000, 1) + "km)".
    PRINT "  Descent:   fairing=" + descentFairingTag
        + " decoupler=" + descentDecouplerTag
        + " chutes=" + descentChutesTag.
    PRINT " ".
    PRINT "Reboot to begin the landing.".
}
