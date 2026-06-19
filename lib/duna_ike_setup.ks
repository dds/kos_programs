// ============================================================
// duna_ike_setup.ks - FalconHeavy Duna/Ike mission glue phases
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL DUNA_AEROCAPTURE_PE IS 20000.
GLOBAL DUNA_AEROCAPTURE_MIN_PE IS 17000.
GLOBAL DUNA_AEROCAPTURE_MAX_PE IS 25000.
GLOBAL DUNA_AEROCAPTURE_TARGET_AP IS 5000000.
GLOBAL DUNA_AEROCAPTURE_MAX_RETRO_DV IS 125.
GLOBAL DUNA_SAFE_PE IS 85000.

GLOBAL IKE_FLYBY_SEQUENCE IS LIST(
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "SCIENCE_OPS", "FLYBY", "SCIENCE_OPS_LOW", "DUNA_ENTRY_SETUP"
).
GLOBAL IKE_FLYBY_PE IS 25000.
GLOBAL IKE_FLYBY_INC IS -1.
GLOBAL IKE_FLYBY_POST_PE_HOLD IS 600.
GLOBAL IKE_FLYBY_EXIT_SOI IS 0.
GLOBAL IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS IS 24.
GLOBAL IKE_TRANSFER_SCAN_SAMPLES_PER_ORBIT IS 32.
GLOBAL IKE_BPLANE_DV_CAP IS 40.
GLOBAL IKE_REFINE_BPLANE_DV_CAP IS 5.
GLOBAL IKE_REFINE_BPLANE_MAX_BURNS IS 8.

GLOBAL DUNA_ENTRY_SEQUENCE IS LIST(
    "DUNA_ENTRY_LOWER_PE", "AEROBRAKE", "DESCENT", "DONE"
).
GLOBAL DUNA_ENTRY_PE IS 18000.
GLOBAL DUNA_ENTRY_PE_TOL IS 5000.
GLOBAL DUNA_ENTRY_LOWER_PE_MAX_DV IS 150.
GLOBAL AEROBRAKE_DECOUPLE_TAG IS "".
GLOBAL AEROBRAKE_REENTRY_DIR IS "RETROGRADE".
GLOBAL AEROBRAKE_ARM_CHUTES IS 1.
GLOBAL AEROBRAKE_TARGETING IS 1.
GLOBAL DESCENT_RELEASE_ALT IS -1.
GLOBAL DESCENT_CHUTES_TAG IS "".
GLOBAL DESCENT_DROGUE_CUT_ALT IS -1.
GLOBAL DESCENT_FAIRING_TAG IS "".
GLOBAL DESCENT_DECOUPLER_TAG IS "".
GLOBAL DESCENT_DECOUPLE_ALT IS -999999.
GLOBAL DESCENT_HEAT_SHIELD_DROP_ALT IS -999999.
GLOBAL DESCENT_BAY_REOPEN_ALT IS -1.
GLOBAL DESCENT_FAIRING_DEPLOY_SPEED IS 10.
GLOBAL DESCENT_ENGINE_ASSIST IS 0.
GLOBAL DESCENT_ENGINE_ASSIST_ALT IS 1000.
GLOBAL DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS IS 2.5.
GLOBAL DESCENT_ENGINE_ASSIST_HIGH_VS IS 12.
GLOBAL DESCENT_ENGINE_ASSIST_MAX_THROTTLE IS 0.85.

LOCAL DUNA_ATM_HEIGHT IS 50000.

LOCAL FUNCTION _diCfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

LOCAL FUNCTION _diRemoveCfg {
    PARAMETER key.
    stateRemove("mission_cfg_" + key).
}

LOCAL FUNCTION _diClearLibCache {
    FOR key IN LIST(
        "lib_band_libs", "lib_band_phase", "reload_reason",
        "reload_next_phase", "reload_next_band"
    ) {
        stateRemove(key).
    }
    stateSet("reload_required", "false").
}

LOCAL FUNCTION _diArchiveLog {
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Duna/Ike setup log archived.").
    } ELSE {
        mLog("Duna/Ike setup log archive skipped: no KSC link.").
    }
}

LOCAL FUNCTION _diAtmHeight {
    IF SHIP:BODY:ATM:EXISTS { RETURN SHIP:BODY:ATM:HEIGHT. }
    RETURN DUNA_ATM_HEIGHT.
}

LOCAL FUNCTION _diBodyName {
    RETURN SHIP:BODY:NAME:TOUPPER.
}

