// ============================================================
// prelaunch.ks  —  Launch-window timing  (0:/lib/prelaunch.ks)
//
// PRELAUNCH phase: wait on the pad for a launch-plane window
// (CAPTURE_LAN) or a rendezvous window derived from a target
// vessel (RENDEZVOUS_TARGET / game target). Own lib so the
// LAUNCH band doesn't carry it for every rocket.
// ============================================================

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
