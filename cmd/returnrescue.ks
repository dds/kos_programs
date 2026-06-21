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
GLOBAL CAPTURE_PE IS -1.
GLOBAL ESCAPE_PE IS -1.
GLOBAL AEROBRAKE_REENTRY_DIR IS "RETROGRADE".
GLOBAL AEROBRAKE_ARM_CHUTES IS 0.

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

LOCAL returnSeq IS LIST("ESCAPE", "COAST", "MCC", "AEROBRAKE", "DESCENT", "DONE").
LOCAL targetPe IS REENTRY_PE.
IF ESCAPE_PE >= 0 { SET targetPe TO ESCAPE_PE. }
IF CAPTURE_PE >= 0 { SET targetPe TO CAPTURE_PE. }
LOCAL phaseName IS "MCC".
LOCAL reentryDir IS AEROBRAKE_REENTRY_DIR.
LOCAL armChutes IS AEROBRAKE_ARM_CHUTES.

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

LOCAL profilePath IS missionProfileBegin(stateGet("vehicle", ""), "kerbin_return").
missionOverrideClear().
LOG "SET MISSION_ID TO " + configLiteral("kerbin_return") + "." TO profilePath.
LOG "SET MISSION_NAME TO " + configLiteral("Return to Kerbin Rescue") + "." TO profilePath.
LOG "SET MISSION_TYPE TO " + configLiteral("kerbin_return") + "." TO profilePath.
LOG "SET TARGET_ TO " + configLiteral("KERBIN") + "." TO profilePath.
LOG "SET PAYLOADS TO " + configLiteral(LIST("RETURN")) + "." TO profilePath.
LOG "SET SEQUENCE TO " + configLiteral(returnSeq) + "." TO profilePath.
LOG "SET ESCAPE_PE TO " + configLiteral(targetPe) + "." TO profilePath.
LOG "SET CAPTURE_PE TO " + configLiteral(targetPe) + "." TO profilePath.
LOG "SET CAPTURE_INC TO " + configLiteral(0) + "." TO profilePath.
LOG "SET AEROBRAKE_REENTRY_DIR TO " + configLiteral(reentryDir) + "." TO profilePath.
_writeCoastAutomation(profilePath).
stateSet("mission_id", "kerbin_return").

IF armChutes > 0 {
    LOG "SET AEROBRAKE_ARM_CHUTES TO " + configLiteral(armChutes) + "." TO profilePath.
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