LOCAL FUNCTION _diHold {
    PARAMETER title.
    PARAMETER detail.
    mLogError(title + ": " + detail).
    PRINT " ".
    PRINT "  " + title.
    PRINT "  " + detail.
    yieldToPrompt().
}

LOCAL FUNCTION _diClearCapturePlaneCfg {
    FOR key IN LIST("CAPTURE_INC", "CAPTURE_LAN", "CAPTURE_AOP", "CAPTURE_DIR") {
        _diRemoveCfg(key).
    }
}

LOCAL FUNCTION _diPersistCoastAutomation {
    _diCfg("KEEP_WARP", KEEP_WARP).
    _diCfg("COAST_AUTO_WARP", COAST_AUTO_WARP).
    _diCfg("COAST_AUTO_WARP_MIN", COAST_AUTO_WARP_MIN).
    _diCfg("COAST_HIBERNATE", COAST_HIBERNATE).
    _diCfg("COAST_HIBERNATE_MIN", COAST_HIBERNATE_MIN).
    _diCfg("COAST_WARP_5M_LIMIT", COAST_WARP_5M_LIMIT).
    _diCfg("COAST_WARP_1H_LIMIT", COAST_WARP_1H_LIMIT).
    _diCfg("COAST_WARP_5H_LIMIT", COAST_WARP_5H_LIMIT).
    _diCfg("COAST_WARP_3D_LIMIT", COAST_WARP_3D_LIMIT).
    _diCfg("COAST_WARP_10D_LIMIT", COAST_WARP_10D_LIMIT).
    _diCfg("COAST_WARP_50D_LIMIT", COAST_WARP_50D_LIMIT).
    _diCfg("COAST_WARP_MAX_RATE", COAST_WARP_MAX_RATE).
}

LOCAL FUNCTION _diOptionalCfg {
    PARAMETER key.
    PARAMETER value.
    IF value <> "" {
        _diCfg(key, value).
    } ELSE {
        _diRemoveCfg(key).
    }
}

LOCAL FUNCTION _diPersistDunaEntryCfg {
    _diCfg("DUNA_ENTRY_SEQUENCE", DUNA_ENTRY_SEQUENCE).
    _diCfg("DUNA_ENTRY_PE", DUNA_ENTRY_PE).
    _diCfg("DUNA_ENTRY_PE_TOL", DUNA_ENTRY_PE_TOL).
    _diCfg("DUNA_ENTRY_LOWER_PE_MAX_DV", DUNA_ENTRY_LOWER_PE_MAX_DV).
    _diCfg("AEROBRAKE_TARGETING", AEROBRAKE_TARGETING).
    _diCfg("AEROBRAKE_REENTRY_DIR", AEROBRAKE_REENTRY_DIR).
    _diCfg("AEROBRAKE_ARM_CHUTES", AEROBRAKE_ARM_CHUTES).
    _diOptionalCfg("AEROBRAKE_DECOUPLE_TAG", AEROBRAKE_DECOUPLE_TAG).

    _diOptionalCfg("DESCENT_CHUTES_TAG", DESCENT_CHUTES_TAG).
    _diCfg("DESCENT_RELEASE_ALT", DESCENT_RELEASE_ALT).
    _diCfg("DESCENT_DROGUE_CUT_ALT", DESCENT_DROGUE_CUT_ALT).
    _diOptionalCfg("DESCENT_FAIRING_TAG", DESCENT_FAIRING_TAG).
    _diCfg("DESCENT_FAIRING_DEPLOY_SPEED", DESCENT_FAIRING_DEPLOY_SPEED).
    _diOptionalCfg("DESCENT_DECOUPLER_TAG", DESCENT_DECOUPLER_TAG).
    _diCfg("DESCENT_DECOUPLE_ALT", DESCENT_DECOUPLE_ALT).
    _diCfg("DESCENT_HEAT_SHIELD_DROP_ALT", DESCENT_HEAT_SHIELD_DROP_ALT).
    _diCfg("DESCENT_BAY_REOPEN_ALT", DESCENT_BAY_REOPEN_ALT).
    _diCfg("DESCENT_ENGINE_ASSIST", DESCENT_ENGINE_ASSIST).
    _diCfg("DESCENT_ENGINE_ASSIST_ALT", DESCENT_ENGINE_ASSIST_ALT).
    _diCfg("DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS", DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS).
    _diCfg("DESCENT_ENGINE_ASSIST_HIGH_VS", DESCENT_ENGINE_ASSIST_HIGH_VS).
    _diCfg("DESCENT_ENGINE_ASSIST_MAX_THROTTLE", DESCENT_ENGINE_ASSIST_MAX_THROTTLE).
}

