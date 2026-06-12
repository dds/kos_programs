// ============================================================
// launch.ks  —  Reusable ascent phases  (0:/lib/launch.ks)
// ============================================================

LOCAL FUNCTION _launchAge {
    RETURN TIME:SECONDS - stateGetNum("launch_time", 0).
}

LOCAL FUNCTION _ascentAngleError {
    IF SHIP:VELOCITY:SURFACE:MAG < 1 { RETURN -1. }
    RETURN VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE).
}

LOCAL FUNCTION _ascentTwr {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / (SHIP:MASS * 9.81).
}

LOCAL FUNCTION _logAscentTelemetry {
    PARAMETER reason.
    mLogWarn("STATS launch telemetry reason=" + reason
        + " age=" + ROUND(_launchAge(),1)
        + " status=" + SHIP:STATUS
        + " massT=" + ROUND(SHIP:MASS,2)
        + " twr=" + ROUND(_ascentTwr(),2)
        + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)
        + " maxThrust=" + ROUND(SHIP:MAXTHRUST,1)
        + " altKm=" + ROUND(SHIP:ALTITUDE/1000,2)
        + " radarKm=" + ROUND(ALT:RADAR/1000,2)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,2)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,2)
        + " vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " vVert=" + ROUND(SHIP:VERTICALSPEED,1)
        + " pitch=" + ROUND(SHIP:FACING:PITCH,1)
        + " roll=" + ROUND(SHIP:FACING:ROLL,1)
        + " heading=" + ROUND(SHIP:FACING:YAW,1)
        + " angleErr=" + ROUND(_ascentAngleError(),1)
        + " phase=" + stateGet("phase", "")).
}

LOCAL FUNCTION _badAscentTrajectory {
    IF _launchAge() < 45 { RETURN FALSE. }
    IF SHIP:ALTITUDE < 1000 { RETURN FALSE. }
    IF SHIP:VELOCITY:SURFACE:MAG < 50 { RETURN FALSE. }
    IF SHIP:VERTICALSPEED > -20 { RETURN FALSE. }
    RETURN SHIP:APOAPSIS < 10000.
}

