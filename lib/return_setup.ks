// ============================================================
// return_setup.ks — Switch a moon mission into Kerbin-return mode
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL RETURN_SEQUENCE IS LIST("ESCAPE", "COAST", "MCC", "AEROBRAKE", "DESCENT", "DONE").
GLOBAL RETURN_PE IS -1.
GLOBAL RETURN_REENTRY_DIR IS "RETROGRADE".
GLOBAL RETURN_KSC_TARGET IS 0.
GLOBAL RETURN_ARM_CHUTES IS 0.
GLOBAL RETURN_DESCENT_FAIRING_TAG IS "".
GLOBAL RETURN_DESCENT_DECOUPLER_TAG IS "".
GLOBAL RETURN_DESCENT_CHUTES_TAG IS "".
GLOBAL SURFACE_RETURN_SEQUENCE IS LIST("PRELAUNCH", "LAUNCH", "PARK", "RETURN_SETUP").
GLOBAL SURFACE_RETURN_PARKING_ALT IS 20000.
GLOBAL SURFACE_RETURN_INCLINATION IS 0.
GLOBAL SURFACE_RETURN_AZIMUTH IS 0.
GLOBAL REENTRY_PE IS 30000.

LOCAL FUNCTION _returnSetupClearLibCache {
    FOR key IN LIST(
        "lib_band_libs", "lib_band_phase", "reload_reason",
        "reload_next_phase", "reload_next_band"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _coastAutomationInto {
    PARAMETER cfg.
    SET cfg["KEEP_WARP"] TO KEEP_WARP.
    SET cfg["COAST_AUTO_WARP"] TO COAST_AUTO_WARP.
    SET cfg["COAST_AUTO_WARP_MIN"] TO COAST_AUTO_WARP_MIN.
    SET cfg["COAST_HIBERNATE"] TO COAST_HIBERNATE.
    SET cfg["COAST_HIBERNATE_MIN"] TO COAST_HIBERNATE_MIN.
    SET cfg["COAST_WARP_5M_LIMIT"] TO COAST_WARP_5M_LIMIT.
    SET cfg["COAST_WARP_1H_LIMIT"] TO COAST_WARP_1H_LIMIT.
    SET cfg["COAST_WARP_5H_LIMIT"] TO COAST_WARP_5H_LIMIT.
    SET cfg["COAST_WARP_3D_LIMIT"] TO COAST_WARP_3D_LIMIT.
    SET cfg["COAST_WARP_10D_LIMIT"] TO COAST_WARP_10D_LIMIT.
    SET cfg["COAST_WARP_50D_LIMIT"] TO COAST_WARP_50D_LIMIT.
    SET cfg["COAST_WARP_MAX_RATE"] TO COAST_WARP_MAX_RATE.
}

LOCAL FUNCTION _optionalTagInto {
    PARAMETER cfg.
    PARAMETER key.
    PARAMETER value.
    IF value <> "" { SET cfg[key] TO value. }
}

// Persist the next leg as a compact local mission profile rather than
// dozens of mission_cfg_* keys in state.json (which starved the LAUNCH
// band). Wipe any mission_cfg_* the previous mission left behind first,
// so the freshly written profile is the single source of truth — boot
// RUNPATHs it, then layers only runtime mission_cfg_* (set mid-mission)
// on top.
LOCAL FUNCTION _writeLegProfile {
    PARAMETER mid.
    PARAMETER cfg.
    stateRemovePrefix("mission_cfg_").
    missionProfileWrite(stateGet("vehicle", ""), mid, cfg).
}

GLOBAL FUNCTION phaseSurfaceReturnSetup {
    IF BODY:NAME <> "Mun" AND BODY:NAME <> "Minmus" {
        mLogError("SURFACE_RETURN_SETUP requires Mun or Minmus surface; current body="
            + BODY:NAME + ".").
        PRINT " ".
        PRINT "  SURFACE RETURN SETUP FAILED".
        PRINT "  Current body: " + BODY:NAME + ".".
        yieldToPrompt().
        RETURN.
    }
    IF NOT (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED") {
        mLogError("SURFACE_RETURN_SETUP requires touchdown; status="
            + SHIP:STATUS + ".").
        PRINT " ".
        PRINT "  SURFACE RETURN SETUP FAILED".
        PRINT "  Current status: " + SHIP:STATUS + ".".
        yieldToPrompt().
        RETURN.
    }

    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Surface landing log archived before relaunch setup.").
    }

    stateSet("target", BODY:NAME:TOUPPER).
    stateSet("mission_type", "surface_return").
    stateSet("mission_id", "surface_return").
    stateSet("mission_name", "Surface Return").

    SET PARKING_ALT TO SURFACE_RETURN_PARKING_ALT.
    SET LAUNCH_INCLINATION TO SURFACE_RETURN_INCLINATION.
    SET LAUNCH_AZIMUTH TO 90.

    LOCAL cfg IS LEXICON().
    SET cfg["SEQUENCE"] TO SURFACE_RETURN_SEQUENCE.
    SET cfg["PARKING_ALT"] TO PARKING_ALT.
    SET cfg["LAUNCH_INCLINATION"] TO LAUNCH_INCLINATION.
    SET cfg["LAUNCH_AZIMUTH"] TO LAUNCH_AZIMUTH.
    SET cfg["RETURN_SEQUENCE"] TO RETURN_SEQUENCE.
    SET cfg["RETURN_PE"] TO RETURN_PE.
    SET cfg["RETURN_REENTRY_DIR"] TO RETURN_REENTRY_DIR.
    SET cfg["RETURN_KSC_TARGET"] TO RETURN_KSC_TARGET.
    SET cfg["RETURN_ARM_CHUTES"] TO RETURN_ARM_CHUTES.
    _optionalTagInto(cfg, "RETURN_DESCENT_FAIRING_TAG", RETURN_DESCENT_FAIRING_TAG).
    _optionalTagInto(cfg, "RETURN_DESCENT_DECOUPLER_TAG", RETURN_DESCENT_DECOUPLER_TAG).
    _optionalTagInto(cfg, "RETURN_DESCENT_CHUTES_TAG", RETURN_DESCENT_CHUTES_TAG).
    _coastAutomationInto(cfg).
    _writeLegProfile("surface_return", cfg).
    FOR key IN LIST("fairing_deployed", "orbit_start_time") {
        stateRemove(key).
    }

    stateSet("phase", "PRELAUNCH").
    stateSet("lib_band", "PRELAUNCH").
    stateSet("reload_required", "false").
    _returnSetupClearLibCache().
    stateSet("launch_time", ROUND(TIME:SECONDS)).

    mLog("Surface return setup: sequence=" + SURFACE_RETURN_SEQUENCE
        + " parkingAlt=" + ROUND(PARKING_ALT/1000, 1)
        + "km inc=" + LAUNCH_INCLINATION
        + " az=" + LAUNCH_AZIMUTH + ".").
    PRINT " ".
    PRINT "Surface return configured:".
    PRINT "  Sequence: " + SURFACE_RETURN_SEQUENCE.
    PRINT "  Orbit:    " + ROUND(PARKING_ALT/1000, 1)
        + "km x " + ROUND(PARKING_ALT/1000, 1) + "km".
    PRINT "  Launch:   inc " + LAUNCH_INCLINATION + " deg, az "
        + LAUNCH_AZIMUTH + " deg.".
    PRINT "  Rebooting into PRELAUNCH.".
    WAIT 3.
    REBOOT.
}

GLOBAL FUNCTION phaseReturnSetup {
    IF BODY:NAME <> "Mun" AND BODY:NAME <> "Minmus" {
        mLogError("RETURN_SETUP requires Mun or Minmus orbit; current body="
            + BODY:NAME + ".").
        PRINT " ".
        PRINT "  RETURN SETUP FAILED".
        PRINT "  Current body: " + BODY:NAME + ".".
        yieldToPrompt().
        RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" {
        mLogError("RETURN_SETUP requires stable orbit; status="
            + SHIP:STATUS + ".").
        PRINT " ".
        PRINT "  RETURN SETUP FAILED".
        PRINT "  Current status: " + SHIP:STATUS + ".".
        yieldToPrompt().
        RETURN.
    }

    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Outbound tour log archived before Kerbin return setup.").
    }

    LOCAL targetPe IS REENTRY_PE.
    IF RETURN_PE >= 0 { SET targetPe TO RETURN_PE. }

    stateSet("target", "KERBIN").
    stateSet("mission_type", "kerbin_return").
    stateSet("mission_id", "kerbin_return").
    stateSet("mission_name", "Return to Kerbin").
    stateSet("payloads", LIST("RETURN")).

    LOCAL cfg IS LEXICON().
    SET cfg["SEQUENCE"] TO RETURN_SEQUENCE.
    SET cfg["ESCAPE_PE"] TO targetPe.
    SET cfg["CAPTURE_PE"] TO targetPe.
    SET cfg["CAPTURE_INC"] TO 0.
    SET cfg["AEROBRAKE_REENTRY_DIR"] TO RETURN_REENTRY_DIR.
    _coastAutomationInto(cfg).
    IF RETURN_KSC_TARGET > 0 { SET cfg["ESCAPE_KSC_TARGET"] TO 1. }
    IF RETURN_ARM_CHUTES > 0 { SET cfg["AEROBRAKE_ARM_CHUTES"] TO RETURN_ARM_CHUTES. }
    _optionalTagInto(cfg, "DESCENT_FAIRING_TAG", RETURN_DESCENT_FAIRING_TAG).
    _optionalTagInto(cfg, "DESCENT_DECOUPLER_TAG", RETURN_DESCENT_DECOUPLER_TAG).
    _optionalTagInto(cfg, "DESCENT_CHUTES_TAG", RETURN_DESCENT_CHUTES_TAG).
    _writeLegProfile("kerbin_return", cfg).

    stateSet("phase", "ESCAPE").
    stateSet("lib_band", "ESCAPE").
    stateSet("reload_required", "false").
    _returnSetupClearLibCache().
    stateSet("launch_time", ROUND(TIME:SECONDS)).

    mLog("Return setup: sequence=" + RETURN_SEQUENCE
        + " Pe=" + ROUND(targetPe/1000, 1) + "km"
        + " inc=0"
        + " KSC=" + RETURN_KSC_TARGET + ".").
    PRINT " ".
    PRINT "Return to Kerbin configured:".
    PRINT "  Sequence:  " + RETURN_SEQUENCE.
    PRINT "  Target PE: " + ROUND(targetPe/1000, 1) + "km".
    PRINT "  Target Inc: 0 deg".
    PRINT "  From:      " + BODY:NAME + ".".
    PRINT "  Rebooting into ESCAPE.".
    WAIT 3.
    REBOOT.
}