LOCAL FUNCTION _diRetractDeployables {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna")
                OR p:HASMODULE("ModuleDeployableSolarPanel") {
            FOR modName IN LIST("ModuleDeployableAntenna", "ModuleDeployableSolarPanel") {
                IF p:HASMODULE(modName) {
                    LOCAL modu IS p:GETMODULE(modName).
                    FOR evName IN modu:ALLEVENTNAMES {
                        LOCAL evLower IS evName:TOLOWER.
                        IF evLower:CONTAINS("retract") {
                            modu:DOEVENT(evName).
                            SET retracted TO retracted + 1.
                        }
                    }
                }
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " deployable event(s).").
        WAIT 3.
    } ELSE {
        mLog("No retractable Duna-aerocapture deployables found.").
    }
}

LOCAL FUNCTION _diOrientRetrograde {
    SAS OFF.
    LOCK STEERING TO RETROGRADE.
    LOCAL startTime IS TIME:SECONDS.
    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT) < 5
        OR TIME:SECONDS > startTime + 60.
    mLog("Retrograde entry alignment err="
        + ROUND(VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT), 1)
        + "deg.").
}

LOCAL FUNCTION _diMaybeCaptureAssist {
    LOCAL cap IS MAX(0, DUNA_AEROCAPTURE_MAX_RETRO_DV).
    IF cap <= 0 {
        mLog("Duna aerocapture assist disabled by dV cap.").
        RETURN TRUE.
    }
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS planCapture(SHIP:BODY, DUNA_AEROCAPTURE_TARGET_AP).
    WAIT 0.2.
    LOCAL dv IS nd:DELTAV:MAG.
    IF dv < 0.5 {
        mLog("Duna aerocapture assist below 0.5m/s; skipping burn.").
        REMOVE nd.
        RETURN TRUE.
    }
    IF dv > cap {
        mLogWarn("Duna aerocapture assist dV " + ROUND(dv,1)
            + "m/s exceeds cap " + ROUND(cap,1)
            + "m/s; relying on atmosphere.").
        REMOVE nd.
        RETURN TRUE.
    }
    mLog("Executing Duna aerocapture assist: dV=" + ROUND(dv,1)
        + "m/s targetAp=" + ROUND(DUNA_AEROCAPTURE_TARGET_AP/1000,1)
        + "km.").
    RETURN executeManeuver().
}

LOCAL FUNCTION _diWaitForAtmospherePass {
    LOCAL atmHeight IS _diAtmHeight().
    IF SHIP:ALTITUDE > atmHeight {
        mLog("Duna aerocapture: waiting for atmosphere at "
            + ROUND(atmHeight/1000,0) + "km.").
        WAIT UNTIL SHIP:ALTITUDE < atmHeight
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN. }
    mLog("Duna aerocapture: inside atmosphere, waiting for exit.").
    WAIT UNTIL (SHIP:ALTITUDE > atmHeight AND SHIP:VERTICALSPEED > 0)
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    SET WARP TO 0.
    WAIT 2.
}