GLOBAL FUNCTION phaseLaunch {
    mLog("Configuring MechJeb ascent...").

    IF NOT ADDONS:MJ:AVAILABLE {
        mLogError("MechJeb not available — cannot auto-launch.").
        HUDTEXT("ERROR: MechJeb unavailable!", 10, 2, 18, RED, FALSE).
        RETURN.
    }

    LOCAL mjCore IS ADDONS:MJ:CORE.
    mLog("MechJeb core running: " + mjCore:RUNNING).

    LOCAL parkingAlt IS cfgNum("PARKING_ALT", 80000).
    LOCAL launchInc IS cfgNum("LAUNCH_INCLINATION", 0).
    LOCAL launchAzimuth IS cfgNum("LAUNCH_AZIMUTH", 0).

    LOCAL asc IS ADDONS:MJ:ASCENT.
    SET asc:ENABLED               TO TRUE.
    SET asc:DESIREDALTITUDE       TO parkingAlt.
    SET asc:DESIREDINCLINATION    TO launchInc.
    SET asc:AUTOSTAGE             TO FALSE.
    SET asc:AUTOSTAGELIMIT        TO 0.
    SET asc:AUTODEPLOYANTENNAS    TO FALSE.
    SET asc:AUTODEPLOYSOLARPANELS TO FALSE.
    SET asc:AUTOWARP              TO FALSE.
    SET asc:SKIPCIRCULARIZATION   TO FALSE.

    mLog("MechJeb ascent armed. Alt=" + ROUND(parkingAlt/1000,0)
        + "km  inc=" + launchInc
        + "°  az=" + launchAzimuth + "°").

    WHEN stateGet("phase","") = "LAUNCH" OR stateGet("phase","") = "FAIR"
            OR stateGet("phase","") = "ANTS" OR stateGet("phase","") = "PARK"
            OR stateGet("phase","") = "SUBORBIT" THEN {
        LOCAL abortTriggered IS FALSE.

        IF stateGet("launch_vs_nonpos_logged", "false") <> "true"
                AND _launchAge() > 10
                AND SHIP:ALTITUDE > 100
                AND SHIP:VELOCITY:SURFACE:MAG > 10
                AND SHIP:VERTICALSPEED <= 0 {
            stateSet("launch_vs_nonpos_logged", "true").
            _logAscentTelemetry("vertical-speed-nonpositive").
        }

        IF _badAscentTrajectory() {
            SET abortTriggered TO TRUE.
            mLogError("Abort: anomalous trajectory — Ap=" + ROUND(SHIP:APOAPSIS/1000,1)
                + "km Vs=" + ROUND(SHIP:VERTICALSPEED,1)
                + "m/s alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km").
            _logAscentTelemetry("abort-anomalous-trajectory").
        }

        IF SHIP:ALTITUDE < 40000
                AND SHIP:VELOCITY:SURFACE:MAG > 10
                AND VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE) > 45 {
            SET abortTriggered TO TRUE.
            mLogError("Abort: attitude divergence — "
                + ROUND(VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE),1) + "deg off prograde").
            _logAscentTelemetry("abort-attitude-divergence").
        }

        IF ABORT OR AG10 { SET abortTriggered TO TRUE. mLogError("Abort: manual trigger."). }

        IF abortTriggered {
            launchAbort().
            RETURN.
        }

        PRESERVE.
    }

    stateSetNum("launch_time", TIME:SECONDS).
    stateSetNum("launch_site_lat", SHIP:GEOPOSITION:LAT).
    stateSetNum("launch_site_lng", SHIP:GEOPOSITION:LNG).
    stateSet("launch_vs_nonpos_logged", "false").

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

    armAscentStaging().

    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseFairing {
    IF stateGet("fairing_deployed","false") = "true" {
        mLog("Fairing already deployed.").
        nextPhase(launchSeq).
        RETURN.
    }
    LOCAL fairingAlt IS cfgNum("FAIRING_ALT", 72000).
    IF fairingAlt < 10000 {
        mLogWarn("Unsafe FAIRING_ALT=" + fairingAlt + "m; using 71500m.").
        SET fairingAlt TO 71500.
    }
    IF SHIP:ALTITUDE < fairingAlt {
        mLog("Waiting for fairing alt " + ROUND(fairingAlt/1000,0) + "km...").
        // A stable orbit above the atmosphere is deploy-safe even
        // below the altitude line (flight-found: a 74km parking
        // target can leave Ap under the default threshold and the
        // wait never completes).
        WAIT UNTIL SHIP:ALTITUDE >= fairingAlt OR ABORT
            OR (SHIP:STATUS = "ORBITING"
                AND SHIP:PERIAPSIS > SHIP:BODY:ATM:HEIGHT).
    }
    IF ABORT { RETURN. }
    _deployFairing().
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseFair {
    phaseFairing().
}

GLOBAL FUNCTION phaseExtendAnts {
    LOCAL extendAlt IS cfgNum("EXTEND_ALT", 73500).
    IF extendAlt < 10000 {
        mLogWarn("Unsafe EXTEND_ALT=" + extendAlt + "m; using 73000m.").
        SET extendAlt TO 73000.
    }
    IF SHIP:ALTITUDE < extendAlt {
        mLog("Waiting for deploy alt " + ROUND(extendAlt/1000,0) + "km...").
        WAIT UNTIL SHIP:ALTITUDE >= extendAlt OR ABORT
            OR (SHIP:STATUS = "ORBITING"
                AND SHIP:PERIAPSIS > SHIP:BODY:ATM:HEIGHT).
    }
    IF ABORT { RETURN. }
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

GLOBAL FUNCTION phaseAnts {
    phaseExtendAnts().
}

GLOBAL FUNCTION phaseParking {
    mLog("Waiting for stable parking orbit...").
    WAIT UNTIL _isParkingOrbitStable() OR ABORT.
    IF ABORT { RETURN. }
    // Orbit-insertion timestamp for ORBIT_STAY_TIME holds.
    IF stateGetNum("orbit_start_time", 0) = 0 {
        stateSetNum("orbit_start_time", ROUND(TIME:SECONDS)).
    }
    orbitSummary().
    mLog("Stable parking orbit confirmed.").
    nextPhase(launchSeq).
}

// ── Staging ──────────────────────────────────────────────────

LOCAL _stagingArmed IS FALSE.

GLOBAL FUNCTION armAscentStaging {
    IF _stagingArmed { RETURN. }
    SET _stagingArmed TO TRUE.

    WHEN ascentNeedsStage() THEN {
        LOCAL ph IS stateGet("phase","").
        IF ph = "DONE" OR ph = "ABORT" { RETURN. }
        IF NOT ADDONS:MJ:ASCENT:ENABLED { RETURN. }
        mLog("Ascent auto-stage at alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
        HUDTEXT("Staging!", 2, 2, 14, YELLOW, FALSE).
        STAGE.
        WAIT 0.5.
        PRESERVE.
    }

    IF CFG:HASKEY("RECOVERY_PE") {
        WHEN SHIP:PERIAPSIS >= CFG["RECOVERY_PE"]
                AND ADDONS:MJ:AVAILABLE AND ADDONS:MJ:ASCENT:ENABLED THEN {
            mLog("Recovery staging: Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km, ejecting stage.").
            HUDTEXT("Recovery staging!", 3, 2, 14, YELLOW, FALSE).
            SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
            LOCK THROTTLE TO 0.
            WAIT 0.3.
            STAGE.
            WAIT 0.5.
            mLog("Ascent complete post-staging, raising Pe now.").
            LOCK STEERING TO SHIP:PROGRADE.
            LOCK THROTTLE TO 1.
            WAIT UNTIL SHIP:PERIAPSIS >= cfgNum("PARKING_ALT", 80000) * 0.95.
            LOCK THROTTLE TO 0.
            UNLOCK THROTTLE.
            UNLOCK STEERING.
            SET SAS TO TRUE.
            orbitSummary().
            stateSet("phase", "PARK").
        }
    }

    mLog("Ascent staging armed.").
}

// ── Private helpers ──────────────────────────────────────────

// ── Abort mode ───────────────────────────────────────────────
// launchAbort is the trigger: cut propulsion, fire the vessel's
// VAB Abort action group (escape motor / separation), and route
// the phase machine into ABORT. The ABORT phase below does the
// real work — chute verification, descent monitoring, archiving,
// operator card — and is reboot-safe (PHASE ABORT = launch, so a
// power cycle mid-descent resumes there). GLOBAL: the
// suborbit lib calls it too.
//
// Setting ABORT ON also flips the condition every ascent-phase
// wait watches, so the main thread breaks out of its altitude
// wait even when the abort fired from the WHEN watcher.
GLOBAL FUNCTION launchAbort {
    mLogError("LAUNCH ABORT TRIGGERED.").
    HUDTEXT("ABORT", 5, 2, 20, RED, FALSE).

    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND eng:ALLOWSHUTDOWN { eng:SHUTDOWN. }
    }

    ABORT ON.
    SET SAS TO TRUE.

    LOG "" TO "1:/run/obs_off".
    stateSet("phase", "ABORT").
}

LOCAL FUNCTION _abortChuteParts {
    LOCAL parts IS SHIP:PARTSTAGGED("chute_main").
    IF parts:LENGTH > 0 { RETURN parts. }
    SET parts TO LIST().
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleParachute") OR p:HASMODULE("RealChuteModule") {
            parts:ADD(p).
        }
    }
    RETURN parts.
}

