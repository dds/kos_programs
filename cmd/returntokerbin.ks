// ============================================================
// cmd/returntokerbin.ks  —  Configure return-to-Kerbin mission
// (0:/cmd/returntokerbin.ks)
//
// Sets up a full automated return mission sequence
// (ESCAPE, COAST, MCC, AEROBRAKE, DESCENT, DONE) and reboots.
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
//   descent_fairing    — part tag for fairing to deploy at < 60 m/s
//   descent_decoupler  — part tag for decoupler to fire at ~6km
//   descent_chutes     — part tag for parachutes to arm on entry
//       Descent tags default to craft/profile globals (then the
//       descent lib defaults); pass "none" to disable a step
//       (FR3 disables the decoupler — shed stage exploded next
//       to the lander at touchdown).
//
// Requires archive access (KSC link or relay).
// For a return to Kerbin ORBIT (no aerobrake/descent), use
// cmd/goto.ks instead: RUNPATH("0:/cmd/goto.ks", "Kerbin").
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL REENTRY_PE IS 30000.

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL FUNCTION _clearLibCache {
    FOR key IN LIST(
        "lib_band_libs", "lib_band_phase", "reload_reason",
        "reload_next_phase", "reload_next_band"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _writeCoastAutomation {
    PARAMETER profilePath.
    LOG "SET KEEP_WARP TO " + configLiteral(KEEP_WARP) + "." TO profilePath.
    LOG "SET COAST_AUTO_WARP TO " + configLiteral(COAST_AUTO_WARP) + "." TO profilePath.
    LOG "SET COAST_AUTO_WARP_MIN TO " + configLiteral(COAST_AUTO_WARP_MIN) + "." TO profilePath.
    LOG "SET COAST_HIBERNATE TO " + configLiteral(COAST_HIBERNATE) + "." TO profilePath.
    LOG "SET COAST_HIBERNATE_MIN TO " + configLiteral(COAST_HIBERNATE_MIN) + "." TO profilePath.
    LOG "SET COAST_WARP_5M_LIMIT TO " + configLiteral(COAST_WARP_5M_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_1H_LIMIT TO " + configLiteral(COAST_WARP_1H_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_5H_LIMIT TO " + configLiteral(COAST_WARP_5H_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_3D_LIMIT TO " + configLiteral(COAST_WARP_3D_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_10D_LIMIT TO " + configLiteral(COAST_WARP_10D_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_50D_LIMIT TO " + configLiteral(COAST_WARP_50D_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_MAX_RATE TO " + configLiteral(COAST_WARP_MAX_RATE) + "." TO profilePath.
}

// --- Read options with defaults ---
// Default honors the mission profile's REENTRY_PE when set.
LOCAL targetPe IS REENTRY_PE.
LOCAL reentryDir IS "RETROGRADE".
LOCAL decoupleTag IS "".
LOCAL armChutes IS 0.
LOCAL kscTarget IS TRUE.
// Empty = leave mission state untouched so craft/profile globals
// (then lib defaults) decide; "none" = explicitly disabled.
LOCAL descentFairingTag IS "".
LOCAL descentDecouplerTag IS "".
LOCAL descentChutesTag IS "".
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

    // Set up the return mission profile and identity.
    LOCAL profilePath IS missionProfileBegin(stateGet("vehicle", ""), "kerbin_return").
    missionOverrideClear().
    LOG "SET MISSION_ID TO " + configLiteral("kerbin_return") + "." TO profilePath.
    LOG "SET MISSION_NAME TO " + configLiteral("Return to Kerbin") + "." TO profilePath.
    LOG "SET MISSION_TYPE TO " + configLiteral("kerbin_return") + "." TO profilePath.
    LOG "SET TARGET_ TO " + configLiteral("KERBIN") + "." TO profilePath.
    LOG "SET PAYLOADS TO " + configLiteral(LIST("RETURN")) + "." TO profilePath.
    stateSet("mission_id", "kerbin_return").

    // Set up the return mission sequence and config
    LOCAL returnSeq IS LIST("ESCAPE", "COAST", "MCC", "AEROBRAKE", "DESCENT", "DONE").
    LOG "SET SEQUENCE TO " + configLiteral(returnSeq) + "." TO profilePath.
    // Keep the escape-planning boot lean; DESCENT loads later in
    // its own band instead of consuming storage during Minmus escape.
    LOG "SET ESCAPE_PE TO " + configLiteral(targetPe) + "." TO profilePath.
    LOG "SET CAPTURE_PE TO " + configLiteral(targetPe) + "." TO profilePath.
    LOG "SET CAPTURE_INC TO " + configLiteral(0) + "." TO profilePath.
    LOG "SET AEROBRAKE_REENTRY_DIR TO " + configLiteral(reentryDir) + "." TO profilePath.
    _writeCoastAutomation(profilePath).

    IF kscTarget {
        LOG "SET ESCAPE_KSC_TARGET TO " + configLiteral(1) + "." TO profilePath.
    }

    IF decoupleTag <> "" {
        LOG "SET AEROBRAKE_DECOUPLE_TAG TO " + configLiteral(decoupleTag) + "." TO profilePath.
    }

    IF armChutes > 0 {
        LOG "SET AEROBRAKE_ARM_CHUTES TO " + configLiteral(armChutes) + "." TO profilePath.
    }

    IF descentFairingTag <> "" {
        LOG "SET DESCENT_FAIRING_TAG TO " + configLiteral(descentFairingTag) + "." TO profilePath.
    }

    IF descentDecouplerTag <> "" {
        LOG "SET DESCENT_DECOUPLER_TAG TO " + configLiteral(descentDecouplerTag) + "." TO profilePath.
    }

    IF descentChutesTag <> "" {
        LOG "SET DESCENT_CHUTES_TAG TO " + configLiteral(descentChutesTag) + "." TO profilePath.
    }

    // Reset phase to start of return sequence
    stateSet("phase", "ESCAPE").
    stateSet("lib_band", "ESCAPE").
    stateSet("reload_required", "false").
    _clearLibCache().

    // Bump launch_time so the new flight log gets a fresh timestamp
    stateSet("launch_time", ROUND(TIME:SECONDS)).

    PRINT " ".
    PRINT "Return to Kerbin configured:".
    PRINT "  Sequence:    " + returnSeq.
    PRINT "  Target PE:   " + targetPe + "m (" + ROUND(targetPe/1000,1) + "km)".
    PRINT "  Target Inc:  0 deg".
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
