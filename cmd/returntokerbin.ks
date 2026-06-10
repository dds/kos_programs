// ============================================================
// cmd/returntokerbin.ks  —  Configure return-to-Kerbin mission
// (0:/cmd/returntokerbin.ks)
//
// Sets up a full automated return mission sequence
// (ESCAPE, MCC, COAST, AEROBRAKE, DONE) and reboots.
// The phase machine handles escape burn, mid-course correction,
// coast to Kerbin SOI, and aerobrake entry with KSC targeting.
//
// Usage:
//   RUNPATH("0:/cmd/returntokerbin.ks").
//   RUNPATH("0:/cmd/returntokerbin.ks", LEX("pe", 52000)).
//   RUNPATH("0:/cmd/returntokerbin.ks", LEX(
//       "pe", 43000,
//       "reentry_dir", "retrograde",
//       "decouple_tag", "aero_decouple",
//       "arm_chutes", 1,
//       "ksc_target", true
//   )).
//
// Options (all optional, with defaults):
//   pe            — Kerbin PE in meters (default 43000)
//   reentry_dir   — "retrograde" or "prograde" (default "retrograde")
//   decouple_tag       — part tag for aerobrake phase decoupler (default: none)
//   arm_chutes         — 1 to arm parachutes in aerobrake phase (default 0)
//   ksc_target         — true to enable KSC targeting (default true)
//   descent_fairing    — part tag for fairing to deploy at < 60 m/s (default: none)
//   descent_decoupler  — part tag for decoupler to fire at ~6km (default: none)
//   descent_chutes     — part tag for parachutes to arm on entry (default: all chutes)
//
// Requires archive access (KSC link or relay).
// For a return to Kerbin ORBIT (no aerobrake/descent), use
// cmd/goto.ks instead: RUNPATH("0:/cmd/goto.ks", "Kerbin").
// ============================================================

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().

// --- Read options with defaults ---
// Default honors the mission profile's REENTRY_PE when set.
LOCAL targetPe IS stateGetNum("mission_cfg_REENTRY_PE", 43000).
LOCAL reentryDir IS "RETROGRADE".
LOCAL decoupleTag IS "".
LOCAL armChutes IS 0.
LOCAL kscTarget IS TRUE.
LOCAL descentFairingTag IS "descent_fairing".
LOCAL descentDecouplerTag IS "descent_decoupler".
LOCAL descentChutesTag IS "descent_chutes".
LOCAL err IS FALSE.

IF opts:HASKEY("pe")                 { SET targetPe TO opts["pe"]. }
IF opts:HASKEY("reentry_pe")         { SET targetPe TO opts["reentry_pe"]. }
IF opts:HASKEY("reentry_dir")        { SET reentryDir TO opts["reentry_dir"]:TOUPPER. }
IF opts:HASKEY("decouple_tag")       { SET decoupleTag TO opts["decouple_tag"]. }
IF opts:HASKEY("arm_chutes")         { SET armChutes TO opts["arm_chutes"]. }
IF opts:HASKEY("ksc_target")         { SET kscTarget TO opts["ksc_target"]. }
IF opts:HASKEY("descent_fairing")    { SET descentFairingTag TO opts["descent_fairing"]. }
IF opts:HASKEY("descent_decoupler")  { SET descentDecouplerTag TO opts["descent_decoupler"]. }
IF opts:HASKEY("descent_chutes")    { SET descentChutesTag TO opts["descent_chutes"]. }

// Validate we're orbiting Mun or Minmus
IF BODY:NAME <> "Mun" AND BODY:NAME <> "Minmus" {
    PRINT "ERROR: Must be orbiting Mun or Minmus.".
    PRINT "Current body: " + BODY:NAME.
    SET err TO TRUE.
}
IF SHIP:STATUS <> "ORBITING" {
    PRINT "ERROR: Must be in stable orbit.".
    PRINT "Current status: " + SHIP:STATUS.
    SET err TO TRUE.
}

IF NOT err {

    // Archive the current flight log before starting the return mission
    archiveLog().
    PRINT "Flight log archived.".

    // Set up the return mission identity.
    // mission_id must be set to a name that has no matching .cfg file
    // so boot skips the mission selector AND bootApplyMissionConfig
    // finds nothing to overwrite our state with.
    stateSet("target", "KERBIN").
    stateSet("mission_type", "kerbin_return").
    stateSet("mission_id", "kerbin_return").
    stateSet("mission_name", "Return to Kerbin").
    stateSet("payloads", "RETURN").

    // Set up the return mission sequence and config
    LOCAL returnSeq IS "ESCAPE,COAST,MCC,AEROBRAKE,DESCENT,DONE".
    stateSet("mission_cfg_SEQUENCE", returnSeq).
    stateSetNum("mission_cfg_ESCAPE_PE", targetPe).
    stateSet("mission_cfg_AEROBRAKE_REENTRY_DIR", reentryDir).

    IF kscTarget {
        stateSet("mission_cfg_ESCAPE_KSC_TARGET", "true").
    } ELSE {
        stateRemove("mission_cfg_ESCAPE_KSC_TARGET").
    }

    IF decoupleTag <> "" {
        stateSet("mission_cfg_AEROBRAKE_DECOUPLE_TAG", decoupleTag).
    } ELSE {
        stateRemove("mission_cfg_AEROBRAKE_DECOUPLE_TAG").
    }

    IF armChutes > 0 {
        stateSetNum("mission_cfg_AEROBRAKE_ARM_CHUTES", armChutes).
    } ELSE {
        stateRemove("mission_cfg_AEROBRAKE_ARM_CHUTES").
    }

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

    // Clear outbound capture config so it doesn't interfere
    FOR key IN LIST("CAPTURE_LAN", "CAPTURE_AOP", "CAPTURE_INC", "CAPTURE_DIR") {
        stateRemove("mission_cfg_" + key).
    }

    // Reset phase to start of return sequence
    stateSet("phase", "ESCAPE").

    // Bump launch_time so the new flight log gets a fresh timestamp
    stateSetNum("launch_time", ROUND(TIME:SECONDS)).

    PRINT " ".
    PRINT "Return to Kerbin configured:".
    PRINT "  Sequence:    " + returnSeq.
    PRINT "  Target PE:   " + targetPe + "m (" + ROUND(targetPe/1000,1) + "km)".
    PRINT "  Reentry dir: " + reentryDir.
    PRINT "  KSC target:  " + kscTarget.
    IF decoupleTag <> "" { PRINT "  Decouple:    " + decoupleTag. }
    IF armChutes > 0     { PRINT "  Arm chutes:  yes". }
    IF descentFairingTag <> "" { PRINT "  Fairing:     " + descentFairingTag. }
    IF descentDecouplerTag <> "" { PRINT "  Decoupler:   " + descentDecouplerTag. }
    IF descentChutesTag <> "" { PRINT "  Chutes:      " + descentChutesTag. }
    PRINT "  From:        " + BODY:NAME.
    PRINT " ".
    PRINT "Reboot to start return mission...".
}
