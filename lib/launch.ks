// ============================================================
// launch.ks  —  Reusable ascent phases  (0:/lib/launch.ks)
// ============================================================

GLOBAL launchSeq IS LIST().

GLOBAL FUNCTION phaseLaunch {
    mLog("Configuring MechJeb ascent...").

    IF NOT ADDONS:MJ:AVAILABLE {
        mLogError("MechJeb not available — cannot auto-launch.").
        HUDTEXT("ERROR: MechJeb unavailable!", 10, 2, 18, RED, FALSE).
        RETURN.
    }

    LOCAL mjCore IS ADDONS:MJ:CORE.
    mLog("MechJeb core running: " + mjCore:RUNNING).

    LOCAL asc IS ADDONS:MJ:ASCENT.
    SET asc:ENABLED               TO TRUE.
    SET asc:DESIREDALTITUDE       TO CFG["PARKING_ALT"].
    SET asc:DESIREDINCLINATION    TO CFG["LAUNCH_INCLINATION"].
    SET asc:AUTOSTAGE             TO FALSE.
    SET asc:AUTOSTAGELIMIT        TO CFG["LAUNCH_STAGE_LIMIT"].
    SET asc:AUTODEPLOYANTENNAS    TO FALSE.
    SET asc:AUTODEPLOYSOLARPANELS TO FALSE.
    SET asc:AUTOWARP              TO FALSE.
    SET asc:SKIPCIRCULARIZATION   TO FALSE.

    mLog("MechJeb ascent armed. Alt=" + ROUND(CFG["PARKING_ALT"]/1000,0)
        + "km  inc=" + CFG["LAUNCH_INCLINATION"]
        + "°  az=" + CFG["LAUNCH_AZIMUTH"] + "°").

    WHEN stateGet("phase","") = "LAUNCH" OR stateGet("phase","") = "PARKING" THEN {
        LOCAL abortTriggered IS FALSE.

        IF TIME:SECONDS > (stateGetNum("launch_time",0) + 15)
                AND SHIP:APOAPSIS < 30000
                AND SHIP:VERTICALSPEED < 0 {
            SET abortTriggered TO TRUE.
            mLogError("Abort: anomalous trajectory — Ap=" + ROUND(SHIP:APOAPSIS/1000,1) + "km").
        }

        IF SHIP:ALTITUDE < 40000
                AND SHIP:VELOCITY:SURFACE:MAG > 10
                AND VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE) > 45 {
            SET abortTriggered TO TRUE.
            mLogError("Abort: attitude divergence — "
                + ROUND(VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE),1) + "deg off prograde").
        }

        IF ABORT OR AG10 { SET abortTriggered TO TRUE. mLogError("Abort: manual trigger."). }

        IF abortTriggered {
            _launchAbort().
            RETURN.
        }

        PRESERVE.
    }

    stateSetNum("launch_time", TIME:SECONDS).

    mLog("Press ABORT or AG10 within 5s to hold launch.").
    HUDTEXT("T-5: ABORT/AG10 to hold", 5, 2, 16, YELLOW, FALSE).
    LOCAL aborted IS FALSE.
    LOCAL tEnd IS TIME:SECONDS + 5.
    WAIT UNTIL TIME:SECONDS >= tEnd OR ABORT OR AG10.
    IF ABORT OR AG10 { SET aborted TO TRUE. }
    IF aborted {
        mLog("Launch hold — operator abort.").
        SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
        RETURN.
    }
    countdown(3).

    STAGE.
    mLog("Launch — STAGE fired.").
    HUDTEXT("Launch!", 3, 2, 18, YELLOW, FALSE).

    WHEN ascentNeedsStage() THEN {
        IF stateGet("phase","") = "DONE" { RETURN. }
        mLog("Ascent auto-stage at alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
        HUDTEXT("Staging!", 2, 2, 14, YELLOW, FALSE).
        STAGE.
        WAIT 0.5.
        PRESERVE.
    }

    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseFairing {
    IF stateGet("fairing_deployed","false") = "true" {
        mLog("Fairing already deployed.").
        nextPhase(launchSeq).
        RETURN.
    }
    IF SHIP:ALTITUDE < CFG["FAIRING_ALT"] {
        mLog("Waiting for fairing alt " + ROUND(CFG["FAIRING_ALT"]/1000,0) + "km...").
        WAIT UNTIL SHIP:ALTITUDE >= CFG["FAIRING_ALT"].
    }
    _deployFairing().
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseExtendAnts {
    IF SHIP:ALTITUDE < CFG["EXTEND_ALT"] {
        mLog("Waiting for deploy alt " + ROUND(CFG["EXTEND_ALT"]/1000,0) + "km...").
        WAIT UNTIL SHIP:ALTITUDE >= CFG["EXTEND_ALT"].
    }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL sm IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF sm:HASEVENT("Extend Solar Panel") { sm:DOEVENT("Extend Solar Panel"). }
        }
    }
    mLog("Solar panels deployed.").
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL am IS p:GETMODULE("ModuleDeployableAntenna").
            IF am:HASEVENT("Extend Antenna") { am:DOEVENT("Extend Antenna"). }
        }
    }
    mLog("Antennas deployed.").
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseParking {
    mLog("Waiting for stable parking orbit...").
    WAIT UNTIL _isParkingOrbitStable().
    orbitSummary().
    mLog("Stable parking orbit confirmed.").
    nextPhase(launchSeq).
}

