// ============================================================
// prelaunch.ks  —  Launch-window timing  (0:/lib/prelaunch.ks)
//
// PRELAUNCH phase: wait on the pad for a launch-plane window
// (CAPTURE_LAN) or a rendezvous window derived from a target
// vessel (RENDEZVOUS_TARGET / game target). Own lib so the
// LAUNCH band doesn't carry it for every rocket.
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL LAUNCH_PLANE_TARGET IS "".
GLOBAL LAUNCH_PLANE_MODE IS "".
GLOBAL LAUNCH_PLANE_LEAD IS 0.
GLOBAL PRELAUNCH_PLANE_LEAD IS 145.
GLOBAL LAUNCH_RDV_ASCENT_TIME IS 300.
GLOBAL LAUNCH_RDV_LEAD IS 30.
GLOBAL LAUNCH_RDV_MAX_WINDOWS IS 16.
GLOBAL PRELAUNCH_TRANSFER_LEAD IS 900.
GLOBAL PRELAUNCH_TRANSFER_PHASE_TOL IS 8.
GLOBAL RENDEZVOUS_TARGET IS "".
GLOBAL TARGET_INCLINATION IS -1.
GLOBAL CAPTURE_INC IS -1.
GLOBAL CAPTURE_LAN IS -1.

LOCAL FUNCTION _norm360 {
    PARAMETER angle.
    LOCAL result IS angle.
    UNTIL result >= 0 { SET result TO result + 360. }
    UNTIL result < 360 { SET result TO result - 360. }
    RETURN result.
}