// Arm every chute (deploy-when-safe), then VERIFY the arm took:
// once armed/deployed the arm event disappears. Returns
// LIST(found, armed).
LOCAL FUNCTION _abortArmChutes {
    LOCAL found IS 0.
    FOR p IN _abortChuteParts() {
        LOCAL moduleName IS "".
        IF p:HASMODULE("ModuleParachute") { SET moduleName TO "ModuleParachute". }
        ELSE IF p:HASMODULE("RealChuteModule") { SET moduleName TO "RealChuteModule". }
        IF moduleName <> "" {
            SET found TO found + 1.
            LOCAL m IS p:GETMODULE(moduleName).
            IF m:HASEVENT("arm parachute") { m:DOEVENT("arm parachute"). }
            ELSE IF m:HASEVENT("deploy chute") { m:DOEVENT("deploy chute"). }
            ELSE IF m:HASEVENT("deploy") { m:DOEVENT("deploy"). }
        }
    }
    IF found = 0 { RETURN LIST(0, 0). }
    WAIT 0.5.

    LOCAL armed IS 0.
    FOR p IN _abortChuteParts() {
        LOCAL moduleName IS "".
        IF p:HASMODULE("ModuleParachute") { SET moduleName TO "ModuleParachute". }
        ELSE IF p:HASMODULE("RealChuteModule") { SET moduleName TO "RealChuteModule". }
        IF moduleName <> "" {
            LOCAL m IS p:GETMODULE(moduleName).
            IF NOT m:HASEVENT("arm parachute") AND NOT m:HASEVENT("deploy") {
                SET armed TO armed + 1.
            } ELSE {
                mLogWarn("Chute NOT armed: " + p:TITLE
                    + " events: " + m:ALLEVENTNAMES:JOIN(", ")).
            }
        }
    }
    RETURN LIST(found, armed).
}

