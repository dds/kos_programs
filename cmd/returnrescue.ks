// ============================================================
// cmd/returnrescue.ks - Repair in-flight Kerbin-return state
// (0:/cmd/returnrescue.ks)
//
// Rewrites only mission state/config for a return already in progress.
// It intentionally skips returntokerbin.ks's stable Mun/Minmus orbit
// checks, for rescues after escape or after Kerbin SOI entry.
//
// Usage:
//   RUNPATH("0:/cmd/returnrescue.ks").
//   RUNPATH("0:/cmd/returnrescue.ks", LEX("phase", "AEROBRAKE", "pe", 30000)).
//
// Defaults:
//   phase - MCC
//   pe    - existing return Pe config, falling back to REENTRY_PE
// ============================================================

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

LOCAL FUNCTION _persistCoastAutomation {
    stateSet("mission_cfg_KEEP_WARP", KEEP_WARP).
    stateSet("mission_cfg_COAST_AUTO_WARP", COAST_AUTO_WARP).
    stateSet("mission_cfg_COAST_AUTO_WARP_MIN", COAST_AUTO_WARP_MIN).
    stateSet("mission_cfg_COAST_HIBERNATE", COAST_HIBERNATE).
    stateSet("mission_cfg_COAST_HIBERNATE_MIN", COAST_HIBERNATE_MIN).
    stateSet("mission_cfg_COAST_WARP_5M_LIMIT", COAST_WARP_5M_LIMIT).
    stateSet("mission_cfg_COAST_WARP_1H_LIMIT", COAST_WARP_1H_LIMIT).
    stateSet("mission_cfg_COAST_WARP_5H_LIMIT", COAST_WARP_5H_LIMIT).
    stateSet("mission_cfg_COAST_WARP_3D_LIMIT", COAST_WARP_3D_LIMIT).
    stateSet("mission_cfg_COAST_WARP_10D_LIMIT", COAST_WARP_10D_LIMIT).
    stateSet("mission_cfg_COAST_WARP_50D_LIMIT", COAST_WARP_50D_LIMIT).
    stateSet("mission_cfg_COAST_WARP_MAX_RATE", COAST_WARP_MAX_RATE).
}

LOCAL returnSeq IS "ESCAPE,COAST,MCC,AEROBRAKE,DESCENT,DONE".
LOCAL targetPe IS stateGetNum(
    "mission_cfg_CAPTURE_PE",
    stateGetNum("mission_cfg_ESCAPE_PE", REENTRY_PE)).
LOCAL phaseName IS "MCC".
LOCAL reentryDir IS stateGet("mission_cfg_AEROBRAKE_REENTRY_DIR", "RETROGRADE").
LOCAL armChutes IS stateGetNum("mission_cfg_AEROBRAKE_ARM_CHUTES", 0).

IF opts:HASKEY("phase")      { SET phaseName TO opts["phase"]:TOUPPER. }
IF opts:HASKEY("pe")         { SET targetPe TO opts["pe"]. }
IF opts:HASKEY("reentry_pe") { SET targetPe TO opts["reentry_pe"]. }
IF opts:HASKEY("reentry_dir") {
    SET reentryDir TO opts["reentry_dir"]:TOUPPER.
}
IF opts:HASKEY("arm_chutes") { SET armChutes TO opts["arm_chutes"]. }

LOCAL phaseBand IS bootLibBandForPhase(phaseName, "").

IF phaseName = "MCC" AND SHIP:BODY:NAME:TOUPPER = "KERBIN" {
    PRINT "MCC will correct the current Kerbin approach orbit.".
}

archiveLog().

stateSet("target", "KERBIN").
stateSet("mission_type", "kerbin_return").
stateSet("mission_id", "kerbin_return").
stateSet("mission_name", "Return to Kerbin Rescue").
stateSet("payloads", "RETURN").

stateSet("mission_cfg_SEQUENCE", returnSeq).
stateSet("mission_cfg_ESCAPE_PE", targetPe).
stateSet("mission_cfg_CAPTURE_PE", targetPe).
stateSet("mission_cfg_CAPTURE_INC", 0).
stateSet("mission_cfg_AEROBRAKE_REENTRY_DIR", reentryDir).
_persistCoastAutomation().

IF armChutes > 0 {
    stateSet("mission_cfg_AEROBRAKE_ARM_CHUTES", armChutes).
} ELSE {
    stateRemove("mission_cfg_AEROBRAKE_ARM_CHUTES").
}

FOR key IN LIST(
    "CAPTURE_LAN", "CAPTURE_AOP", "CAPTURE_DIR",
    "LIBS_EXTRA"
) {
    stateRemove("mission_cfg_" + key).
}

stateSet("phase", phaseName).
stateSet("lib_band", phaseBand).
stateSet("reload_required", "false").
_clearLibCache().

PRINT " ".
PRINT "Kerbin return rescue configured:".
PRINT "  Sequence:    " + returnSeq.
PRINT "  Phase:       " + phaseName + " (band " + phaseBand + ")".
PRINT "  Target PE:   " + ROUND(targetPe / 1000, 1) + "km".
PRINT "  Target Inc:  0 deg".
PRINT "  Reentry dir: " + reentryDir.
PRINT "  Arm chutes:  " + armChutes.
PRINT "  Current:     " + SHIP:BODY:NAME + " / " + SHIP:STATUS + ".".
PRINT " ".
PRINT "Run REBOOT to resume.".
