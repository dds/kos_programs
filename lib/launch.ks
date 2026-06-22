// ============================================================
// launch.ks  —  Reusable ascent phases  (0:/lib/launch.ks)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL PARKING_ALT IS 80000.
GLOBAL LAUNCH_INCLINATION IS 0.
GLOBAL LAUNCH_AZIMUTH IS 0.
GLOBAL LAUNCH_STAGE_LIMIT IS 0.
GLOBAL LAUNCH_SOLID_STAGE_FRAC IS 0.
GLOBAL ASCENT_STAGED IS FALSE.
GLOBAL FAIRING_ALT IS 72000.
GLOBAL EXTEND_ALT IS 73500.
GLOBAL RECOVERY_PE IS -1.
GLOBAL ORBIT_STAY_TIME IS 0.

LOCAL FUNCTION _launchAge {
    RETURN TIME:SECONDS - stateGetNum("launch_time", 0).
}

LOCAL FUNCTION _ascentAngleError {
    IF SHIP:VELOCITY:SURFACE:MAG < 1 { RETURN -1. }
    RETURN VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE).
}

LOCAL FUNCTION _launchHasAtmosphere {
    RETURN SHIP:BODY:ATM:EXISTS.
}

LOCAL FUNCTION _launchOnSurface {
    RETURN SHIP:STATUS = "PRELAUNCH"
        OR SHIP:STATUS = "LANDED"
        OR SHIP:STATUS = "SPLASHED".
}

LOCAL FUNCTION _launchSetPhase {
    PARAMETER next.
    LOCAL current IS stateGet("phase", "").
    stateSet("phase", next).
    mLog("Phase: " + current + " -> " + next).
    archivePhaseLog().
}

LOCAL FUNCTION _vacuumLaunchCompletePhase {
    IF launchSeq:CONTAINS("PARK") {
        _launchSetPhase("PARK").
        RETURN.
    }
    IF launchSeq:CONTAINS("RETURN_SETUP") {
        _launchSetPhase("RETURN_SETUP").
        RETURN.
    }
    nextPhase(launchSeq).
}