// ── Private helpers ──────────────────────────────────────────

LOCAL FUNCTION _launchAbort {
    mLogError("LAUNCH ABORT TRIGGERED.").
    HUDTEXT("ABORT — CUT ENGINES", 5, 2, 20, RED, FALSE).

    SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    LOCAL chutes IS SHIP:PARTSTAGGED("chute_main").
    IF chutes:LENGTH > 0 {
        FOR c IN chutes {
            IF c:HASMODULE("ModuleParachute") {
                LOCAL modu IS c:GETMODULE("ModuleParachute").
                IF modu:HASEVENT("Deploy Chute") {
                    modu:DOEVENT("Deploy Chute").
                } ELSE IF modu:HASEVENT("Arm Parachute") {
                    modu:DOEVENT("Arm Parachute").
                }
            }
        }
        mLog("Parachutes deployed.").
    } ELSE {
        AG6 ON.
        mLogWarn("No tagged chutes found — fired AG6.").
    }

    HUDTEXT("ABORT — CHUTES DEPLOYED", 8, 2, 18, RED, FALSE).
    stateSet("phase", "ABORT").

    IF HOMECONNECTION:ISCONNECTED {
        IF NOT EXISTS("0:/logs") { CREATEDIR("0:/logs"). }
        IF flightLogPath <> "" AND EXISTS(flightLogPath) {
            LOCAL archivePath IS "0:/logs/" + flightLogPath:REPLACE("1:/logs/","").
            COPYPATH(flightLogPath, archivePath).
            mLog("Abort log archived to " + archivePath).
        }
    } ELSE {
        mLogWarn("No KSC link — log NOT archived (will retry in recovery).").
    }

    LOG "" TO "1:/state/obs_off".
    mLog("Abort complete. Awaiting landing.").
}

GLOBAL FUNCTION ascentNeedsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _isParkingOrbitStable {
    LOCAL target IS CFG["PARKING_ALT"].
    LOCAL tol IS target * 0.10.
    RETURN SHIP:PERIAPSIS > (target - tol)
        AND SHIP:APOAPSIS < (target + tol)
        AND SHIP:APOAPSIS > (target - tol).
}

LOCAL FUNCTION _deployFairing {
    LOCAL parts IS SHIP:PARTSTAGGED("main_fairing").
    IF parts:LENGTH = 0 {
        mLogWarn("No part tagged 'main_fairing' — skipping fairing deploy.").
        RETURN.
    }
    LOCAL fairingPart IS parts[0].
    IF NOT fairingPart:HASMODULE("ModuleProceduralFairing") {
        mLogWarn("main_fairing has no ModuleProceduralFairing.").
        RETURN.
    }
    LOCAL myMod IS fairingPart:GETMODULE("ModuleProceduralFairing").
    IF myMod:HASEVENT("Deploy") {
        myMod:DOEVENT("Deploy").
        stateSet("fairing_deployed", "true").
        mLog("Fairing deployed at " + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
    } ELSE {
        mLogWarn("Fairing Deploy event not available.").
    }
}
