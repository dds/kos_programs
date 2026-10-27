// ============================================================
// return_setup.ks — Switch a moon mission into Kerbin-return mode
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL RETURN_SEQUENCE IS LIST("ESCAPE", "COAST", "MCC", "AEROBRAKE", "DESCENT", "DONE").
GLOBAL RETURN_PE IS -1.
// Opt-in entry corridor around RETURN_PE. Persist it through surface
// ascent so MCC / site targeting cannot accept the default deep entry.
GLOBAL RETURN_PE_TOLERANCE IS -1.
GLOBAL RETURN_REENTRY_DIR IS "RETROGRADE".
GLOBAL RETURN_KSC_TARGET IS 0.
GLOBAL RETURN_KSC_TRIM_DV_CAP IS 80.
GLOBAL RETURN_ARM_CHUTES IS 0.
GLOBAL MCC_RETURN_AT_APOAPSIS IS 0.
GLOBAL RETURN_DESCENT_FAIRING_TAG IS "".
GLOBAL RETURN_DESCENT_DECOUPLER_TAG IS "".
GLOBAL RETURN_DESCENT_CHUTES_TAG IS "".
GLOBAL RETURN_DESCENT_DECOUPLE_ALT IS -999999.
GLOBAL RETURN_DESCENT_RELEASE_ALT IS -1.
GLOBAL SURFACE_RETURN_SEQUENCE IS LIST("PRELAUNCH", "LAUNCH", "PARK", "RETURN_SETUP").
GLOBAL SURFACE_RETURN_PARKING_ALT IS 20000.
GLOBAL SURFACE_RETURN_INCLINATION IS 0.
GLOBAL SURFACE_RETURN_AZIMUTH IS 0.
// Optional post-ascent SHAPE settings, written into the generated local
// surface-return profile. Empty preserves every existing return sequence.
GLOBAL SURFACE_RETURN_ORBIT IS LEXICON().
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
    // Keep the optional assist policy through both surface ascent
    // and Kerbin-return profile replacements (which clear old overrides).
    LOG "SET AEROBRAKE_AP_BURN TO " + configLiteral(AEROBRAKE_AP_BURN) + "." TO profilePath.
    LOG "SET AEROBRAKE_AP_RESERVE_DV TO " + configLiteral(AEROBRAKE_AP_RESERVE_DV) + "." TO profilePath.
    LOG "SET AEROBRAKE_AP_PLAN_LEAD TO " + configLiteral(AEROBRAKE_AP_PLAN_LEAD) + "." TO profilePath.
    LOG "SET AEROBRAKE_AP_MAX_Q TO " + configLiteral(AEROBRAKE_AP_MAX_Q) + "." TO profilePath.
    LOG "SET AEROBRAKE_AP_MAX_OFF_RETRO TO " + configLiteral(AEROBRAKE_AP_MAX_OFF_RETRO) + "." TO profilePath.
}

// Persist the next leg as a compact local mission profile. State keeps
// only mission identity/progress; the profile is the config source of truth.
LOCAL FUNCTION _beginLegProfile {
    PARAMETER mid.
    missionOverrideClear().
    RETURN missionProfileBegin(stateGet("vehicle", ""), mid).
}