GLOBAL FUNCTION phaseDunaAerocapture {
    mLogPhase("DUNA_AEROCAPTURE").
    IF _diBodyName() <> "DUNA" {
        _diHold("DUNA AEROCAPTURE HOLD",
            "expected Duna SOI, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }

    LOCAL pe IS SHIP:PERIAPSIS.
    IF pe < DUNA_AEROCAPTURE_MIN_PE OR pe > DUNA_AEROCAPTURE_MAX_PE {
        _diHold("DUNA AEROCAPTURE HOLD",
            "arrival Pe " + ROUND(pe/1000,1) + "km outside "
            + ROUND(DUNA_AEROCAPTURE_MIN_PE/1000,1) + "-"
            + ROUND(DUNA_AEROCAPTURE_MAX_PE/1000,1) + "km.").
        RETURN.
    }

    mLogWarn("STATS duna-aerocapture setup PeKm=" + ROUND(pe/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " etaPe=" + ROUND(ETA:PERIAPSIS,0)).
    _diRetractDeployables().
    _diOrientRetrograde().
    IF NOT _diMaybeCaptureAssist() {
        _diHold("DUNA AEROCAPTURE HOLD", "capture-assist burn failed.").
        RETURN.
    }
    _diOrientRetrograde().

    _diWaitForAtmospherePass().
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        _diHold("DUNA AEROCAPTURE HOLD",
            "ship reached surface during aerocapture; Ike leg abandoned.").
        RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" {
        _diHold("DUNA AEROCAPTURE HOLD",
            "post-pass status=" + SHIP:STATUS + "; manual recovery needed.").
        RETURN.
    }

    IF SHIP:PERIAPSIS < DUNA_SAFE_PE {
        mLog("Duna aerocapture: raising Pe to safe "
            + ROUND(DUNA_SAFE_PE/1000,1) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planRaisePeNow(DUNA_SAFE_PE).
        WAIT 0.2.
        IF nd:DELTAV:MAG > 0.5 {
            IF NOT executeManeuver() {
                _diHold("DUNA AEROCAPTURE HOLD", "safe-Pe raise burn failed.").
                RETURN.
            }
        } ELSE {
            REMOVE nd.
        }
    }

    SET SAS TO TRUE.
    UNLOCK STEERING.
    orbitSummary().
    mLogWarn("STATS duna-aerocapture result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseIkeSetup {
    mLogPhase("IKE_SETUP").
    IF _diBodyName() <> "DUNA" {
        _diHold("IKE SETUP HOLD",
            "expected Duna orbit, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" {
        _diHold("IKE SETUP HOLD",
            "requires stable Duna orbit; status=" + SHIP:STATUS + ".").
        RETURN.
    }

    _diArchiveLog().
    stateSet("target", "IKE").
    stateSet("mission_type", "duna_ike_flyby").
    stateSet("mission_id", "duna_ike_flyby").
    stateSet("mission_name", "Duna/Ike Flyby").
    stateSet("payloads", LIST("SCISAT")).

    _diCfg("SEQUENCE", IKE_FLYBY_SEQUENCE).
    _diCfg("CAPTURE_PE", IKE_FLYBY_PE).
    _diCfg("BPLANE_TARGET", "IKE").
    _diCfg("FLYBY_POST_PE_HOLD", IKE_FLYBY_POST_PE_HOLD).
    _diCfg("FLYBY_EXIT_SOI", IKE_FLYBY_EXIT_SOI).
    _diCfg("TRANSFER_SCAN_LOOKAHEAD_HOURS", IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS).
    _diCfg("TRANSFER_SCAN_SAMPLES_PER_ORBIT", IKE_TRANSFER_SCAN_SAMPLES_PER_ORBIT).
    _diCfg("BPLANE_DV_CAP", IKE_BPLANE_DV_CAP).
    _diCfg("REFINE_BPLANE_DV_CAP", IKE_REFINE_BPLANE_DV_CAP).
    _diCfg("REFINE_BPLANE_MAX_BURNS", IKE_REFINE_BPLANE_MAX_BURNS).
    IF IKE_FLYBY_INC >= 0 {
        _diCfg("CAPTURE_INC", IKE_FLYBY_INC).
    } ELSE {
        _diClearCapturePlaneCfg().
    }
    FOR key IN LIST("SHAPE_PE", "SHAPE_AP", "SHAPE_INC", "SHAPE_LAN", "SHAPE_AOP",
            "DUNA_AEROCAPTURE_PE", "DUNA_AEROCAPTURE_MIN_PE",
            "DUNA_AEROCAPTURE_MAX_PE", "DUNA_AEROCAPTURE_TARGET_AP",
            "DUNA_AEROCAPTURE_MAX_RETRO_DV", "DUNA_SAFE_PE") {
        _diRemoveCfg(key).
    }
    _diPersistCoastAutomation().
    _diPersistDunaEntryCfg().

    stateSet("phase", "XING").
    stateSet("lib_band", "XFER_PLAN").
    _diClearLibCache().
    stateSet("launch_time", ROUND(TIME:SECONDS)).
    mLog("Ike flyby configured: sequence=" + IKE_FLYBY_SEQUENCE
        + " Pe=" + ROUND(IKE_FLYBY_PE/1000,1) + "km.").
    PRINT " ".
    PRINT "Ike flyby configured.".
    PRINT "  Sequence: " + IKE_FLYBY_SEQUENCE.
    PRINT "  Ike Pe:   " + ROUND(IKE_FLYBY_PE/1000,1) + "km".
    PRINT "  Rebooting into XING.".
    WAIT 3.
    REBOOT.
}

GLOBAL FUNCTION phaseDunaEntrySetup {
    mLogPhase("DUNA_ENTRY_SETUP").
    IF _diBodyName() = "IKE" {
        mLog("DUNA_ENTRY_SETUP: waiting to exit Ike SOI.").
        IF SHIP:ORBIT:HASNEXTPATCH AND SHIP:ORBIT:NEXTPATCHETA > 60 {
            kacEnsureAlarm("Exit SOI: Ike",
                TIME:SECONDS + SHIP:ORBIT:NEXTPATCHETA,
                "Auto-created by DUNA_ENTRY_SETUP").
        }
        LOCAL solarRef IS -1.
        UNTIL _diBodyName() = "DUNA" {
            SET solarRef TO trySolarHoldTick(solarRef).
            WAIT 30.
        }
        WAIT 2.
    }
    IF _diBodyName() <> "DUNA" {
        _diHold("DUNA ENTRY SETUP HOLD",
            "expected Duna SOI, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }

    _diArchiveLog().
    LOCAL entryPe IS DUNA_ENTRY_PE.
    LOCAL entryTol IS MAX(0, DUNA_ENTRY_PE_TOL).
    LOCAL currentPe IS SHIP:PERIAPSIS.
    LOCAL firstPhase IS "DUNA_ENTRY_LOWER_PE".
    IF currentPe <= entryPe + entryTol OR currentPe < _diAtmHeight() {
        SET firstPhase TO "AEROBRAKE".
    } ELSE IF SHIP:STATUS <> "ORBITING" {
        _diHold("DUNA ENTRY SETUP HOLD",
            "Pe is high (" + ROUND(currentPe/1000,1)
            + "km) but status=" + SHIP:STATUS + "; cannot lower Pe.").
        RETURN.
    }

    stateSet("target", "DUNA").
    stateSet("mission_type", "duna_entry").
    stateSet("mission_id", "duna_entry").
    stateSet("mission_name", "Duna Entry").
    stateSet("payloads", LIST("SCISAT")).
    _diCfg("SEQUENCE", DUNA_ENTRY_SEQUENCE).
    _diPersistDunaEntryCfg().
    _diPersistCoastAutomation().
    _diRemoveCfg("LIBS_EXTRA").
    _diClearCapturePlaneCfg().

    stateSet("phase", firstPhase).
    stateSet("lib_band", bootLibBandForPhase(firstPhase, firstPhase)).
    _diClearLibCache().
    stateSet("launch_time", ROUND(TIME:SECONDS)).
    mLog("Duna entry configured: phase=" + firstPhase
        + " Pe=" + ROUND(currentPe/1000,1)
        + "km target=" + ROUND(entryPe/1000,1) + "km.").
    PRINT " ".
    PRINT "Duna entry configured.".
    PRINT "  Start:     " + firstPhase.
    PRINT "  Current Pe:" + ROUND(currentPe/1000,1) + "km".
    PRINT "  Target Pe: " + ROUND(entryPe/1000,1) + "km".
    PRINT "  Rebooting.".
    WAIT 3.
    REBOOT.
}

GLOBAL FUNCTION phaseDunaEntryLowerPe {
    mLogPhase("DUNA_ENTRY_LOWER_PE").
    IF _diBodyName() <> "DUNA" {
        _diHold("DUNA ENTRY LOWER PE HOLD",
            "expected Duna SOI, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" {
        _diHold("DUNA ENTRY LOWER PE HOLD",
            "requires stable Duna orbit; status=" + SHIP:STATUS + ".").
        RETURN.
    }
    IF SHIP:PERIAPSIS <= DUNA_ENTRY_PE + DUNA_ENTRY_PE_TOL {
        mLog("Duna entry Pe already in corridor.").
        nextPhase(xferSeq).
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS planLowerPe(DUNA_ENTRY_PE).
    WAIT 0.2.
    LOCAL dv IS nd:DELTAV:MAG.
    IF dv > DUNA_ENTRY_LOWER_PE_MAX_DV {
        REMOVE nd.
        _diHold("DUNA ENTRY LOWER PE HOLD",
            "lower-Pe burn " + ROUND(dv,1) + "m/s exceeds cap "
            + ROUND(DUNA_ENTRY_LOWER_PE_MAX_DV,1) + "m/s.").
        RETURN.
    }
    IF NOT executeManeuver() {
        _diHold("DUNA ENTRY LOWER PE HOLD", "lower-Pe burn failed.").
        RETURN.
    }
    orbitSummary().
    mLogWarn("STATS duna-entry-lower-pe result PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " dv=" + ROUND(dv,1)).
    nextPhase(xferSeq).
}