LOCAL FUNCTION _logAscentTelemetry {
    PARAMETER reason.
    mLog("STATS launch telemetry reason=" + reason
        + " age=" + ROUND(_launchAge(),1)
        + " status=" + SHIP:STATUS
        + " massT=" + ROUND(SHIP:MASS,2)
        + " twr=" + ROUND(shipTwr(),2)
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
    IF NOT _launchHasAtmosphere() { RETURN FALSE. }
    IF _launchAge() < 45 { RETURN FALSE. }
    IF SHIP:ALTITUDE < 1000 { RETURN FALSE. }
    IF SHIP:VELOCITY:SURFACE:MAG < 50 { RETURN FALSE. }
    IF SHIP:VERTICALSPEED > -20 { RETURN FALSE. }
    RETURN SHIP:APOAPSIS < 10000.
}

// Vacuum (airless) ascent + circularization now lives in ascent.ks
// so the LAUNCH band does not load the maneuver-node executor. This
// remains the LAUNCH-phase entry for airless bodies; it drives the
// ascent then advances the phase.
GLOBAL FUNCTION phaseVacuumLaunch {
    IF NOT ascentAirlessToOrbit() { RETURN. }
    _vacuumLaunchCompletePhase().
}

GLOBAL FUNCTION phaseLaunch {
    IF NOT _launchHasAtmosphere() {
        phaseVacuumLaunch().
        RETURN.
    }

    SET SAS TO FALSE.
    mLog("Configuring MechJeb ascent...").

    IF NOT ADDONS:MJ:AVAILABLE {
        mLogError("MechJeb not available — cannot auto-launch.").
        HUDTEXT("ERROR: MechJeb unavailable!", 10, 2, 18, RED, FALSE).
        RETURN.
    }

    mLog("MechJeb core running: " + ADDONS:MJ:CORE:RUNNING).

    LOCAL asc IS ADDONS:MJ:ASCENT.
    SET asc:ENABLED               TO FALSE.
    SET asc:DESIREDALTITUDE       TO PARKING_ALT.
    SET asc:DESIREDINCLINATION    TO LAUNCH_INCLINATION.
    SET asc:AUTOSTAGE             TO FALSE.
    SET asc:AUTOSTAGELIMIT        TO 0.
    SET asc:AUTODEPLOYANTENNAS    TO FALSE.
    SET asc:AUTODEPLOYSOLARPANELS TO FALSE.
    SET asc:AUTOWARP              TO FALSE.
    SET asc:SKIPCIRCULARIZATION   TO FALSE.

    mLog("MechJeb ascent armed. Alt=" + ROUND(PARKING_ALT/1000,0)
        + "km  inc=" + LAUNCH_INCLINATION
        + "°  az=" + LAUNCH_AZIMUTH + "°").

    WHEN bootLibAscentWatchPhase() THEN {
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

        IF _launchHasAtmosphere()
                AND SHIP:ALTITUDE < 40000
                AND SHIP:VELOCITY:SURFACE:MAG > 10
                AND VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE) > 45 {
            SET abortTriggered TO TRUE.
            mLogError("Abort: attitude divergence — "
                + ROUND(VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE),1) + "deg off prograde").
            _logAscentTelemetry("abort-attitude-divergence").
        }

        IF stateGet("phase","") <> "SUBORBIT"
                AND SHIP:MAXTHRUST = 0 AND _launchAge() > 60
                AND SHIP:STATUS = "SUB_ORBITAL"
                AND NOT ascentStageAttemptPending()
                AND SHIP:PERIAPSIS < SHIP:BODY:ATM:HEIGHT {
            SET abortTriggered TO TRUE.
            mLogError("Abort: thrust exhausted before orbit (Pe "
                + ROUND(SHIP:PERIAPSIS/1000,1) + "km).").
            _logAscentTelemetry("abort-thrust-exhausted").
        }

        IF ABORT { SET abortTriggered TO TRUE. mLogError("Abort: manual trigger."). }

        IF abortTriggered {
            launchAbort().
            RETURN.
        }

        PRESERVE.
    }

    IF NOT _launchOnSurface() {
        mLogWarn("LAUNCH entered while already " + SHIP:STATUS
            + "; resuming ascent without countdown or staging.").
        IF stateGetNum("launch_time", 0) = 0 {
            stateSet("launch_time", TIME:SECONDS).
        }
        SET asc:ENABLED TO TRUE.
        armAscentStaging().
        nextPhase(launchSeq).
        RETURN.
    }

    stateSet("launch_time", TIME:SECONDS).
    stateSet("launch_site_lat", SHIP:GEOPOSITION:LAT).
    stateSet("launch_site_lng", SHIP:GEOPOSITION:LNG).
    stateSet("launch_vs_nonpos_logged", "false").

    LOCK THROTTLE TO 0.
    mLog("Press ABORT within 5s to hold launch.").
    HUDTEXT("T-5: ABORT to hold", 5, 2, 16, YELLOW, FALSE).
    LOCAL tEnd IS TIME:SECONDS + 5.
    WAIT UNTIL TIME:SECONDS >= tEnd OR ABORT.
    IF ABORT {
        mLog("Launch hold — operator abort.").
        SET asc:ENABLED TO FALSE.
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        RETURN.
    }
    countdown(3).

    IF ABORT OR stateGet("phase", "") = "ABORT" {
        mLogWarn("Launch countdown interrupted by abort; holding ABORT phase.").
        SET asc:ENABLED TO FALSE.
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        RETURN.
    }

    SET asc:ENABLED TO TRUE.
    UNLOCK THROTTLE.
    WAIT 0.1.
    STAGE.
    mLog("Launch — STAGE fired.").
    HUDTEXT("Launch!", 3, 2, 18, YELLOW, FALSE).
    WAIT 0.5.
    ascentRunPostStageHook().

    armAscentStaging().

    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseFairing {
    IF stateGet("fairing_deployed","false") = "true" {
        mLog("Fairing already deployed.").
        nextPhase(launchSeq).
        RETURN.
    }
    IF SHIP:PARTSTAGGED("main_fairing"):LENGTH = 0 {
        mLog("FAIR: no main_fairing part — skipping.").
        nextPhase(launchSeq).
        RETURN.
    }
    LOCAL fairingAlt IS FAIRING_ALT.
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
    // Nothing deployable -> nothing to wait for. Fixed antennas
    // and fixed panels need no altitude gate (flight-found: a
    // craft with only fixed antennas stalled here twice).
    LOCAL deployables IS FALSE.
    IF SHIP:PARTSTAGGED("extend_bay"):LENGTH > 0 {
        SET deployables TO TRUE.
    }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna")
                OR p:HASMODULE("ModuleDeployableSolarPanel") {
            SET deployables TO TRUE.
        }
    }
    IF NOT deployables {
        mLog("ANTS: nothing deployable aboard — skipping.").
        nextPhase(launchSeq).
        RETURN.
    }

    LOCAL extendAlt IS EXTEND_ALT.
    IF extendAlt < 10000 {
        mLogWarn("Unsafe EXTEND_ALT=" + extendAlt + "m; using 73000m.").
        SET extendAlt TO 73000.
    }
    IF SHIP:ALTITUDE < extendAlt {
        mLog("Waiting for deploy alt " + ROUND(extendAlt/1000,0) + "km...").
        // Narrated wait: if this ever stalls again, the log says
        // exactly what state it was stuck looking at.
        LOCAL nextNote IS TIME:SECONDS + 60.
        UNTIL SHIP:ALTITUDE >= extendAlt OR ABORT
                OR (SHIP:STATUS = "ORBITING"
                    AND SHIP:PERIAPSIS > SHIP:BODY:ATM:HEIGHT) {
            IF TIME:SECONDS > nextNote {
                SET nextNote TO TIME:SECONDS + 60.
                mLog("ANTS hold: alt="
                    + ROUND(SHIP:ALTITUDE / 1000, 1) + "km of "
                    + ROUND(extendAlt / 1000, 1) + "km  status="
                    + SHIP:STATUS + "  Pe="
                    + ROUND(SHIP:PERIAPSIS / 1000, 1) + "km.").
            }
            WAIT 1.
        }
    }
    IF ABORT { RETURN. }
    _openExtendBays().
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
    // Stall instrumentation — flight-found twice: the mainline
    // froze between the line above and nextPhase for ~40s during
    // MJ's coast to Ap (triggers kept running; a staging event
    // unfroze it). These brackets pin which side of nextPhase the
    // next occurrence sits on.
    mLog("ANTS complete — advancing.").
    nextPhase(launchSeq).
    mLog("ANTS handler done.").
}

