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

LOCAL FUNCTION _launchCfgNum {
    PARAMETER key.
    PARAMETER defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _norm360 {
    PARAMETER angle.
    LOCAL result IS angle.
    UNTIL result >= 0 { SET result TO result + 360. }
    UNTIL result < 360 { SET result TO result - 360. }
    RETURN result.
}

LOCAL FUNCTION _targetLaunchPlaneInc {
    LOCAL inc IS _launchCfgNum("LAUNCH_INCLINATION", 0).
    IF CFG:HASKEY("TARGET_INCLINATION") AND CFG["TARGET_INCLINATION"] >= 0 {
        SET inc TO CFG["TARGET_INCLINATION"].
    }
    IF CFG:HASKEY("CAPTURE_INC") {
        SET inc TO CFG["CAPTURE_INC"].
    }
    RETURN inc.
}

LOCAL FUNCTION _latIncOk {
    PARAMETER latitude_.
    PARAMETER inclination_.
    LOCAL maxLat IS inclination_.
    IF maxLat > 90 { SET maxLat TO 180 - maxLat. }
    RETURN ABS(latitude_) <= ABS(maxLat) AND ABS(latitude_) < 90.
}

LOCAL FUNCTION _etaToLaunchPlane {
    PARAMETER ascendingNode.
    PARAMETER targetLan.
    PARAMETER targetInc.

    LOCAL eta_ IS -1.
    LOCAL latitude_ IS SHIP:LATITUDE.
    LOCAL longitude_ IS SHIP:LONGITUDE.
    IF NOT _latIncOk(latitude_, targetInc) { RETURN eta_. }

    LOCAL relLng IS 0.
    IF ABS(ABS(targetInc) - 90) > 0.001 {
        SET relLng TO ARCSIN(TAN(latitude_) / TAN(targetInc)).
    }
    IF NOT ascendingNode { SET relLng TO 180 - relLng. }

    LOCAL geoLng IS _norm360(targetLan + relLng - SHIP:BODY:ROTATIONANGLE).
    LOCAL nodeAngle IS _norm360(geoLng - longitude).
    SET eta_ TO (nodeAngle / 360) * SHIP:BODY:ROTATIONPERIOD.
    RETURN eta_.
}

LOCAL FUNCTION _planeLaunchWait {
    PARAMETER targetLan.
    PARAMETER targetInc.
    PARAMETER leadTime.

    LOCAL period IS SHIP:BODY:ROTATIONPERIOD.
    LOCAL best IS -1.
    LOCAL etaAn IS _etaToLaunchPlane(TRUE, targetLan, targetInc).
    LOCAL etaDn IS _etaToLaunchPlane(FALSE, targetLan, targetInc).
    FOR eta IN LIST(etaAn, etaDn) {
        IF eta >= 0 {
            LOCAL waitTime IS eta - leadTime.
            UNTIL waitTime >= 0 { SET waitTime TO waitTime + period. }
            IF best < 0 OR waitTime < best { SET best TO waitTime. }
        }
    }
    RETURN best.
}

LOCAL FUNCTION _waitForPrelaunchUt {
    PARAMETER targetUt.

    LOCAL kacAlarmId IS "".
    IF ADDONS:KAC:AVAILABLE {
        LOCAL alarmUt IS targetUt - 30.
        IF alarmUt > TIME:SECONDS {
            LOCAL alm IS ADDALARM("Raw", alarmUt, "FR3 prelaunch window", "Auto-created by PRELAUNCH").
            SET alm:ACTION TO "KillWarp".
            SET kacAlarmId TO alm:ID.
        }
    }

    IF targetUt - TIME:SECONDS > 60 { SET WARP TO 4. }
    UNTIL TIME:SECONDS >= targetUt OR ABORT OR AG10 {
        LOCAL remaining IS MAX(0, targetUt - TIME:SECONDS).
        HUDTEXT("Prelaunch window in " + ROUND(remaining, 0) + "s", 5, 2, 13, CYAN, FALSE).
        WAIT MIN(30, MAX(0.5, remaining)).
    }
    SET WARP TO 0.

    IF kacAlarmId <> "" {
        DELETEALARM(kacAlarmId).
    }
}

// ── Launch-to-rendezvous window ──────────────────────────────
// For rescue/rendezvous missions: derive the launch window from
// the target vessel itself — wait until the launch site rotates
// into the target's orbital plane AND the target's along-track
// position is right, so the ascent ends with the target slightly
// ahead. Knobs (CFG): LAUNCH_RDV_ASCENT_TIME (300s pad-to-orbit
// estimate), LAUNCH_RDV_LEAD (30 deg ahead of the launch-site
// direction at insertion), LAUNCH_RDV_MAX_WINDOWS (16 plane
// crossings ~ 2 Kerbin days).

LOCAL FUNCTION _vesselNamed {
    PARAMETER nm.
    LOCAL vs IS LIST().
    LIST TARGETS IN vs.
    FOR tv IN vs {
        IF tv:NAME = nm { RETURN tv. }
    }
    RETURN 0.
}

LOCAL FUNCTION _norm180 {
    PARAMETER angle.
    RETURN _norm360(angle + 180) - 180.
}

// Body-centered inertial direction of the launch site at a future
// time: the site then equals the CURRENT direction of the surface
// point rotated forward in longitude — uses the game's own LATLNG
// mapping, no spin-axis sign gymnastics.
LOCAL FUNCTION _siteDirAt {
    PARAMETER ut.
    LOCAL siteGeo IS SHIP:GEOPOSITION.
    LOCAL lngThen IS siteGeo:LNG
        + 360 * (ut - TIME:SECONDS) / SHIP:BODY:ROTATIONPERIOD.
    RETURN (LATLNG(siteGeo:LAT, lngThen):POSITION
        - SHIP:BODY:POSITION):NORMALIZED.
}

LOCAL FUNCTION _tgtDirAt {
    PARAMETER ves.
    PARAMETER ut.
    RETURN (POSITIONAT(ves, ut) - POSITIONAT(SHIP:BODY, ut)):NORMALIZED.
}

// Signed along-track lead of the target relative to the launch
// site direction at insertion time: positive = the target passed
// overhead BEFORE insertion (it is ahead of us). Found by scanning
// for the moment the target crosses the site direction —
// sign-robust, no cross products in a left-handed frame.
LOCAL FUNCTION _rdvLeadAngle {
    PARAMETER ves.
    PARAMETER tIns.
    LOCAL period IS ves:ORBIT:PERIOD.
    LOCAL siteDir IS _siteDirAt(tIns).

    LOCAL bestT IS tIns.
    LOCAL bestAng IS VANG(_tgtDirAt(ves, tIns), siteDir).
    LOCAL step IS period / 36.
    LOCAL scanT IS tIns - period / 2.
    UNTIL scanT > tIns + period / 2 {
        LOCAL ang IS VANG(_tgtDirAt(ves, scanT), siteDir).
        IF ang < bestAng { SET bestAng TO ang. SET bestT TO scanT. }
        SET scanT TO scanT + step.
    }
    LOCAL coarseT IS bestT.
    SET scanT TO coarseT - step.
    UNTIL scanT > coarseT + step {
        LOCAL ang IS VANG(_tgtDirAt(ves, scanT), siteDir).
        IF ang < bestAng { SET bestAng TO ang. SET bestT TO scanT. }
        SET scanT TO scanT + step / 12.
    }
    RETURN (tIns - bestT) * 360 / period.
}

// Rendezvous target name: explicit config first; otherwise — for
// missions without a CAPTURE_LAN plane target — the vessel the
// operator has targeted in the game, persisted to mission state
// so reboots keep it.
LOCAL FUNCTION _prelaunchRdvTarget {
    IF CFG:HASKEY("RENDEZVOUS_TARGET") AND CFG["RENDEZVOUS_TARGET"] <> "" {
        RETURN CFG["RENDEZVOUS_TARGET"].
    }
    IF NOT CFG:HASKEY("CAPTURE_LAN") AND HASTARGET
            AND TARGET:ISTYPE("Vessel") {
        LOCAL nm IS TARGET:NAME.
        cfgSet("RENDEZVOUS_TARGET", nm).
        stateSet("mission_cfg_RENDEZVOUS_TARGET", nm).
        mLog("PRELAUNCH: rendezvous target from game target: " + nm).
        RETURN nm.
    }
    RETURN "".
}

LOCAL FUNCTION _prelaunchToVessel {
    PARAMETER rdvName.
    LOCAL ves IS _vesselNamed(rdvName).
    IF NOT ves:ISTYPE("Vessel") {
        mLogError("PRELAUNCH: rendezvous target '" + rdvName
            + "' not found — holding.").
        yieldToPrompt().
        RETURN.
    }
    IF ves:BODY:NAME <> SHIP:BODY:NAME {
        mLogError("PRELAUNCH: target orbits " + ves:BODY:NAME
            + ", not " + SHIP:BODY:NAME + " — holding.").
        yieldToPrompt().
        RETURN.
    }

    LOCAL tgtInc IS ves:ORBIT:INCLINATION.
    LOCAL tgtLan IS ves:ORBIT:LAN.
    LOCAL ascentTime IS _launchCfgNum("LAUNCH_RDV_ASCENT_TIME", 300).
    LOCAL desiredLead IS _launchCfgNum("LAUNCH_RDV_LEAD", 30).
    LOCAL maxWindows IS _launchCfgNum("LAUNCH_RDV_MAX_WINDOWS", 16).
    LOCAL leadTime IS _launchCfgNum("PRELAUNCH_PLANE_LEAD", 145).
    LOCAL rotPeriod IS SHIP:BODY:ROTATIONPERIOD.

    mLog("PRELAUNCH: rendezvous with " + ves:NAME
        + "  inc=" + ROUND(tgtInc, 2) + "  LAN=" + ROUND(tgtLan, 1)
        + "  alt=" + ROUND(ves:ORBIT:APOAPSIS / 1000, 0) + "km.").

    // Candidate launch times: each pass of the site through the
    // target plane (ascending and descending flavors — the DN
    // flavor launches with negative MJ inclination), or a plain
    // time grid for near-equatorial targets where the site is
    // always in plane.
    LOCAL candidates IS LIST().
    LOCAL etaAn IS _etaToLaunchPlane(TRUE, tgtLan, tgtInc).
    LOCAL etaDn IS _etaToLaunchPlane(FALSE, tgtLan, tgtInc).
    IF etaAn < 0 AND etaDn < 0 {
        LOCAL j IS 1.
        UNTIL j > maxWindows {
            candidates:ADD(LEXICON(
                "ut", TIME:SECONDS + 120 + j * ves:ORBIT:PERIOD / 6,
                "inc", tgtInc)).
            SET j TO j + 1.
        }
    } ELSE {
        FOR flavor IN LIST(LEXICON("eta", etaAn, "inc", tgtInc),
                           LEXICON("eta", etaDn, "inc", -tgtInc)) {
            IF flavor["eta"] >= 0 {
                LOCAL k IS 0.
                UNTIL k >= CEILING(maxWindows / 2) {
                    LOCAL windowUt IS TIME:SECONDS + flavor["eta"]
                        + k * rotPeriod - leadTime.
                    IF windowUt > TIME:SECONDS + 60 {
                        candidates:ADD(LEXICON(
                            "ut", windowUt, "inc", flavor["inc"])).
                    }
                    SET k TO k + 1.
                }
            }
        }
    }
    IF candidates:LENGTH = 0 {
        mLogError("PRELAUNCH: no launch windows — target plane never"
            + " passes over the launch site.").
        yieldToPrompt().
        RETURN.
    }

    // Score: along-track lead error at insertion, plus 2 deg/hour
    // so a marginally better window days away doesn't win.
    LOCAL best IS candidates[0].
    LOCAL bestScore IS 999999.
    FOR cand IN candidates {
        LOCAL lead IS _rdvLeadAngle(ves, cand["ut"] + ascentTime).
        LOCAL leadErr IS ABS(_norm180(lead - desiredLead)).
        LOCAL score IS leadErr + 2 * (cand["ut"] - TIME:SECONDS) / 3600.
        cand:ADD("lead", lead).
        IF score < bestScore { SET bestScore TO score. SET best TO cand. }
    }

    LOCAL launchUt IS best["ut"].
    cfgSet("LAUNCH_INCLINATION", best["inc"]).
    stateSetNum("mission_cfg_LAUNCH_INCLINATION", best["inc"]).
    stateSetNum("prelaunch_plane_ut", launchUt).
    mLog("PRELAUNCH: window in " + ROUND(launchUt - TIME:SECONDS, 0)
        + "s  launch inc=" + ROUND(best["inc"], 2)
        + "  target lead at insertion=" + ROUND(best["lead"], 1)
        + " deg (want " + ROUND(desiredLead, 1) + ").").
    mLogWarn("STATS prelaunch rdv setup target=" + ves:NAME
        + " inc=" + ROUND(best["inc"], 2)
        + " wait=" + ROUND(launchUt - TIME:SECONDS, 0)
        + " lead=" + ROUND(best["lead"], 1)).

    _waitForPrelaunchUt(launchUt).
    IF ABORT OR AG10 {
        mLog("PRELAUNCH hold — operator abort.").
        yieldToPrompt().
        RETURN.
    }
    mLog("PRELAUNCH complete; rendezvous window open.").
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phasePrelaunch {
    // Rendezvous missions: the window comes from the target vessel.
    LOCAL rdvName IS _prelaunchRdvTarget().
    IF rdvName <> "" {
        _prelaunchToVessel(rdvName).
        RETURN.
    }

    IF NOT CFG:HASKEY("CAPTURE_LAN") {
        mLog("PRELAUNCH: no CAPTURE_LAN configured; launching immediately.").
        nextPhase(launchSeq).
        RETURN.
    }

    LOCAL targetLan IS CFG["CAPTURE_LAN"].
    LOCAL targetInc IS _targetLaunchPlaneInc().
    LOCAL leadTime IS _launchCfgNum("PRELAUNCH_PLANE_LEAD", 145).
    IF leadTime < 0 { SET leadTime TO 0. }

    IF targetInc <= 0 OR targetInc >= 180 {
        mLog("PRELAUNCH: equatorial target; LAN is undefined, launching immediately.").
        nextPhase(launchSeq).
        RETURN.
    }

    IF NOT _latIncOk(SHIP:LATITUDE, targetInc) {
        mLogError("PRELAUNCH: target plane never passes over launch latitude.").
        PRINT " ".
        PRINT "  PRELAUNCH HOLD".
        PRINT "  Target inc " + ROUND(targetInc, 2) + " deg cannot pass over lat "
            + ROUND(SHIP:LATITUDE, 3) + " deg.".
        yieldToPrompt().
        RETURN.
    }

    LOCAL waitTime IS _planeLaunchWait(targetLan, targetInc, leadTime).
    IF waitTime < 0 {
        mLogError("PRELAUNCH: could not calculate launch-plane timing.").
        yieldToPrompt().
        RETURN.
    }

    LOCAL targetUt IS TIME:SECONDS + waitTime.
    stateSetNum("prelaunch_plane_ut", targetUt).
    mLog("PRELAUNCH: target LAN=" + ROUND(targetLan, 1)
        + " deg inc=" + ROUND(targetInc, 2)
        + " deg lead=" + ROUND(leadTime, 0)
        + "s wait=" + ROUND(waitTime, 0) + "s.").

    _waitForPrelaunchUt(targetUt).
    IF ABORT OR AG10 {
        mLog("PRELAUNCH hold — operator abort.").
        yieldToPrompt().
        RETURN.
    }

    mLog("PRELAUNCH complete; launch plane window open.").
    nextPhase(launchSeq).
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

    LOCAL parkingAlt IS _launchCfgNum("PARKING_ALT", 80000).
    LOCAL launchInc IS _launchCfgNum("LAUNCH_INCLINATION", 0).
    LOCAL launchAzimuth IS _launchCfgNum("LAUNCH_AZIMUTH", 0).

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
            _launchAbort().
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
    LOCAL fairingAlt IS _launchCfgNum("FAIRING_ALT", 72000).
    IF fairingAlt < 10000 {
        mLogWarn("Unsafe FAIRING_ALT=" + fairingAlt + "m; using 71500m.").
        SET fairingAlt TO 71500.
    }
    IF SHIP:ALTITUDE < fairingAlt {
        mLog("Waiting for fairing alt " + ROUND(fairingAlt/1000,0) + "km...").
        WAIT UNTIL SHIP:ALTITUDE >= fairingAlt OR ABORT.
    }
    IF ABORT { RETURN. }
    _deployFairing().
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseFair {
    phaseFairing().
}

GLOBAL FUNCTION phaseExtendAnts {
    LOCAL extendAlt IS _launchCfgNum("EXTEND_ALT", 73500).
    IF extendAlt < 10000 {
        mLogWarn("Unsafe EXTEND_ALT=" + extendAlt + "m; using 73000m.").
        SET extendAlt TO 73000.
    }
    IF SHIP:ALTITUDE < extendAlt {
        mLog("Waiting for deploy alt " + ROUND(extendAlt/1000,0) + "km...").
        WAIT UNTIL SHIP:ALTITUDE >= extendAlt OR ABORT.
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
            WAIT UNTIL SHIP:PERIAPSIS >= _launchCfgNum("PARKING_ALT", 80000) * 0.95.
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
// _launchAbort is the trigger: cut propulsion, fire the vessel's
// VAB Abort action group (escape motor / separation), and route
// the phase machine into ABORT. The ABORT phase below does the
// real work — chute verification, descent monitoring, archiving,
// operator card — and is reboot-safe (PHASE ABORT = launch, so a
// power cycle mid-descent resumes there).
//
// Setting ABORT ON also flips the condition every ascent-phase
// wait watches, so the main thread breaks out of its altitude
// wait even when the abort fired from the WHEN watcher.
LOCAL FUNCTION _launchAbort {
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
    LOCAL target IS _launchCfgNum("PARKING_ALT", 80000).
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

// ── Suborbital return arc (SUBORBIT_RETURN = 1) ──────────────
// "Very long arc in space, land where we started": fly JUST
// below orbital speed. After the MechJeb boost, keep burning
// prograde while the Trajectories impact prediction sweeps east
// around the globe; cut the engine when the predicted impact
// arrives back at the launch site, then trim the arc with small
// prograde/retrograde burns above the atmosphere. Knobs:
// SUBORBIT_RETURN_TOL (40km). NOT YET FLIGHT-PROVEN.

LOCAL FUNCTION _suborbitSiteGeo {
    LOCAL siteLat IS stateGetNum("launch_site_lat", 9999).
    LOCAL siteLng IS stateGetNum("launch_site_lng", 9999).
    IF siteLat <> 9999 { RETURN LATLNG(siteLat, siteLng). }
    IF CFG:HASKEY("LANDING_TARGET_LAT") AND CFG:HASKEY("LANDING_TARGET_LNG") {
        RETURN LATLNG(CFG["LANDING_TARGET_LAT"], CFG["LANDING_TARGET_LNG"]).
    }
    RETURN LATLNG(-0.0972, -74.5577).   // KSC pad
}

// Chord distance from the predicted impact to the site (same-time
// positions, so the chord is frame-safe). -1 = no impact.
LOCAL FUNCTION _suborbitImpactDist {
    PARAMETER siteGeo.
    IF NOT (ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT) { RETURN -1. }
    LOCAL impactGeo IS ADDONS:TR:IMPACTPOS.
    RETURN (LATLNG(impactGeo:LAT, impactGeo:LNG):POSITION
        - LATLNG(siteGeo:LAT, siteGeo:LNG):POSITION):MAG.
}

// Deliver a small dv on orbit prograde/retrograde, gently.
LOCAL FUNCTION _suborbitTrimBurn {
    PARAMETER dvMag.
    PARAMETER pro.
    LOCAL startVel IS SHIP:VELOCITY:ORBIT.
    IF pro { LOCK STEERING TO SHIP:PROGRADE. }
    ELSE { LOCK STEERING TO SHIP:RETROGRADE. }
    LOCAL alignDeadline IS TIME:SECONDS + 45.
    UNTIL VANG(SHIP:FACING:FOREVECTOR,
            (CHOOSE 1 IF pro ELSE -1) * SHIP:VELOCITY:ORBIT) < 5
            OR TIME:SECONDS > alignDeadline {
        WAIT 0.1.
    }
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL burnDeadline IS TIME:SECONDS + 60.
    UNTIL (SHIP:VELOCITY:ORBIT - startVel):MAG >= dvMag
            OR TIME:SECONDS > burnDeadline {
        LOCAL acc IS MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
        LOCAL remaining IS dvMag - (SHIP:VELOCITY:ORBIT - startVel):MAG.
        SET throttleCmd TO MIN(1, MAX(0.02, remaining / acc / 0.6)).
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
}

// Closed-loop trim: measure impact-to-site distance, burn a small
// step, re-measure, learn the sensitivity (m of impact motion per
// m/s), repeat. Self-correcting against Trajectories.
LOCAL FUNCTION _suborbitTrimArc {
    PARAMETER siteGeo.
    PARAMETER tol.
    LOCAL sens IS 30000.
    LOCAL iter IS 0.
    UNTIL iter >= 8 {
        SET iter TO iter + 1.
        WAIT 2.
        LOCAL d0 IS _suborbitImpactDist(siteGeo).
        LOCAL pro IS TRUE.
        LOCAL step IS 2.
        IF d0 < 0 {
            // No impact at all: we ended up orbital — pull Pe down.
            SET pro TO FALSE.
            SET step TO 5.
            mLog("Trim " + iter + ": no impact (orbital) — retro 5 m/s.").
        } ELSE {
            IF d0 <= tol {
                mLog("Trim done: impact " + ROUND(d0 / 1000, 0)
                    + "km from site (tol " + ROUND(tol / 1000, 0) + "km).").
                BREAK.
            }
            // Short (site east of impact) → prograde extends the arc.
            LOCAL alongErr IS _norm180(siteGeo:LNG - ADDONS:TR:IMPACTPOS:LNG).
            SET pro TO alongErr > 0.
            SET step TO MIN(10, MAX(0.5, d0 / sens)).
            mLog("Trim " + iter + ": impact " + ROUND(d0 / 1000, 0)
                + "km " + (CHOOSE "short" IF pro ELSE "long")
                + " — " + (CHOOSE "prograde " IF pro ELSE "retrograde ")
                + ROUND(step, 1) + " m/s.").
        }
        _suborbitTrimBurn(step, pro).
        WAIT 2.
        LOCAL d1 IS _suborbitImpactDist(siteGeo).
        IF d0 > 0 AND d1 > 0 AND ABS(d0 - d1) > 1000 {
            SET sens TO MAX(5000, ABS(d0 - d1) / step).
        }
    }
    UNLOCK STEERING.
    mLogWarn("STATS suborbit-return trim result dist="
        + ROUND(_suborbitImpactDist(siteGeo) / 1000, 1)
        + "km PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)).
}

LOCAL FUNCTION _suborbitReturnArc {
    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("SUBORBIT return mode needs Trajectories — holding.").
        yieldToPrompt().
        RETURN.
    }
    LOCAL siteGeo IS _suborbitSiteGeo().
    LOCAL tol IS _launchCfgNum("SUBORBIT_RETURN_TOL", 40000).
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.
    // MechJeb must NOT circularize — the sweep burn is ours.
    IF ADDONS:MJ:AVAILABLE {
        SET ADDONS:MJ:ASCENT:SKIPCIRCULARIZATION TO TRUE.
    }
    mLog("Return arc: target site " + ROUND(siteGeo:LAT, 3) + ","
        + ROUND(siteGeo:LNG, 3) + " tol " + ROUND(tol / 1000, 0) + "km.").

    // Ride the MechJeb boost, then take over above the atmosphere.
    WAIT UNTIL SHIP:ALTITUDE >= atmTop
        OR NOT (ADDONS:MJ:AVAILABLE AND ADDONS:MJ:ASCENT:ENABLED)
        OR ABORT OR AG10.
    IF ABORT OR AG10 { _launchAbort(). RETURN. }
    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }

    // Sweep burn: prograde until the predicted impact comes back
    // around to the site. Throttle steps down as it closes — the
    // sweep accelerates wildly near orbital speed.
    LOCK STEERING TO SHIP:PROGRADE.
    WAIT 3.
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL dMin IS 1e12.
    LOCAL cutReason IS "".
    UNTIL cutReason <> "" {
        IF ABORT OR AG10 { _launchAbort(). RETURN. }
        LOCAL d IS _suborbitImpactDist(siteGeo).
        IF d >= 0 {
            IF d < dMin { SET dMin TO d. }
            IF d < tol * 1.5 { SET cutReason TO "impact-at-site". }
            ELSE IF dMin < 800000 AND d > dMin + 150000 {
                SET cutReason TO "past-closest".
            }
            SET throttleCmd TO
                CHOOSE 0.05 IF d < 500000
                ELSE CHOOSE 0.2 IF d < 2000000 ELSE 1.
        } ELSE {
            SET cutReason TO "impact-lost-orbital".
        }
        IF SHIP:PERIAPSIS > 45000 { SET cutReason TO "pe-too-high". }
        WAIT 0.1.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    mLogWarn("STATS suborbit-return cutoff reason=" + cutReason
        + " dist=" + ROUND(MAX(-1, _suborbitImpactDist(siteGeo)) / 1000, 0)
        + "km ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)).

    _suborbitTrimArc(siteGeo, tol).
    SET SAS TO TRUE.
    mLog("Return arc set — riding it back to "
        + ROUND(siteGeo:LAT, 2) + "," + ROUND(siteGeo:LNG, 2) + ".").
    nextPhase(launchSeq).
}

// ── Suborbital cutoff ────────────────────────────────────────
// For crewed suborbital hops (SEQUENCE LAUNCH,SUBORBIT,DESCENT,
// DONE): lets the MechJeb ascent boost until apoapsis reaches
// PARKING_ALT, then kills the autopilot and coasts ballistic —
// no circularization, the ship falls back for a chute landing
// downrange. With SUBORBIT_RETURN = 1 it instead flies the
// round-the-world arc back to the launch site (above).
// Resume-safe: re-running just re-disables MechJeb.
GLOBAL FUNCTION phaseSuborbit {
    IF _launchCfgNum("SUBORBIT_RETURN", 0) > 0 {
        _suborbitReturnArc().
        RETURN.
    }
    LOCAL targetAp IS _launchCfgNum("PARKING_ALT", 80000).
    mLog("Suborbital: boosting to Ap " + ROUND(targetAp/1000, 0)
        + "km, then engine cutoff (no circularization).").

    IF SHIP:APOAPSIS < targetAp * 0.95 {
        WAIT UNTIL SHIP:APOAPSIS >= targetAp * 0.95
            OR NOT (ADDONS:MJ:AVAILABLE AND ADDONS:MJ:ASCENT:ENABLED)
            OR ABORT OR AG10.
    }
    IF ABORT OR AG10 {
        _launchAbort().
        RETURN.
    }

    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    mLogWarn("STATS suborbit cutoff ApKm=" + ROUND(SHIP:APOAPSIS/1000, 1)
        + " altKm=" + ROUND(SHIP:ALTITUDE/1000, 1)
        + " vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)).

    // Hold surface prograde for the rest of the climb out of the
    // atmosphere so the stack stays stable after cutoff.
    IF SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT
            AND SHIP:VERTICALSPEED > 0 {
        LOCK STEERING TO SHIP:SRFPROGRADE.
        WAIT UNTIL SHIP:ALTITUDE >= SHIP:BODY:ATM:HEIGHT
            OR SHIP:VERTICALSPEED < 0 OR ABORT.
        UNLOCK STEERING.
    }
    IF ABORT { RETURN. }
    SET SAS TO TRUE.
    mLog("Suborbital cutoff complete: Ap=" + ROUND(SHIP:APOAPSIS/1000, 1)
        + "km. Falling back for descent.").
    nextPhase(launchSeq).
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
