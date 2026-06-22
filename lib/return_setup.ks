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

LOCAL FUNCTION _writeCoastAutomation {
    PARAMETER profilePath.
    LOG "SET KEEP_WARP TO " + configLiteral(KEEP_WARP) + "." TO profilePath.
    LOG "SET COAST_AUTO_WARP TO " + configLiteral(COAST_AUTO_WARP) + "." TO profilePath.
    LOG "SET COAST_AUTO_WARP_MIN TO " + configLiteral(COAST_AUTO_WARP_MIN) + "." TO profilePath.
    LOG "SET COAST_WARP_5M_LIMIT TO " + configLiteral(COAST_WARP_5M_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_1H_LIMIT TO " + configLiteral(COAST_WARP_1H_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_5H_LIMIT TO " + configLiteral(COAST_WARP_5H_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_3D_LIMIT TO " + configLiteral(COAST_WARP_3D_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_10D_LIMIT TO " + configLiteral(COAST_WARP_10D_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_50D_LIMIT TO " + configLiteral(COAST_WARP_50D_LIMIT) + "." TO profilePath.
    LOG "SET COAST_WARP_MAX_RATE TO " + configLiteral(COAST_WARP_MAX_RATE) + "." TO profilePath.
}

// Persist the next leg as a compact local mission profile. State keeps
// only mission identity/progress; the profile is the config source of truth.
LOCAL FUNCTION _beginLegProfile {
    PARAMETER mid.
    missionOverrideClear().
    RETURN missionProfileBegin(stateGet("vehicle", ""), mid).
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

    LOCAL profilePath IS _beginLegProfile("surface_return").
    LOG "SET MISSION_ID TO " + configLiteral("surface_return") + "." TO profilePath.
    LOG "SET MISSION_NAME TO " + configLiteral("Surface Return") + "." TO profilePath.
    LOG "SET MISSION_TYPE TO " + configLiteral("surface_return") + "." TO profilePath.
    LOG "SET TARGET_ TO " + configLiteral(BODY:NAME:TOUPPER) + "." TO profilePath.
    LOG "SET SEQUENCE TO " + configLiteral(SURFACE_RETURN_SEQUENCE) + "." TO profilePath.
    LOG "SET PARKING_ALT TO " + configLiteral(PARKING_ALT) + "." TO profilePath.
    LOG "SET LAUNCH_INCLINATION TO " + configLiteral(LAUNCH_INCLINATION) + "." TO profilePath.
    LOG "SET LAUNCH_AZIMUTH TO " + configLiteral(LAUNCH_AZIMUTH) + "." TO profilePath.
    LOG "SET RETURN_SEQUENCE TO " + configLiteral(RETURN_SEQUENCE) + "." TO profilePath.
    LOG "SET RETURN_PE TO " + configLiteral(RETURN_PE) + "." TO profilePath.
    LOG "SET RETURN_REENTRY_DIR TO " + configLiteral(RETURN_REENTRY_DIR) + "." TO profilePath.
    LOG "SET RETURN_KSC_TARGET TO " + configLiteral(RETURN_KSC_TARGET) + "." TO profilePath.
    LOG "SET RETURN_ARM_CHUTES TO " + configLiteral(RETURN_ARM_CHUTES) + "." TO profilePath.
    IF RETURN_DESCENT_FAIRING_TAG <> "" { LOG "SET RETURN_DESCENT_FAIRING_TAG TO " + configLiteral(RETURN_DESCENT_FAIRING_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_DECOUPLER_TAG <> "" { LOG "SET RETURN_DESCENT_DECOUPLER_TAG TO " + configLiteral(RETURN_DESCENT_DECOUPLER_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_CHUTES_TAG <> "" { LOG "SET RETURN_DESCENT_CHUTES_TAG TO " + configLiteral(RETURN_DESCENT_CHUTES_TAG) + "." TO profilePath. }
    _writeCoastAutomation(profilePath).
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

    LOCAL profilePath IS _beginLegProfile("kerbin_return").
    LOG "SET MISSION_ID TO " + configLiteral("kerbin_return") + "." TO profilePath.
    LOG "SET MISSION_NAME TO " + configLiteral("Return to Kerbin") + "." TO profilePath.
    LOG "SET MISSION_TYPE TO " + configLiteral("kerbin_return") + "." TO profilePath.
    LOG "SET TARGET_ TO " + configLiteral("KERBIN") + "." TO profilePath.
    LOG "SET PAYLOADS TO " + configLiteral(LIST("RETURN")) + "." TO profilePath.
    LOG "SET SEQUENCE TO " + configLiteral(RETURN_SEQUENCE) + "." TO profilePath.
    LOG "SET ESCAPE_PE TO " + configLiteral(targetPe) + "." TO profilePath.
    LOG "SET CAPTURE_PE TO " + configLiteral(targetPe) + "." TO profilePath.
    LOG "SET CAPTURE_INC TO " + configLiteral(0) + "." TO profilePath.
    LOG "SET AEROBRAKE_REENTRY_DIR TO " + configLiteral(RETURN_REENTRY_DIR) + "." TO profilePath.
    _writeCoastAutomation(profilePath).
    IF RETURN_KSC_TARGET > 0 { LOG "SET ESCAPE_KSC_TARGET TO " + configLiteral(1) + "." TO profilePath. }
    IF RETURN_ARM_CHUTES > 0 { LOG "SET AEROBRAKE_ARM_CHUTES TO " + configLiteral(RETURN_ARM_CHUTES) + "." TO profilePath. }
    IF RETURN_DESCENT_FAIRING_TAG <> "" { LOG "SET DESCENT_FAIRING_TAG TO " + configLiteral(RETURN_DESCENT_FAIRING_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_DECOUPLER_TAG <> "" { LOG "SET DESCENT_DECOUPLER_TAG TO " + configLiteral(RETURN_DESCENT_DECOUPLER_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_CHUTES_TAG <> "" { LOG "SET DESCENT_CHUTES_TAG TO " + configLiteral(RETURN_DESCENT_CHUTES_TAG) + "." TO profilePath. }

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