LOCAL FUNCTION _openExtendBays {
    LOCAL opened IS 0.
    LOCAL missing IS 0.
    FOR p IN SHIP:PARTSTAGGED("extend_bay") {
        IF p:HASMODULE("ModuleAnimateGeneric") {
            LOCAL bm IS p:GETMODULE("ModuleAnimateGeneric").
            IF bm:HASEVENT("Open") {
                bm:DOEVENT("Open").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Open Doors") {
                bm:DOEVENT("Open Doors").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Deploy") {
                bm:DOEVENT("Deploy").
                SET opened TO opened + 1.
            } ELSE {
                SET missing TO missing + 1.
            }
        } ELSE {
            SET missing TO missing + 1.
        }
    }
    IF opened > 0 OR missing > 0 {
        mLog("Extend bays opened: " + opened + "  unavailable: " + missing + ".").
        WAIT 1.
    }
}

GLOBAL FUNCTION phaseAnts {
    phaseExtendAnts().
}

LOCAL FUNCTION _launchAngDiff {
    PARAMETER a.
    PARAMETER b.
    LOCAL d IS a - b.
    UNTIL d <= 180 { SET d TO d - 360. }
    UNTIL d > -180 { SET d TO d + 360. }
    RETURN d.
}

LOCAL FUNCTION _logParkingPlaneResult {
    LOCAL planeTarget IS stateGet("prelaunch_plane_target", "").
    IF planeTarget = "" { RETURN. }
    LOCAL tgtInc IS stateGetNum("prelaunch_plane_inc", SHIP:ORBIT:INCLINATION).
    LOCAL tgtLan IS stateGetNum("prelaunch_plane_lan", SHIP:ORBIT:LAN).
    LOCAL incErr IS _launchAngDiff(SHIP:ORBIT:INCLINATION, tgtInc).
    LOCAL lanErr IS _launchAngDiff(SHIP:ORBIT:LAN, tgtLan).
    mLog("Parking plane vs " + planeTarget
        + ": incErr=" + ROUND(incErr, 2)
        + " LANErr=" + ROUND(lanErr, 2) + " deg.").
    mLog("STATS launch-plane result target=" + planeTarget
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION, 3)
        + " lan=" + ROUND(SHIP:ORBIT:LAN, 3)
        + " targetInc=" + ROUND(tgtInc, 3)
        + " targetLan=" + ROUND(tgtLan, 3)
        + " incErr=" + ROUND(incErr, 3)
        + " lanErr=" + ROUND(lanErr, 3)).
}

GLOBAL FUNCTION phaseParking {
    mLog("Waiting for stable parking orbit...").
    WAIT UNTIL _isParkingOrbitStable() OR ABORT.
    IF ABORT { RETURN. }
    // Orbit-insertion timestamp for ORBIT_STAY_TIME holds.
    IF stateGetNum("orbit_start_time", 0) = 0 {
        stateSet("orbit_start_time", ROUND(TIME:SECONDS)).
    }
    orbitSummary().
    _logParkingPlaneResult().
    mLog("Stable parking orbit confirmed.").
    nextPhase(launchSeq).
}

// ── Staging ──────────────────────────────────────────────────

// ── Private helpers ──────────────────────────────────────────

// ── Abort mode ───────────────────────────────────────────────
// launchAbort is only the trigger: stop propulsion, fire the
// vessel abort action group, mark the ABORT phase, and reboot
// into the isolated abort library.
GLOBAL FUNCTION launchAbort {
    LOCK THROTTLE TO 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND eng:ALLOWSHUTDOWN { eng:SHUTDOWN. }
    }

    ABORT ON.
    stateSet("phase", "ABORT").
    REBOOT.
}

LOCAL FUNCTION _isParkingOrbitStable {
    RETURN SHIP:PERIAPSIS > PARKING_ALT * 0.90
        AND SHIP:APOAPSIS < PARKING_ALT * 1.10
        AND SHIP:APOAPSIS > PARKING_ALT * 0.90.
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

// ── Reboot recovery ─────────────────────────────────────────
IF ADDONS:MJ:AVAILABLE AND ADDONS:MJ:ASCENT:ENABLED
        AND stateGetNum("boot_count", 0) > 1 {
    armAscentStaging().
}