// ABORT phase: post-abort descent to touchdown.
GLOBAL FUNCTION phaseAbort {
    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }
    UNLOCK ALL.
    SET SAS TO TRUE.

    mLogWarn("STATS abort entry alt=" + ROUND(SHIP:ALTITUDE, 0)
        + " vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)
        + " vs=" + ROUND(SHIP:VERTICALSPEED, 1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000, 1)).
    IF HOMECONNECTION:ISCONNECTED { archiveLog(). }

    IF SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "SPLASHED" {
        // Give the escape motor / separation a beat before chutes.
        WAIT 1.5.
        LOCAL chuteState IS _abortArmChutes().
        IF chuteState[0] = 0 {
            mLogError("NO PARACHUTES FOUND — firing AG6 backup.").
            HUDTEXT("ABORT: NO CHUTES — AG6 FIRED", 8, 2, 18, RED, FALSE).
            AG6 ON.
        } ELSE {
            IF chuteState[1] < chuteState[0] {
                mLogWarn("CHUTES: only " + chuteState[1] + "/" + chuteState[0]
                    + " armed — re-arming during descent.").
            } ELSE {
                mLog("CHUTES: " + chuteState[1] + "/" + chuteState[0]
                    + " armed and ready.").
            }
            HUDTEXT("ABORT: chutes " + chuteState[1] + "/" + chuteState[0]
                + " armed", 8, 2, 16, YELLOW, FALSE).
        }

        LOCAL nextCheck IS TIME:SECONDS + 20.
        UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            IF TIME:SECONDS >= nextCheck {
                SET nextCheck TO TIME:SECONDS + 20.
                IF chuteState[0] > 0 AND chuteState[1] < chuteState[0] {
                    SET chuteState TO _abortArmChutes().
                    mLog("Chute re-arm: " + chuteState[1] + "/"
                        + chuteState[0] + " armed.").
                }
                mLog("Abort descent: alt=" + ROUND(SHIP:ALTITUDE/1000, 1)
                    + "km vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 0)
                    + "m/s vs=" + ROUND(SHIP:VERTICALSPEED, 0) + "m/s.").
            }
            WAIT 1.
        }
    }

    mLogWarn("STATS abort landed status=" + SHIP:STATUS
        + " lat=" + ROUND(SHIP:GEOPOSITION:LAT, 4)
        + " lng=" + ROUND(SHIP:GEOPOSITION:LNG, 4)).

    // Antennas back out so the log archive has a link.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL am IS p:GETMODULE("ModuleDeployableAntenna").
            IF am:HASEVENT("Extend Antenna") { am:DOEVENT("Extend Antenna"). }
        }
    }
    WAIT 3.
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Abort log archived.").
    } ELSE {
        mLogWarn("No KSC link — log NOT archived; reboot when linked.").
    }

    PRINT " ".
    PRINT "  ABORT COMPLETE — " + SHIP:STATUS.
    PRINT "  ─────────────────────────────────────────────".
    PRINT "  Clear abort:    SET ABORT TO FALSE.".
    PRINT "  Refly:          RUNPATH('1:/cmd/setphase', 'LAUNCH'). + reboot".
    PRINT "  Other mission:  RUNPATH('1:/cmd/setphase', 'LAUNCH', '<id>').".
    PRINT "  State dump:     RUNPATH('1:/cmd/dump').".
    PRINT "  Backup chutes:  AG6 ON.".
    yieldToPrompt().
}