LOCAL FUNCTION _targetLaunchPlaneInc {
    LOCAL inc IS LAUNCH_INCLINATION.
    IF TARGET_INCLINATION >= 0 {
        SET inc TO TARGET_INCLINATION.
    }
    IF CAPTURE_INC >= 0 {
        SET inc TO CAPTURE_INC.
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
    PARAMETER toleranceDeg IS 2.5. 

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
    
    // Fixed missing underscore on longitude_
    LOCAL nodeAngle IS _norm360(geoLng - longitude_).

    // Handle the wraparound if we just passed the window
    IF nodeAngle > (360 - toleranceDeg) {
        // Shift it to a negative angle representing how far past the window we are
        SET nodeAngle TO nodeAngle - 360.
    }

    // ETA will be negative if we are past the window but within tolerance
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

LOCAL FUNCTION _planeLaunchWindow {
    PARAMETER targetLan.
    PARAMETER targetInc.
    PARAMETER leadTime.

    LOCAL best IS 0.
    LOCAL bestWait IS -1.
    LOCAL period IS SHIP:BODY:ROTATIONPERIOD.
    LOCAL etaAn IS _etaToLaunchPlane(TRUE, targetLan, targetInc).
    LOCAL etaDn IS _etaToLaunchPlane(FALSE, targetLan, targetInc).

    FOR flavor IN LIST(
            LEXICON("eta", etaAn, "inc", targetInc, "node", "AN"),
            LEXICON("eta", etaDn, "inc", -targetInc, "node", "DN")) {
        IF flavor["eta"] >= 0 {
            LOCAL waitTime IS flavor["eta"] - leadTime.
            UNTIL waitTime >= 0 { SET waitTime TO waitTime + period. }
            IF bestWait < 0 OR waitTime < bestWait {
                SET bestWait TO waitTime.
                SET best TO LEXICON(
                    "wait", waitTime,
                    "ut", TIME:SECONDS + waitTime,
                    "inc", flavor["inc"],
                    "node", flavor["node"],
                    "eta", flavor["eta"]).
            }
        }
    }
    RETURN best.
}

LOCAL FUNCTION _bodyNamed {
    PARAMETER nm.
    LOCAL want IS nm:TOUPPER.
    LOCAL allBodies IS LIST().
    LIST BODIES IN allBodies.
    FOR bod_ IN allBodies {
        IF bod_:NAME:TOUPPER = want { RETURN bod_. }
    }
    RETURN 0.
}

LOCAL FUNCTION _launchPlaneTargetName {
    LOCAL nm IS "".
    IF LAUNCH_PLANE_TARGET <> "" {
        SET nm TO LAUNCH_PLANE_TARGET.
    } ELSE IF getTarget("") <> "" {
        SET nm TO getTarget("").
    } ELSE IF HASTARGET AND (TARGET:ISTYPE("Body") OR TARGET:ISTYPE("Vessel")) {
        SET nm TO TARGET:NAME.
    }
    RETURN nm.
}

LOCAL FUNCTION _prelaunchNextPhaseIs {
    PARAMETER phaseName.

    LOCAL current IS stateGet("phase", "PRELAUNCH").
    LOCAL i IS 0.
    UNTIL i >= launchSeq:LENGTH {
        IF launchSeq[i] = current {
            IF i + 1 >= launchSeq:LENGTH { RETURN FALSE. }
            RETURN launchSeq[i + 1] = phaseName.
        }
        SET i TO i + 1.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _prelaunchToSuborbital {
    mLog("PRELAUNCH: suborbital hop; launch-plane timing skipped.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _prelaunchToBodyOrbit {
    PARAMETER allowFallback.

    LOCAL tgtName IS _launchPlaneTargetName().
    IF tgtName = "" {
        mLogError("PRELAUNCH: LAUNCH_PLANE_MODE requested but no target found.").
        yieldToPrompt().
        RETURN.
    }

    LOCAL bod_ IS _bodyNamed(tgtName).
    IF NOT bod_:ISTYPE("Body") {
        mLogError("PRELAUNCH: launch-plane body '" + tgtName + "' not found.").
        yieldToPrompt().
        RETURN.
    }
    IF NOT bod_:HASBODY OR bod_:BODY:NAME <> SHIP:BODY:NAME {
        mLogError("PRELAUNCH: " + bod_:NAME + " does not orbit "
            + SHIP:BODY:NAME + "; cannot use its body-orbit plane from here.").
        yieldToPrompt().
        RETURN.
    }

    LOCAL targetInc IS bod_:ORBIT:INCLINATION.
    LOCAL targetLan IS bod_:ORBIT:LAN.
    LOCAL leadTime IS PRELAUNCH_PLANE_LEAD.
    IF LAUNCH_PLANE_LEAD > 0 {
        SET leadTime TO LAUNCH_PLANE_LEAD.
    }
    IF leadTime < 0 { SET leadTime TO 0. }

    IF targetInc <= 0 OR targetInc >= 180 {
        SET LAUNCH_INCLINATION TO targetInc.
        stateSet("mission_cfg_LAUNCH_INCLINATION", targetInc).
        mLog("PRELAUNCH: " + bod_:NAME
            + " plane is equatorial; launching immediately.").
        nextPhase(launchSeq).
        RETURN.
    }

    IF NOT _latIncOk(SHIP:LATITUDE, targetInc) {
        IF allowFallback {
            SET LAUNCH_INCLINATION TO 0.
            stateSet("mission_cfg_LAUNCH_INCLINATION", 0).
            mLogWarn("PRELAUNCH: " + bod_:NAME + " plane inc="
                + ROUND(targetInc, 2) + " cannot pass over lat "
                + ROUND(SHIP:LATITUDE, 3)
                + "; AUTO falling back to equatorial launch.").
            mLogWarn("STATS prelaunch body-plane fallback target=" + bod_:NAME
                + " inc=" + ROUND(targetInc, 2)
                + " lat=" + ROUND(SHIP:LATITUDE, 3)).
            nextPhase(launchSeq).
            RETURN.
        }
        mLogError("PRELAUNCH: target plane never passes over launch latitude.").
        PRINT " ".
        PRINT "  PRELAUNCH HOLD".
        PRINT "  " + bod_:NAME + " inc " + ROUND(targetInc, 2)
            + " deg cannot pass over lat " + ROUND(SHIP:LATITUDE, 3) + " deg.".
        yieldToPrompt().
        RETURN.
    }

    LOCAL win IS _planeLaunchWindow(targetLan, targetInc, leadTime).
    IF win = 0 {
        mLogError("PRELAUNCH: could not calculate body-plane timing.").
        yieldToPrompt().
        RETURN.
    }

    SET LAUNCH_INCLINATION TO win["inc"].
    stateSet("mission_cfg_LAUNCH_INCLINATION", win["inc"]).
    stateSet("prelaunch_plane_ut", win["ut"]).
    stateSet("prelaunch_plane_target", bod_:NAME).
    stateSet("prelaunch_plane_inc", targetInc).
    stateSet("prelaunch_plane_lan", targetLan).

    mLog("PRELAUNCH: " + bod_:NAME + " body plane "
        + win["node"] + " window in " + ROUND(win["wait"], 0)
        + "s  inc=" + ROUND(targetInc, 2)
        + " LAN=" + ROUND(targetLan, 1)
        + " launchInc=" + ROUND(win["inc"], 2)
        + " lead=" + ROUND(leadTime, 0) + "s.").
    mLogWarn("STATS prelaunch body-plane setup target=" + bod_:NAME
        + " node=" + win["node"]
        + " inc=" + ROUND(targetInc, 2)
        + " lan=" + ROUND(targetLan, 2)
        + " launchInc=" + ROUND(win["inc"], 2)
        + " wait=" + ROUND(win["wait"], 0)
        + " lead=" + ROUND(leadTime, 0)).

    _waitForPrelaunchUt(win["ut"]).
    IF ABORT {
        mLog("PRELAUNCH hold — operator abort.").
        yieldToPrompt().
        RETURN.
    }
    mLog("PRELAUNCH complete; body-plane launch window open.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _waitForPrelaunchUt {
    PARAMETER targetUt.

    LOCAL kacAlarmId IS "".
    LOCAL alarmUt IS targetUt - 30.
    IF alarmUt > TIME:SECONDS {
        SET kacAlarmId TO kacEnsureAlarm("Prelaunch window: " + SHIP:NAME,
            alarmUt,
            "Auto-created by PRELAUNCH. Fly safe.").
        IF kacAlarmId <> "" {
            mLog("KAC alarm set for prelaunch window in "
                + ROUND(alarmUt - TIME:SECONDS, 0) + "s.").
        }
    }

    mLog("PRELAUNCH waiting for launch window. Operator may warp.").
    UNTIL TIME:SECONDS >= targetUt OR ABORT {
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
// ahead. Knobs: LAUNCH_RDV_ASCENT_TIME (300s pad-to-orbit
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

LOCAL FUNCTION _signedPhaseAngle {
    PARAMETER fromVec.
    PARAMETER toVec.
    PARAMETER normalVec.
    LOCAL angle IS VANG(fromVec, toVec).
    IF VDOT(VCRS(fromVec, toVec), normalVec) < 0 {
        SET angle TO -angle.
    }
    RETURN _norm360(angle).
}

LOCAL FUNCTION _interplanetaryTargetSpec {
    LOCAL tgtName IS _launchPlaneTargetName().
    IF tgtName = "" { RETURN 0. }
    LOCAL bod_ IS _bodyNamed(tgtName).
    IF bod_:ISTYPE("Body") {
        RETURN LEXICON(
            "FOUND", TRUE,
            "KIND", "BODY",
            "NAME", bod_:NAME,
            "OBJECT", bod_,
            "XING_BODY", bod_
        ).
    }
    RETURN 0.
}

LOCAL FUNCTION _isInterplanetaryBodyTarget {
    PARAMETER bod_.
    IF NOT bod_:ISTYPE("Body") { RETURN FALSE. }
    IF NOT SHIP:BODY:HASBODY { RETURN FALSE. }
    IF bod_ = SHIP:BODY:BODY { RETURN TRUE. }
    IF NOT bod_:HASBODY { RETURN FALSE. }
    RETURN bod_:BODY = SHIP:BODY:BODY
        AND bod_ <> SHIP:BODY.
}

LOCAL FUNCTION _objectPhaseAt {
    PARAMETER targetObj.
    PARAMETER centralBody.
    PARAMETER ut.
    LOCAL originVec IS POSITIONAT(SHIP:BODY, ut)
        - POSITIONAT(centralBody, ut).
    LOCAL targetVec IS POSITIONAT(targetObj, ut)
        - POSITIONAT(centralBody, ut).
    LOCAL originNext IS POSITIONAT(SHIP:BODY, ut + 60)
        - POSITIONAT(centralBody, ut + 60).
    LOCAL normalVec IS VCRS(originVec, originNext - originVec):NORMALIZED.
    RETURN _signedPhaseAngle(originVec, targetVec, normalVec).
}

LOCAL FUNCTION _hohmannPhaseForOrbit {
    PARAMETER targetOrbit.
    LOCAL centralBody IS SHIP:BODY:BODY.
    LOCAL originOrbit IS SHIP:BODY:ORBIT.
    LOCAL xferA IS (originOrbit:SEMIMAJORAXIS
        + targetOrbit:SEMIMAJORAXIS) / 2.
    LOCAL tof IS CONSTANT:PI * SQRT(xferA ^ 3 / centralBody:MU).
    LOCAL targetMotion IS 360 * tof / targetOrbit:PERIOD.
    RETURN _norm360(180 - targetMotion).
}

LOCAL FUNCTION _interplanetaryLaunchIncFor {
    PARAMETER targetName.
    PARAMETER targetOrbit.
    LOCAL inc IS targetOrbit:INCLINATION.
    IF inc <= 0 OR inc >= 180 { RETURN 0. }
    IF _latIncOk(SHIP:LATITUDE, inc) { RETURN inc. }
    mLogWarn("PRELAUNCH: " + targetName + " solar plane inc="
        + ROUND(inc, 2) + " cannot pass over lat "
        + ROUND(SHIP:LATITUDE, 3)
        + "; using equatorial parking orbit.").
    RETURN 0.
}

LOCAL FUNCTION _prelaunchToInterplanetary {
    PARAMETER targetSpec.

    IF targetSpec = 0 OR NOT targetSpec:HASKEY("FOUND") {
        mLogError("PRELAUNCH: interplanetary mode requested but no target found.").
        yieldToPrompt().
        RETURN.
    }

    LOCAL targetObj IS targetSpec["OBJECT"].
    LOCAL targetName IS targetSpec["NAME"].
    LOCAL xingBody IS targetSpec["XING_BODY"].

    IF NOT _isInterplanetaryBodyTarget(xingBody) {
        mLogError("PRELAUNCH: interplanetary mode needs a body around "
            + SHIP:BODY:BODY:NAME + "; target is not supported.").
        yieldToPrompt().
        RETURN.
    }

    LOCAL launchInc IS _interplanetaryLaunchIncFor(
        targetName, targetObj:ORBIT).
    SET LAUNCH_INCLINATION TO launchInc.
    stateSet("mission_cfg_LAUNCH_INCLINATION", launchInc).

    IF xingBody = SHIP:BODY:BODY {
        mLog("PRELAUNCH: solar escape target; launching immediately"
            + " inc=" + ROUND(launchInc, 2) + ".").
        nextPhase(launchSeq).
        RETURN.
    }

    LOCAL originOrbit IS SHIP:BODY:ORBIT.
    LOCAL targetOrbit IS targetObj:ORBIT.
    LOCAL desiredPhase IS _hohmannPhaseForOrbit(targetOrbit).
    LOCAL leadTime IS MAX(0, PRELAUNCH_TRANSFER_LEAD).
    LOCAL phaseTol IS MAX(0.1, PRELAUNCH_TRANSFER_PHASE_TOL).
    LOCAL immediateDepartUt IS TIME:SECONDS + leadTime.
    LOCAL phaseAtImmediate IS _objectPhaseAt(
        targetObj, SHIP:BODY:BODY, immediateDepartUt).
    LOCAL immediateErr IS ABS(_norm180(phaseAtImmediate - desiredPhase)).

    IF immediateErr <= phaseTol {
        mLog("PRELAUNCH: already in " + targetName
            + " transfer window; launch now. phase="
            + ROUND(phaseAtImmediate, 1)
            + "/" + ROUND(desiredPhase, 1)
            + " err=" + ROUND(immediateErr, 1)
            + " inc=" + ROUND(launchInc, 2) + ".").
        mLogWarn("STATS prelaunch transfer target=" + targetName
            + " xingTarget=" + xingBody:NAME
            + " wait=0"
            + " phase=" + ROUND(phaseAtImmediate, 2)
            + " desired=" + ROUND(desiredPhase, 2)
            + " err=" + ROUND(immediateErr, 2)
            + " launchInc=" + ROUND(launchInc, 2)).
        nextPhase(launchSeq).
        RETURN.
    }

    LOCAL phaseNow IS _objectPhaseAt(targetObj, SHIP:BODY:BODY, TIME:SECONDS).
    LOCAL originRate IS 360 / originOrbit:PERIOD.
    LOCAL targetRate IS 360 / targetOrbit:PERIOD.
    LOCAL relRate IS targetRate - originRate.
    IF ABS(relRate) < 0.0000001 {
        mLogError("PRELAUNCH: cannot compute transfer window; relative"
            + " solar motion is too small.").
        yieldToPrompt().
        RETURN.
    }

    LOCAL phaseDelta IS 0.
    IF relRate > 0 {
        SET phaseDelta TO _norm360(desiredPhase - phaseNow).
    } ELSE {
        SET phaseDelta TO _norm360(phaseNow - desiredPhase).
    }
    LOCAL departWait IS phaseDelta / ABS(relRate).
    LOCAL synodic IS 360 / ABS(relRate).
    UNTIL TIME:SECONDS + departWait >= immediateDepartUt {
        SET departWait TO departWait + synodic.
    }

    LOCAL departUt IS TIME:SECONDS + departWait.
    LOCAL launchUt IS departUt - leadTime.
    IF launchUt < TIME:SECONDS { SET launchUt TO TIME:SECONDS. }

    stateSet("prelaunch_plane_ut", launchUt).

    mLog("PRELAUNCH: " + targetName + " transfer window in "
        + ROUND(launchUt - TIME:SECONDS, 0)
        + "s  depart in " + ROUND(departUt - TIME:SECONDS, 0)
        + "s phase=" + ROUND(phaseNow, 1)
        + "/" + ROUND(desiredPhase, 1)
        + " inc=" + ROUND(launchInc, 2)
        + " xingTarget=" + xingBody:NAME
        + " lead=" + ROUND(leadTime, 0) + "s.").
    mLogWarn("STATS prelaunch transfer target=" + targetName
        + " xingTarget=" + xingBody:NAME
        + " wait=" + ROUND(launchUt - TIME:SECONDS, 0)
        + " departWait=" + ROUND(departUt - TIME:SECONDS, 0)
        + " phase=" + ROUND(phaseNow, 2)
        + " desired=" + ROUND(desiredPhase, 2)
        + " launchInc=" + ROUND(launchInc, 2)
        + " lead=" + ROUND(leadTime, 0)).

    _waitForPrelaunchUt(launchUt).
    IF ABORT {
        mLog("PRELAUNCH hold — operator abort.").
        yieldToPrompt().
        RETURN.
    }
    mLog("PRELAUNCH complete; interplanetary transfer window open.").
    nextPhase(launchSeq).
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
    IF RENDEZVOUS_TARGET <> "" {
        RETURN RENDEZVOUS_TARGET.
    }
    IF CAPTURE_LAN < 0 AND HASTARGET
            AND TARGET:ISTYPE("Vessel") {
        LOCAL nm IS TARGET:NAME.
        SET RENDEZVOUS_TARGET TO nm.
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
    LOCAL ascentTime IS LAUNCH_RDV_ASCENT_TIME.
    LOCAL desiredLead IS LAUNCH_RDV_LEAD.
    LOCAL maxWindows IS LAUNCH_RDV_MAX_WINDOWS.
    LOCAL leadTime IS PRELAUNCH_PLANE_LEAD.
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
    SET LAUNCH_INCLINATION TO best["inc"].
    stateSet("mission_cfg_LAUNCH_INCLINATION", best["inc"]).
    stateSet("prelaunch_plane_ut", launchUt).
    mLog("PRELAUNCH: window in " + ROUND(launchUt - TIME:SECONDS, 0)
        + "s  launch inc=" + ROUND(best["inc"], 2)
        + "  target lead at insertion=" + ROUND(best["lead"], 1)
        + " deg (want " + ROUND(desiredLead, 1) + ").").
    mLogWarn("STATS prelaunch rdv setup target=" + ves:NAME
        + " inc=" + ROUND(best["inc"], 2)
        + " wait=" + ROUND(launchUt - TIME:SECONDS, 0)
        + " lead=" + ROUND(best["lead"], 1)).

    _waitForPrelaunchUt(launchUt).
    IF ABORT {
        mLog("PRELAUNCH hold — operator abort.").
        yieldToPrompt().
        RETURN.
    }
    mLog("PRELAUNCH complete; rendezvous window open.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _prelaunchPrintConfig {
    flightPlanTitle("PRELAUNCH", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("MISSION").
    flightPlanRow("BAND", phaseBand()).
    flightPlanRow("TARGET", getTarget()).
    IF PAYLOADS:LENGTH > 0 {
        flightPlanRow("PAYLOADS", PAYLOADS).
    }
    flightPlanConfig().
    flightPlanSection("SEQUENCE").
    flightPlanSequence(launchSeq).
}

LOCAL FUNCTION _prelaunchClearPlanState {
    FOR key IN LIST(
        "prelaunch_plane_ut", "prelaunch_plane_target",
        "prelaunch_plane_inc", "prelaunch_plane_lan"
    ) {
        stateRemove(key).
    }
}

GLOBAL FUNCTION confirmLaunch {
    IF stateGet("phase", "") <> "PRELAUNCH" {
        RETURN TRUE.
    }

    _prelaunchPrintConfig().
    uiPrompt("SPACE to arm / ESC to hold / 30s auto-arm").
    uiPrompt("Edit globals in terminal to override").
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
        PRINT "  [==============================] HOLD     " AT (0, TERMINAL:HEIGHT - 1).
        mLog("Prelaunch held by operator.").
        RETURN FALSE.
    }
    PRINT "  [==============================] ARMED    " AT (0, TERMINAL:HEIGHT - 1).
    RETURN TRUE.
}

GLOBAL FUNCTION phasePrelaunch {
    IF NOT confirmLaunch() {
        yieldToPrompt().
        RETURN.
    }
    _prelaunchClearPlanState().

    LOCAL planeMode IS "".
    IF LAUNCH_PLANE_MODE <> "" {
        SET planeMode TO LAUNCH_PLANE_MODE:TOUPPER.
    }
    IF planeMode = "SUBORBITAL" OR _prelaunchNextPhaseIs("HOP") {
        _prelaunchToSuborbital().
        RETURN.
    }
    IF planeMode = "INTERPLANETARY" {
        _prelaunchToInterplanetary(_interplanetaryTargetSpec()).
        RETURN.
    }
    IF planeMode = "AUTO" {
        LOCAL autoSpec IS _interplanetaryTargetSpec().
        IF autoSpec <> 0
                AND _isInterplanetaryBodyTarget(autoSpec["XING_BODY"]) {
            _prelaunchToInterplanetary(autoSpec).
        } ELSE {
            _prelaunchToBodyOrbit(TRUE).
        }
        RETURN.
    }
    IF planeMode = "BODY_ORBIT" {
        _prelaunchToBodyOrbit(planeMode = "AUTO").
        RETURN.
    }

    // Rendezvous missions: the window comes from the target vessel.
    LOCAL rdvName IS _prelaunchRdvTarget().
    IF rdvName <> "" {
        _prelaunchToVessel(rdvName).
        RETURN.
    }

    IF CAPTURE_LAN < 0 {
        mLog("PRELAUNCH: no CAPTURE_LAN configured; launching immediately.").
        nextPhase(launchSeq).
        RETURN.
    }

    LOCAL targetLan IS CAPTURE_LAN.
    LOCAL targetInc IS _targetLaunchPlaneInc().
    LOCAL leadTime IS PRELAUNCH_PLANE_LEAD.
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
    stateSet("prelaunch_plane_ut", targetUt).
    mLog("PRELAUNCH: target LAN=" + ROUND(targetLan, 1)
        + " deg inc=" + ROUND(targetInc, 2)
        + " deg lead=" + ROUND(leadTime, 0)
        + "s wait=" + ROUND(waitTime, 0) + "s.").

    _waitForPrelaunchUt(targetUt).
    IF ABORT {
        mLog("PRELAUNCH hold — operator abort.").
        yieldToPrompt().
        RETURN.
    }

    mLog("PRELAUNCH complete; launch plane window open.").
    nextPhase(launchSeq).
}
