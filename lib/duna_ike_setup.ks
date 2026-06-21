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
    "DUNA_ENTRY_LOWER_PE", "AEROBRAKE", "ATMO_WALK", "DESCENT", "DONE"
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
LOCAL DI_PROFILE_PATH IS "".

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

LOCAL FUNCTION _diPersistCoastAutomation {
    LOG "SET KEEP_WARP TO " + configLiteral(KEEP_WARP) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_AUTO_WARP TO " + configLiteral(COAST_AUTO_WARP) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_AUTO_WARP_MIN TO " + configLiteral(COAST_AUTO_WARP_MIN) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_HIBERNATE TO " + configLiteral(COAST_HIBERNATE) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_HIBERNATE_MIN TO " + configLiteral(COAST_HIBERNATE_MIN) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_WARP_5M_LIMIT TO " + configLiteral(COAST_WARP_5M_LIMIT) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_WARP_1H_LIMIT TO " + configLiteral(COAST_WARP_1H_LIMIT) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_WARP_5H_LIMIT TO " + configLiteral(COAST_WARP_5H_LIMIT) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_WARP_3D_LIMIT TO " + configLiteral(COAST_WARP_3D_LIMIT) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_WARP_10D_LIMIT TO " + configLiteral(COAST_WARP_10D_LIMIT) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_WARP_50D_LIMIT TO " + configLiteral(COAST_WARP_50D_LIMIT) + "." TO DI_PROFILE_PATH.
    LOG "SET COAST_WARP_MAX_RATE TO " + configLiteral(COAST_WARP_MAX_RATE) + "." TO DI_PROFILE_PATH.
}