LOCAL FUNCTION _writeSurfaceReturnOrbit {
    PARAMETER profilePath.
    FOR key IN LIST("AP","PE","INC","LAN","AOP","ALT_TOL","ANG_TOL","AOP_TOL",
            "DV_CAP","TOTAL_DV_CAP","RESERVE_DV","MIN_BURN_DV","BURN_TOLERANCE","MIN_PE") {
        IF SURFACE_RETURN_ORBIT:HASKEY(key) {
            LOG "SET SHAPE_" + key + " TO " + configLiteral(SURFACE_RETURN_ORBIT[key]) + "." TO profilePath.
        }
    }
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

    IF SURFACE_RETURN_ORBIT:LENGTH > 0 AND NOT SURFACE_RETURN_SEQUENCE:CONTAINS("SHAPE") {
        mLogError("Surface return orbit configured without SHAPE in its sequence; profile unchanged.").
        yieldToPrompt(). RETURN.
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
    _writeSurfaceReturnOrbit(profilePath).
    LOG "SET RETURN_SEQUENCE TO " + configLiteral(RETURN_SEQUENCE) + "." TO profilePath.
    LOG "SET RETURN_PE TO " + configLiteral(RETURN_PE) + "." TO profilePath.
    LOG "SET RETURN_PE_TOLERANCE TO " + configLiteral(RETURN_PE_TOLERANCE) + "." TO profilePath.
    LOG "SET RETURN_REENTRY_DIR TO " + configLiteral(RETURN_REENTRY_DIR) + "." TO profilePath.
    LOG "SET RETURN_KSC_TARGET TO " + configLiteral(RETURN_KSC_TARGET) + "." TO profilePath.
    LOG "SET RETURN_KSC_TRIM_DV_CAP TO " + configLiteral(RETURN_KSC_TRIM_DV_CAP) + "." TO profilePath.
    LOG "SET RETURN_ARM_CHUTES TO " + configLiteral(RETURN_ARM_CHUTES) + "." TO profilePath.
    IF RETURN_DESCENT_FAIRING_TAG <> "" { LOG "SET RETURN_DESCENT_FAIRING_TAG TO " + configLiteral(RETURN_DESCENT_FAIRING_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_DECOUPLER_TAG <> "" { LOG "SET RETURN_DESCENT_DECOUPLER_TAG TO " + configLiteral(RETURN_DESCENT_DECOUPLER_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_CHUTES_TAG <> "" { LOG "SET RETURN_DESCENT_CHUTES_TAG TO " + configLiteral(RETURN_DESCENT_CHUTES_TAG) + "." TO profilePath. }
    LOG "SET RETURN_DESCENT_DECOUPLE_ALT TO " + configLiteral(RETURN_DESCENT_DECOUPLE_ALT) + "." TO profilePath.
    LOG "SET RETURN_DESCENT_RELEASE_ALT TO " + configLiteral(RETURN_DESCENT_RELEASE_ALT) + "." TO profilePath.
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

// Native patch chain, including the current orbit. Never use a pasted orbit
// or a pending maneuver's prediction as the recovery source of truth.
GLOBAL FUNCTION returnKerbinPatch {
    IF HASNODE { RETURN 0. }
    LOCAL patch IS SHIP:ORBIT.
    LOCAL checked IS 0.
    UNTIL checked >= 16 {
        IF patch:BODY:NAME = "Kerbin" { RETURN patch. }
        IF NOT patch:HASNEXTPATCH { RETURN 0. }
        SET patch TO patch:NEXTPATCH.
        SET checked TO checked + 1.
    }
    RETURN 0.
}

GLOBAL FUNCTION phaseReturnSetup {
    PARAMETER startPhase IS "ESCAPE".
    IF startPhase <> "ESCAPE" AND startPhase <> "MCC" {
        mLogError("Unsupported return setup entry phase: " + startPhase).
        yieldToPrompt(). RETURN.
    }
    IF startPhase = "MCC" {
        IF ABORT OR HASNODE OR returnKerbinPatch() = 0
                OR NOT (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING"
                    OR SHIP:STATUS = "SUB_ORBITAL")
                OR NOT RETURN_SEQUENCE:CONTAINS("MCC")
                OR (stateGet("burn_pending","false") = "true"
                    AND stateGet("burn_started","false") = "true")
                OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                    AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
            PRINT "Recovery setup refused: require an unmodified Kerbin patch, stopped thrust/throttle and no Abort or interrupted burn.".
            yieldToPrompt(). RETURN.
        }
    } ELSE IF BODY:NAME <> "Mun" AND BODY:NAME <> "Minmus" {
        mLogError("RETURN_SETUP requires Mun or Minmus orbit; current body="
            + BODY:NAME + ".").
        PRINT " ".
        PRINT "  RETURN SETUP FAILED".
        PRINT "  Current body: " + BODY:NAME + ".".
        yieldToPrompt().
        RETURN.
    }
    IF startPhase = "ESCAPE" AND SHIP:STATUS <> "ORBITING" {
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
    // Keep the late Pe cleanup consistent with the escape target even
    // after the original landing profile is no longer loaded.
    LOG "SET REENTRY_PE TO " + configLiteral(targetPe) + "." TO profilePath.
    LOG "SET AEROBRAKE_PE TO " + configLiteral(targetPe) + "." TO profilePath.
    LOG "SET MCC_RETURN_AT_APOAPSIS TO " + configLiteral(MCC_RETURN_AT_APOAPSIS) + "." TO profilePath.
    IF RETURN_PE_TOLERANCE >= 0 {
        LOCAL minPe IS MAX(0, targetPe - RETURN_PE_TOLERANCE).
        LOCAL maxPe IS targetPe + RETURN_PE_TOLERANCE.
        LOG "SET MCC_AEROBRAKE_SAFE_PE_MIN TO " + configLiteral(minPe) + "." TO profilePath.
        LOG "SET MCC_AEROBRAKE_SAFE_PE_MAX TO " + configLiteral(maxPe) + "." TO profilePath.
        // Preserve the return plane: fuel is for the entry corridor,
        // not forcing an equatorial orbit on the way home.
        LOG "SET CAPTURE_INC TO -1." TO profilePath.
        LOG "SET AEROBRAKE_PE_TARGETING TO 1." TO profilePath.
        LOG "SET AEROBRAKE_CORRECTION_PE_MIN TO " + configLiteral(minPe) + "." TO profilePath.
        LOG "SET AEROBRAKE_CORRECTION_PE_MAX TO " + configLiteral(maxPe) + "." TO profilePath.
        LOG "SET AEROBRAKE_BRAKE_PE_FLOOR TO " + configLiteral(minPe) + "." TO profilePath.
        LOG "SET RETURN_TRIM_PE_MIN TO " + configLiteral(minPe) + "." TO profilePath.
        LOG "SET RETURN_TRIM_PE_MAX TO " + configLiteral(maxPe) + "." TO profilePath.
    }
    LOG "SET AEROBRAKE_REENTRY_DIR TO " + configLiteral(RETURN_REENTRY_DIR) + "." TO profilePath.
    _writeCoastAutomation(profilePath).
    // No KSC request must also disable aerobrake's default site targeting.
    IF RETURN_KSC_TARGET <= 0 {
        LOG "SET ESCAPE_KSC_TARGET TO 0." TO profilePath.
        LOG "SET AEROBRAKE_TARGETING TO 0." TO profilePath.
    }
    IF RETURN_KSC_TARGET > 0 {
        LOG "SET ESCAPE_KSC_TARGET TO 1." TO profilePath.
        LOG "SET TARGET_LAT TO -0.0972." TO profilePath.
        LOG "SET TARGET_LNG TO -74.5577." TO profilePath.
        LOG "SET TARGET_LOCK TO 1." TO profilePath.
        LOG "SET TARGET_WAYPOINT TO " + configLiteral("") + "." TO profilePath.
        LOG "SET AEROBRAKE_TARGETING TO 1." TO profilePath.
        IF RETURN_SEQUENCE:CONTAINS("RETURN_TRIM") {
            LOG "SET RETURN_TRIM TO TRUE." TO profilePath.
            LOG "SET RETURN_TRIM_DV_CAP TO " + configLiteral(RETURN_KSC_TRIM_DV_CAP) + "." TO profilePath.
        }
    }
    IF RETURN_ARM_CHUTES > 0 { LOG "SET AEROBRAKE_ARM_CHUTES TO " + configLiteral(RETURN_ARM_CHUTES) + "." TO profilePath. }
    IF RETURN_DESCENT_FAIRING_TAG <> "" { LOG "SET DESCENT_FAIRING_TAG TO " + configLiteral(RETURN_DESCENT_FAIRING_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_DECOUPLER_TAG <> "" { LOG "SET DESCENT_DECOUPLER_TAG TO " + configLiteral(RETURN_DESCENT_DECOUPLER_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_CHUTES_TAG <> "" { LOG "SET DESCENT_CHUTES_TAG TO " + configLiteral(RETURN_DESCENT_CHUTES_TAG) + "." TO profilePath. }
    IF RETURN_DESCENT_DECOUPLE_ALT > -999999 { LOG "SET DESCENT_DECOUPLE_ALT TO " + configLiteral(RETURN_DESCENT_DECOUPLE_ALT) + "." TO profilePath. }
    IF RETURN_DESCENT_RELEASE_ALT >= 0 { LOG "SET DESCENT_RELEASE_ALT TO " + configLiteral(RETURN_DESCENT_RELEASE_ALT) + "." TO profilePath. }

    stateSet("phase", startPhase).
    stateSet("lib_band", bootLibBandForPhase(startPhase,startPhase)).
    stateSet("reload_required", "false").
    _returnSetupClearLibCache().
    stateSet("launch_time", ROUND(TIME:SECONDS)).

    mLog("Return setup: sequence=" + RETURN_SEQUENCE
        + " Pe=" + ROUND(targetPe/1000, 1) + "km"
        + " entryToleranceKm=" + ROUND(RETURN_PE_TOLERANCE/1000, 1)
        + " KSC=" + RETURN_KSC_TARGET + ".").
    PRINT " ".
    PRINT "Return to Kerbin configured:".
    PRINT "  Sequence:  " + RETURN_SEQUENCE.
    PRINT "  Target PE: " + ROUND(targetPe/1000, 1) + "km".
    IF RETURN_PE_TOLERANCE >= 0 {
        PRINT "  Entry Pe tolerance: +/- " + RETURN_PE_TOLERANCE/1000 + "km.".
    }
    PRINT "  From:      " + BODY:NAME + ".".
    PRINT "  Rebooting into " + startPhase + ".".
    WAIT 3.
    REBOOT.
}

// Scalar capability marker, assigned only when this library has run. Bare
// DEFINED functionName is not a reliable cross-compiled function probe.
GLOBAL RETURN_SETUP_LOADED IS TRUE.