GLOBAL FUNCTION ascentNeedsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _isParkingOrbitStable {
    LOCAL target IS cfgNum("PARKING_ALT", 80000).
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

GLOBAL FUNCTION phasePark {
    phaseParking().
}

// ── Pre-launch config screen ────────────────────────────────

GLOBAL FUNCTION confirmLaunch {
    PARAMETER printFn.
    LOCAL phase IS stateGet("phase", "").
    IF phase <> "" AND phase <> "PRELAUNCH" AND phase <> "LAUNCH" {
        RETURN TRUE.
    }

    printFn:CALL().
    uiPrompt("SPACE to launch / ESC to abort / 30s auto-launch").
    uiPrompt("Edit CFG in terminal to override").
    PRINT " ".
    LOCAL deadline IS TIME:SECONDS + 30.
    LOCAL confirmed IS FALSE.
    LOCAL aborted IS FALSE.
    UNTIL TIME:SECONDS >= deadline OR confirmed OR aborted {
        LOCAL remaining IS ROUND(deadline - TIME:SECONDS, 0).
        LOCAL bar IS "".
        LOCAL filled IS ROUND(30 - remaining, 0).
        LOCAL j IS 0.
        UNTIL j >= 30 {
            IF j < filled { SET bar TO bar + "=". }
            ELSE { SET bar TO bar + ".". }
            SET j TO j + 1.
        }
        PRINT "  [" + bar + "] T-" + ("" + remaining):PADLEFT(2) + "s   " AT (0, TERMINAL:HEIGHT - 1).
        IF TERMINAL:INPUT:HASCHAR {
            LOCAL ch IS TERMINAL:INPUT:GETCHAR().
            IF UNCHAR(ch) = 27 {
                SET aborted TO TRUE.
            } ELSE IF UNCHAR(ch) = 32 OR UNCHAR(ch) = 0 {
                SET confirmed TO TRUE.
            }
        }
        WAIT 0.2.
    }
    IF aborted {
        PRINT "  [==============================] ABORT    " AT (0, TERMINAL:HEIGHT - 1).
        mLog("Launch aborted by operator.").
        RETURN FALSE.
    }
    PRINT "  [==============================] GO       " AT (0, TERMINAL:HEIGHT - 1).
    RETURN TRUE.
}

// ── Rocket main skeleton ──────────────────────────────────────

// Shared main() boilerplate for rocket craft scripts. Handles
// both fresh launches and mid-mission resume (confirmLaunch is
// a no-op when phase is past LAUNCH).
//   vehicleName   - string for logging (e.g. "FR2")
//   seqBuilder    - delegate that returns the phase sequence LIST
//   configPrinter - delegate for flight plan display (passed to confirmLaunch)
//   phaseMapBuilder - delegate that returns the phase LEXICON
//   options       - optional LEXICON:
//     "skipConfirmCheck" - delegate returning TRUE to skip confirmLaunch
//     "preRun"          - delegate called after seq setup, before runPhases
GLOBAL FUNCTION rocketMain {
    PARAMETER vehicleName.
    PARAMETER seqBuilder.
    PARAMETER configPrinter.
    PARAMETER phaseMapBuilder.
    PARAMETER options IS LEXICON().

    LOCAL seq IS seqBuilder:CALL().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase(vehicleName + " MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    IF options:HASKEY("preRun") {
        options["preRun"]:CALL().
    }

    LOCAL skipConfirm IS FALSE.
    IF options:HASKEY("skipConfirmCheck") {
        SET skipConfirm TO options["skipConfirmCheck"]:CALL().
    }
    IF NOT skipConfirm {
        IF NOT confirmLaunch(configPrinter) { RETURN. }
    }

    runPhases(phaseMapBuilder:CALL()).
}

// ── Reboot recovery ─────────────────────────────────────────
IF ADDONS:MJ:AVAILABLE AND ADDONS:MJ:ASCENT:ENABLED
        AND stateGetNum("boot_count", 0) > 1 {
    armAscentStaging().
}
