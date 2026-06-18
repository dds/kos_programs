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

LOCAL FUNCTION _returnSetupCfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

LOCAL FUNCTION _returnSetupRemoveCfg {
    PARAMETER key.
    stateRemove("mission_cfg_" + key).
}

LOCAL FUNCTION _returnSetupOptionalTag {
    PARAMETER key.
    PARAMETER value.
    IF value <> "" {
        _returnSetupCfg(key, value).
    } ELSE {
        _returnSetupRemoveCfg(key).
    }
}

LOCAL FUNCTION _returnSetupCoastAutomationCfg {
    _returnSetupCfg("KEEP_WARP", KEEP_WARP).
    _returnSetupCfg("COAST_AUTO_WARP", COAST_AUTO_WARP).
    _returnSetupCfg("COAST_AUTO_WARP_MIN", COAST_AUTO_WARP_MIN).
    _returnSetupCfg("COAST_HIBERNATE", COAST_HIBERNATE).
    _returnSetupCfg("COAST_HIBERNATE_MIN", COAST_HIBERNATE_MIN).
    _returnSetupCfg("COAST_WARP_5M_LIMIT", COAST_WARP_5M_LIMIT).
    _returnSetupCfg("COAST_WARP_1H_LIMIT", COAST_WARP_1H_LIMIT).
    _returnSetupCfg("COAST_WARP_5H_LIMIT", COAST_WARP_5H_LIMIT).
    _returnSetupCfg("COAST_WARP_3D_LIMIT", COAST_WARP_3D_LIMIT).
    _returnSetupCfg("COAST_WARP_10D_LIMIT", COAST_WARP_10D_LIMIT).
    _returnSetupCfg("COAST_WARP_50D_LIMIT", COAST_WARP_50D_LIMIT).
    _returnSetupCfg("COAST_WARP_MAX_RATE", COAST_WARP_MAX_RATE).
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

    _returnSetupCfg("SEQUENCE", SURFACE_RETURN_SEQUENCE).
    _returnSetupCfg("PARKING_ALT", SURFACE_RETURN_PARKING_ALT).
    _returnSetupCfg("LAUNCH_INCLINATION", SURFACE_RETURN_INCLINATION).
    _returnSetupCfg("LAUNCH_AZIMUTH", SURFACE_RETURN_AZIMUTH).
    _returnSetupCfg("RETURN_SEQUENCE", RETURN_SEQUENCE).
    _returnSetupCfg("RETURN_PE", RETURN_PE).
    _returnSetupCfg("RETURN_REENTRY_DIR", RETURN_REENTRY_DIR).
    _returnSetupCfg("RETURN_KSC_TARGET", RETURN_KSC_TARGET).
    _returnSetupCfg("RETURN_ARM_CHUTES", RETURN_ARM_CHUTES).
    _returnSetupOptionalTag("RETURN_DESCENT_FAIRING_TAG", RETURN_DESCENT_FAIRING_TAG).
    _returnSetupOptionalTag("RETURN_DESCENT_DECOUPLER_TAG", RETURN_DESCENT_DECOUPLER_TAG).
    _returnSetupOptionalTag("RETURN_DESCENT_CHUTES_TAG", RETURN_DESCENT_CHUTES_TAG).
    _returnSetupCoastAutomationCfg().
    _returnSetupRemoveCfg("LIBS_EXTRA").
    FOR key IN LIST("fairing_deployed", "orbit_start_time") {
        stateRemove(key).
    }

    stateSet("phase", "PRELAUNCH").
    stateSet("lib_band", "PRELAUNCH").
    stateSet("reload_required", "false").
    _returnSetupClearLibCache().
    stateSet("launch_time", ROUND(TIME:SECONDS)).

    mLog("Surface return setup: sequence=" + SURFACE_RETURN_SEQUENCE
        + " parkingAlt=" + ROUND(SURFACE_RETURN_PARKING_ALT/1000, 1)
        + "km inc=" + SURFACE_RETURN_INCLINATION
        + " az=" + SURFACE_RETURN_AZIMUTH + ".").
    PRINT " ".
    PRINT "Surface return configured:".
    PRINT "  Sequence: " + SURFACE_RETURN_SEQUENCE.
    PRINT "  Orbit:    " + ROUND(SURFACE_RETURN_PARKING_ALT/1000, 1)
        + "km x " + ROUND(SURFACE_RETURN_PARKING_ALT/1000, 1) + "km".
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

    _returnSetupCfg("SEQUENCE", RETURN_SEQUENCE).
    _returnSetupCfg("ESCAPE_PE", targetPe).
    _returnSetupCfg("CAPTURE_PE", targetPe).
    _returnSetupCfg("CAPTURE_INC", 0).
    _returnSetupCfg("AEROBRAKE_REENTRY_DIR", RETURN_REENTRY_DIR).
    _returnSetupRemoveCfg("LIBS_EXTRA").
    _returnSetupCoastAutomationCfg().

    IF RETURN_KSC_TARGET > 0 {
        _returnSetupCfg("ESCAPE_KSC_TARGET", 1).
    } ELSE {
        _returnSetupRemoveCfg("ESCAPE_KSC_TARGET").
    }

    IF RETURN_ARM_CHUTES > 0 {
        _returnSetupCfg("AEROBRAKE_ARM_CHUTES", RETURN_ARM_CHUTES).
    } ELSE {
        _returnSetupRemoveCfg("AEROBRAKE_ARM_CHUTES").
    }

    _returnSetupOptionalTag("DESCENT_FAIRING_TAG", RETURN_DESCENT_FAIRING_TAG).
    _returnSetupOptionalTag("DESCENT_DECOUPLER_TAG", RETURN_DESCENT_DECOUPLER_TAG).
    _returnSetupOptionalTag("DESCENT_CHUTES_TAG", RETURN_DESCENT_CHUTES_TAG).

    FOR key IN LIST("CAPTURE_LAN", "CAPTURE_AOP", "CAPTURE_DIR") {
        _returnSetupRemoveCfg(key).
    }

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
