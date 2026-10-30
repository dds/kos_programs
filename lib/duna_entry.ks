// Duna atmospheric capture/entry phases; no Ike flight handler.
@LAZYGLOBAL OFF.

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
    IF nd = 0 { RETURN FALSE. }
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
    LOCAL atmHeight IS dunaIkeAtmHeight().
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
    IF dunaIkeBodyName() <> "DUNA" {
        dunaIkeHold("DUNA AEROCAPTURE HOLD",
            "expected Duna SOI, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }

    LOCAL pe IS SHIP:PERIAPSIS.
    IF pe < DUNA_AEROCAPTURE_MIN_PE OR pe > DUNA_AEROCAPTURE_MAX_PE {
        dunaIkeHold("DUNA AEROCAPTURE HOLD",
            "arrival Pe " + ROUND(pe/1000,1) + "km outside "
            + ROUND(DUNA_AEROCAPTURE_MIN_PE/1000,1) + "-"
            + ROUND(DUNA_AEROCAPTURE_MAX_PE/1000,1) + "km.").
        RETURN.
    }

    mLog("STATS duna-aerocapture setup PeKm=" + ROUND(pe/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " etaPe=" + ROUND(ETA:PERIAPSIS,0)).
    _diRetractDeployables().
    _diOrientRetrograde().
    IF NOT _diMaybeCaptureAssist() {
        dunaIkeHold("DUNA AEROCAPTURE HOLD", "capture-assist burn failed.").
        RETURN.
    }
    _diOrientRetrograde().

    _diWaitForAtmospherePass().
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        dunaIkeHold("DUNA AEROCAPTURE HOLD",
            "ship reached surface during aerocapture; Ike leg abandoned.").
        RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" {
        dunaIkeHold("DUNA AEROCAPTURE HOLD",
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
                dunaIkeHold("DUNA AEROCAPTURE HOLD", "safe-Pe raise burn failed.").
                RETURN.
            }
        } ELSE {
            REMOVE nd.
        }
    }

    SET SAS TO TRUE.
    UNLOCK STEERING.
    orbitSummary().
    mLog("STATS duna-aerocapture result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)).
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseDunaEntrySetup {
    mLogPhase("DUNA_ENTRY_SETUP").
    IF dunaIkeBodyName() = "IKE" {
        mLog("DUNA_ENTRY_SETUP: waiting to exit Ike SOI.").
        IF SHIP:ORBIT:HASNEXTPATCH AND SHIP:ORBIT:NEXTPATCHETA > 60 {
            kacEnsureAlarm("Exit SOI: Ike",
                TIME:SECONDS + SHIP:ORBIT:NEXTPATCHETA,
                "Auto-created by DUNA_ENTRY_SETUP").
        }
        LOCAL solarRef IS -1.
        UNTIL dunaIkeBodyName() = "DUNA" {
            SET solarRef TO trySolarHoldTick(solarRef).
            WAIT 30.
        }
        WAIT 2.
    }
    IF dunaIkeBodyName() <> "DUNA" {
        dunaIkeHold("DUNA ENTRY SETUP HOLD",
            "expected Duna SOI, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }

    dunaIkeArchiveLog().
    LOCAL entryPe IS DUNA_ENTRY_PE.
    LOCAL entryTol IS MAX(0, DUNA_ENTRY_PE_TOL).
    LOCAL currentPe IS SHIP:PERIAPSIS.
    LOCAL firstPhase IS "DUNA_ENTRY_LOWER_PE".
    IF currentPe <= entryPe + entryTol OR currentPe < dunaIkeAtmHeight() {
        SET firstPhase TO "AEROBRAKE".
    } ELSE IF SHIP:STATUS <> "ORBITING" {
        dunaIkeHold("DUNA ENTRY SETUP HOLD",
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
    dunaIkeWriteEntry().
    dunaIkeWriteCoast().

    stateSet("phase", firstPhase).
    stateSet("lib_band", bootLibBandForPhase(firstPhase, firstPhase)).
    dunaIkeClearCache().
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
    IF dunaIkeBodyName() <> "DUNA" {
        dunaIkeHold("DUNA ENTRY LOWER PE HOLD",
            "expected Duna SOI, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" {
        dunaIkeHold("DUNA ENTRY LOWER PE HOLD",
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
        dunaIkeHold("DUNA ENTRY LOWER PE HOLD",
            "lower-Pe burn " + ROUND(dv,1) + "m/s exceeds cap "
            + ROUND(DUNA_ENTRY_LOWER_PE_MAX_DV,1) + "m/s.").
        RETURN.
    }
    IF NOT executeManeuver() {
        dunaIkeHold("DUNA ENTRY LOWER PE HOLD", "lower-Pe burn failed.").
        RETURN.
    }
    orbitSummary().
    mLog("STATS duna-entry-lower-pe result PeKm="
        + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " dv=" + ROUND(dv,1)).
    nextPhase(xferSeq).
}