LOCAL FUNCTION _diPersistDunaEntryCfg {
    LOG "SET DUNA_ENTRY_SEQUENCE TO " + configLiteral(DUNA_ENTRY_SEQUENCE) + "." TO DI_PROFILE_PATH.
    LOG "SET DUNA_ENTRY_PE TO " + configLiteral(DUNA_ENTRY_PE) + "." TO DI_PROFILE_PATH.
    LOG "SET DUNA_ENTRY_PE_TOL TO " + configLiteral(DUNA_ENTRY_PE_TOL) + "." TO DI_PROFILE_PATH.
    LOG "SET DUNA_ENTRY_LOWER_PE_MAX_DV TO " + configLiteral(DUNA_ENTRY_LOWER_PE_MAX_DV) + "." TO DI_PROFILE_PATH.
    LOG "SET AEROBRAKE_TARGETING TO " + configLiteral(AEROBRAKE_TARGETING) + "." TO DI_PROFILE_PATH.
    LOG "SET AEROBRAKE_REENTRY_DIR TO " + configLiteral(AEROBRAKE_REENTRY_DIR) + "." TO DI_PROFILE_PATH.
    LOG "SET AEROBRAKE_ARM_CHUTES TO " + configLiteral(AEROBRAKE_ARM_CHUTES) + "." TO DI_PROFILE_PATH.
    IF AEROBRAKE_DECOUPLE_TAG <> "" {
        LOG "SET AEROBRAKE_DECOUPLE_TAG TO "
            + configLiteral(AEROBRAKE_DECOUPLE_TAG) + "." TO DI_PROFILE_PATH.
    }

    IF DESCENT_CHUTES_TAG <> "" {
        LOG "SET DESCENT_CHUTES_TAG TO "
            + configLiteral(DESCENT_CHUTES_TAG) + "." TO DI_PROFILE_PATH.
    }
    LOG "SET DESCENT_RELEASE_ALT TO " + configLiteral(DESCENT_RELEASE_ALT) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_DROGUE_CUT_ALT TO " + configLiteral(DESCENT_DROGUE_CUT_ALT) + "." TO DI_PROFILE_PATH.
    IF DESCENT_FAIRING_TAG <> "" {
        LOG "SET DESCENT_FAIRING_TAG TO "
            + configLiteral(DESCENT_FAIRING_TAG) + "." TO DI_PROFILE_PATH.
    }
    LOG "SET DESCENT_FAIRING_DEPLOY_SPEED TO " + configLiteral(DESCENT_FAIRING_DEPLOY_SPEED) + "." TO DI_PROFILE_PATH.
    IF DESCENT_DECOUPLER_TAG <> "" {
        LOG "SET DESCENT_DECOUPLER_TAG TO "
            + configLiteral(DESCENT_DECOUPLER_TAG) + "." TO DI_PROFILE_PATH.
    }
    LOG "SET DESCENT_DECOUPLE_ALT TO " + configLiteral(DESCENT_DECOUPLE_ALT) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_HEAT_SHIELD_DROP_ALT TO " + configLiteral(DESCENT_HEAT_SHIELD_DROP_ALT) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_BAY_REOPEN_ALT TO " + configLiteral(DESCENT_BAY_REOPEN_ALT) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_ENGINE_ASSIST TO " + configLiteral(DESCENT_ENGINE_ASSIST) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_ENGINE_ASSIST_ALT TO " + configLiteral(DESCENT_ENGINE_ASSIST_ALT) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS TO " + configLiteral(DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_ENGINE_ASSIST_HIGH_VS TO " + configLiteral(DESCENT_ENGINE_ASSIST_HIGH_VS) + "." TO DI_PROFILE_PATH.
    LOG "SET DESCENT_ENGINE_ASSIST_MAX_THROTTLE TO " + configLiteral(DESCENT_ENGINE_ASSIST_MAX_THROTTLE) + "." TO DI_PROFILE_PATH.
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
    missionOverrideClear().
    SET DI_PROFILE_PATH TO missionProfileBegin(stateGet("vehicle", ""), "duna_ike_flyby").

    LOG "SET MISSION_ID TO " + configLiteral("duna_ike_flyby") + "." TO DI_PROFILE_PATH.
    LOG "SET MISSION_NAME TO " + configLiteral("Duna/Ike Flyby") + "." TO DI_PROFILE_PATH.
    LOG "SET MISSION_TYPE TO " + configLiteral("duna_ike_flyby") + "." TO DI_PROFILE_PATH.
    LOG "SET TARGET_ TO " + configLiteral("IKE") + "." TO DI_PROFILE_PATH.
    LOG "SET PAYLOADS TO " + configLiteral(LIST("SCISAT")) + "." TO DI_PROFILE_PATH.
    LOG "SET SEQUENCE TO " + configLiteral(IKE_FLYBY_SEQUENCE) + "." TO DI_PROFILE_PATH.
    LOG "SET CAPTURE_PE TO " + configLiteral(IKE_FLYBY_PE) + "." TO DI_PROFILE_PATH.
    LOG "SET BPLANE_TARGET TO " + configLiteral("IKE") + "." TO DI_PROFILE_PATH.
    LOG "SET FLYBY_POST_PE_HOLD TO " + configLiteral(IKE_FLYBY_POST_PE_HOLD) + "." TO DI_PROFILE_PATH.
    LOG "SET FLYBY_EXIT_SOI TO " + configLiteral(IKE_FLYBY_EXIT_SOI) + "." TO DI_PROFILE_PATH.
    LOG "SET TRANSFER_SCAN_LOOKAHEAD_HOURS TO " + configLiteral(IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS) + "." TO DI_PROFILE_PATH.
    LOG "SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO " + configLiteral(IKE_TRANSFER_SCAN_SAMPLES_PER_ORBIT) + "." TO DI_PROFILE_PATH.
    LOG "SET BPLANE_DV_CAP TO " + configLiteral(IKE_BPLANE_DV_CAP) + "." TO DI_PROFILE_PATH.
    LOG "SET REFINE_BPLANE_DV_CAP TO " + configLiteral(IKE_REFINE_BPLANE_DV_CAP) + "." TO DI_PROFILE_PATH.
    LOG "SET REFINE_BPLANE_MAX_BURNS TO " + configLiteral(IKE_REFINE_BPLANE_MAX_BURNS) + "." TO DI_PROFILE_PATH.
    IF IKE_FLYBY_INC >= 0 {
        LOG "SET CAPTURE_INC TO " + configLiteral(IKE_FLYBY_INC) + "." TO DI_PROFILE_PATH.
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
    missionOverrideClear().
    SET DI_PROFILE_PATH TO missionProfileBegin(stateGet("vehicle", ""), "duna_entry").

    LOG "SET MISSION_ID TO " + configLiteral("duna_entry") + "." TO DI_PROFILE_PATH.
    LOG "SET MISSION_NAME TO " + configLiteral("Duna Entry") + "." TO DI_PROFILE_PATH.
    LOG "SET MISSION_TYPE TO " + configLiteral("duna_entry") + "." TO DI_PROFILE_PATH.
    LOG "SET TARGET_ TO " + configLiteral("DUNA") + "." TO DI_PROFILE_PATH.
    LOG "SET PAYLOADS TO " + configLiteral(LIST("SCISAT")) + "." TO DI_PROFILE_PATH.
    LOG "SET SEQUENCE TO " + configLiteral(DUNA_ENTRY_SEQUENCE) + "." TO DI_PROFILE_PATH.
    _diPersistDunaEntryCfg().
    _diPersistCoastAutomation().

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
