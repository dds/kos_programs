// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

@LAZYGLOBAL OFF.

LOCAL COMPLETE_FRAC        IS 0.001.
LOCAL ABS_CUTOFF           IS 0.0001.
LOCAL ALIGN_TOLERANCE      IS 2.0.
LOCAL HIBERNATE_THRESHOLD  IS 300.
LOCAL HIBERNATE_WAKE_LEAD  IS 180.

GLOBAL FUNCTION executeManeuver {
    WAIT 0.1.
    IF NOT HASNODE {
        mLogError("executeManeuver: no node on flight plan.").
        HUDTEXT("ERROR: No maneuver node!", 5, 2, 18, RED, FALSE).
        RETURN FALSE.
    }

    LOCAL nd    IS NEXTNODE.
    LOCAL burnDV  IS nd:DELTAV:MAG.
    LOCAL startTime IS _calcStartTime(nd).
    _wakeCmd().
    _markPendingBurn(nd, burnDV, startTime).

    IF burnDV < 10 { _setThrustLimit(0.25). }
    IF burnDV < 2  { _setThrustLimit(0.10). }
    IF burnDV < 0.5 { _setThrustLimit(0.05). }

    IF startTime < TIME:SECONDS {
        mLogWarn("Burn window already passed by " + ROUND(TIME:SECONDS - startTime, 0) + "s — removing node.").
        HUDTEXT("Burn window missed — replanning", 5, 2, 15, YELLOW, FALSE).
        REMOVE nd.
        _clearPendingBurn("missed-window").
        RETURN FALSE.
    }

    // Pre-burn brief card + orbit diagram (lib/orbit_draw.ks).
    IF DEFINED ORBIT_DRAW_READY {
        maneuverBrief(nd, stateGet("phase", "MANEUVER")).
    }

    mLog("Maneuver: dV=" + ROUND(burnDV,1) + " m/s  ETA=" + ROUND(startTime - TIME:SECONDS,1) + "s").
    mLogWarn("STATS burn setup dv=" + ROUND(burnDV,1)
        + " eta=" + ROUND(startTime - TIME:SECONDS,1)
        + " nodeEta=" + ROUND(nd:ETA,1)
        + " body=" + SHIP:BODY:NAME
        + " maxAcc=" + ROUND(_safeMaxAcc(),2)).
    IF _safeMaxAcc() <= 0 {
        mLogWarn("STATS burn thrust status=no-thrust maxThrust="
            + ROUND(SHIP:MAXTHRUST,1)
            + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).
    }

    // Set a KAC alarm to kill warp before the burn starts.
    // Alarm fires 60s before burn start to allow alignment time.
    LOCAL kacAlarmId IS "".
    IF ADDONS:KAC:AVAILABLE {
        LOCAL alarmUt IS startTime - 60.
        IF alarmUt > TIME:SECONDS {
            LOCAL alm IS ADDALARM("Raw", alarmUt, "Burn: " + ROUND(burnDV,1) + "m/s", "Auto-created by executeManeuver").
            SET alm:ACTION TO "KillWarp".
            SET kacAlarmId TO alm:ID.
            mLog("KAC alarm set for burn in " + ROUND(alarmUt - TIME:SECONDS, 0) + "s.").
        }
    }

    SET SAS TO FALSE.
    WAIT 0.1.
    LOCK STEERING TO nd:BURNVECTOR.
    mLog("Aligning to burn vector...").

    LOCAL wakeTime IS startTime - HIBERNATE_WAKE_LEAD.
    IF TIME:SECONDS < wakeTime - HIBERNATE_THRESHOLD {
        mLog("Long coast wait (" + ROUND(wakeTime - TIME:SECONDS, 0) + "s).").
        HUDTEXT("Coasting. Burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, CYAN, FALSE).
        WAIT MAX(0, wakeTime - TIME:SECONDS).
        _wakeCmd().
        SET WARP TO 0.
        SET SAS TO FALSE.
        WAIT 0.1.
        LOCK STEERING TO nd:BURNVECTOR.
        mLog("Awake — " + ROUND(startTime - TIME:SECONDS, 0) + "s to burn.").
        mLog("Re-aligning to burn vector after hibernation.").
        HUDTEXT("Core awake — burn in " + ROUND(startTime - TIME:SECONDS, 0) + "s", 5, 2, 13, GREEN, FALSE).
    }

    WAIT UNTIL TIME:SECONDS >= startTime - 60.
    mLog("Burn in T-60").

    LOCAL alignDeadline IS startTime - 5.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ALIGN_TOLERANCE
            OR TIME:SECONDS >= alignDeadline {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }

    LOCAL alignErr IS VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR).
    mLogWarn("STATS burn align angle=" + ROUND(alignErr,1)
        + " tol=" + ALIGN_TOLERANCE
        + " timeToBurn=" + ROUND(startTime - TIME:SECONDS,1)).
    IF alignErr >= ALIGN_TOLERANCE {
        mLogWarn("Burn starting with " + ROUND(alignErr,1) + "° misalignment.").
    } ELSE {
        mLog("Aligned. Waiting for burn window...").
    }

    WAIT UNTIL TIME:SECONDS >= alignDeadline.
    HUDTEXT("Burn in T-4", 3, 2, 15, WHITE, FALSE).
    countdown(4).

    WAIT UNTIL TIME:SECONDS >= startTime.
    mLog("Burn start. dV=" + ROUND(burnDV,1) + " m/s").
    LOCAL burnStartClock IS TIME:SECONDS.

    LOCAL origBurnVec IS nd:BURNVECTOR.

    UNTIL _isComplete(nd, burnDV) {
        LOCK STEERING TO nd:BURNVECTOR.

        IF _needsStage() {
            HUDTEXT("Staging!", 2, 2, 15, YELLOW, FALSE).
            mLog("Auto-stage triggered.").
            LOCK THROTTLE TO 0.
            WAIT 0.3.
            STAGE.
            WAIT 0.7.
        }

        LOCAL remaining IS nd:DELTAV:MAG.
        LOCAL maxAcc    IS _safeMaxAcc().
        LOCAL dotCheck IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).

        IF dotCheck < 0 { LOCK THROTTLE TO 0. BREAK. }

        IF remaining > 5.0 {
            LOCK THROTTLE TO 1.0.
        } ELSE IF remaining > 0.5 {
            LOCAL timeToStop IS remaining / maxAcc.
            LOCK THROTTLE TO MAX(0.02, MIN(0.5, timeToStop)).
        } ELSE IF remaining >= 0.04 {
            LOCK THROTTLE TO 0.01.
        } ELSE {
            LOCK THROTTLE TO 0.
            BREAK.
        }
        WAIT 0.01.
    }

    LOCAL residual IS nd:DELTAV:MAG.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    REMOVE nd.
    SET SAS TO TRUE.
    _setThrustLimit(1.0).
    _clearPendingBurn("complete").

    // Clean up the KAC alarm now that the burn is done.
    IF kacAlarmId <> "" {
        DELETEALARM(kacAlarmId).
    }

    mLog("Burn complete. Residual dV ~" + ROUND(residual, 2) + " m/s.").
    mLogWarn("STATS burn result dv=" + ROUND(burnDV,1)
        + " residual=" + ROUND(residual,2)
        + " duration=" + ROUND(TIME:SECONDS - burnStartClock,1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
    HUDTEXT("Burn complete", 3, 2, 15, GREEN, FALSE).
    RETURN TRUE.
}

GLOBAL FUNCTION archivePlannedManeuverLog {
    PARAMETER label IS "maneuver".
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Planned maneuver log archived: " + label + ".").
    } ELSE {
        mLog("Planned maneuver log archive skipped: no KSC link (" + label + ").").
    }
}

LOCAL FUNCTION _setThrustLimit {
    PARAMETER pct.
    FOR eng IN SHIP:ENGINES {
        SET eng:THRUSTLIMIT TO pct * 100.
    }
}

GLOBAL FUNCTION planCircularize {
    LOCAL etaApo IS ETA:APOAPSIS.
    LOCAL mu  IS SHIP:ORBIT:BODY:MU.
    LOCAL vCirc IS SQRT(mu / (SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS)).
    LOCAL vNow  IS VELOCITYAT(SHIP, TIME:SECONDS + etaApo):ORBIT:MAG.
    LOCAL dv    IS vCirc - vNow.

    LOCAL nd IS NODE(TIME:SECONDS + etaApo, 0, 0, dv).
    ADD nd.
    mLog("Circularize node: dV=" + ROUND(dv,1) + " m/s at Ap in " + ROUND(etaApo,0) + "s").
    mLogWarn("STATS circularize plan dv=" + ROUND(dv,1)
        + " eta=" + ROUND(etaApo,0)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    archivePlannedManeuverLog("circularize").
    RETURN nd.
}

GLOBAL FUNCTION planCapture {
    PARAMETER targetBody.
    PARAMETER targetAlt.
    LOCAL mu    IS targetBody:MU.
    LOCAL rPe   IS targetBody:RADIUS + SHIP:PERIAPSIS.
    LOCAL rAp   IS targetBody:RADIUS + targetAlt.
    LOCAL tSMA  IS (rPe + rAp) / 2.
    LOCAL vCapture IS SQRT(mu * (2/rPe - 1/tSMA)).
    LOCAL vAtPe    IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:PERIAPSIS):ORBIT:MAG.
    LOCAL dv       IS vCapture - vAtPe.
    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Capture node: dV=" + ROUND(dv,1)
        + " m/s at Pe in " + ROUND(ETA:PERIAPSIS,0)
        + "s  targetAp=" + ROUND(targetAlt/1000,1) + "km").
    mLogWarn("STATS capture plan target=" + targetBody:NAME
        + " dv=" + ROUND(dv,1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " targetApKm=" + ROUND(targetAlt/1000,1)
        + " etaPe=" + ROUND(ETA:PERIAPSIS,0)).
    archivePlannedManeuverLog("capture").
    RETURN nd.
}

GLOBAL FUNCTION planRaisePeNow {
    PARAMETER targetPe.
    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL rNow IS SHIP:ORBIT:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL rPe  IS SHIP:ORBIT:BODY:RADIUS + targetPe.
    LOCAL vNow IS SHIP:VELOCITY:ORBIT:MAG.
    LOCAL tSMA IS (rNow + rPe) / 2.
    LOCAL vNew IS SQRT(mu * (2/rNow - 1/tSMA)).
    LOCAL dv   IS vNew - vNow.
    LOCAL lead IS 60.
    IF ABS(dv) > 100 { SET lead TO 90. }
    IF ABS(dv) > 300 { SET lead TO 120. }
    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, dv).
    ADD nd.
    mLog("Raise Pe node: dV=" + ROUND(dv,1)
        + " m/s  targetPe=" + ROUND(targetPe/1000,1) + "km").
    mLogWarn("STATS raise-pe plan dv=" + ROUND(dv,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    archivePlannedManeuverLog("raise-pe").
    RETURN nd.
}

GLOBAL FUNCTION planLowerPe {
    PARAMETER targetPe.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL rBurn IS bodyR + SHIP:APOAPSIS.
    LOCAL rTarget IS bodyR + targetPe.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
    ADD nd.
    mLog("Lower Pe node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPe=" + ROUND(targetPe/1000,1) + "km").
    mLogWarn("STATS lower-pe plan dv=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " etaAp=" + ROUND(ETA:APOAPSIS,0)).
    archivePlannedManeuverLog("lower-pe").
    RETURN nd.
}

GLOBAL FUNCTION planAoPChange {
    PARAMETER targetAoP.
    LOCAL currentAoP IS SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    LOCAL deltaAoP IS targetAoP - currentAoP.
    IF deltaAoP > 180  { SET deltaAoP TO deltaAoP - 360. }
    IF deltaAoP < -180 { SET deltaAoP TO deltaAoP + 360. }
    IF ABS(deltaAoP) < 2 { RETURN 0. }
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL a  IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL e  IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL h  IS SQRT(mu * a * (1 - e^2)).
    LOCAL dvMag IS 2 * (mu / h) * e * SIN(ABS(deltaAoP) / 2).
    LOCAL ta1 IS deltaAoP / 2.
    LOCAL ta2 IS ta1 + 180.
    LOCAL eta1 IS etaToTrueAnomaly(ta1).
    LOCAL eta2 IS etaToTrueAnomaly(ta2).
    LOCAL burnETA IS eta1.
    LOCAL dvSign IS -1.
    IF eta2 < eta1 {
        SET burnETA TO eta2.
        SET dvSign TO 1.
    }
    LOCAL dvRadial IS dvSign * dvMag.
    LOCAL burnUT IS TIME:SECONDS + burnETA.
    LOCAL nd IS NODE(burnUT, dvRadial, 0, 0).
    ADD nd.
    mLog("AoP node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s  targetAoP=" + ROUND(targetAoP,1)
        + " ETA=" + ROUND(burnETA,0) + "s").
    archivePlannedManeuverLog("aop").
    RETURN nd.
}

LOCAL FUNCTION _calcStartTime {
    PARAMETER nd.
    LOCAL halfBurn IS 0.
    IF ADDONS:KE:AVAILABLE {
        SET halfBurn TO ADDONS:KE:NODEHALFBURNTIME.
    } ELSE {
        SET halfBurn TO nd:BURNTIME / 2.
    }
    LOCAL lead IS MIN(2.0, halfBurn * 0.02).
    RETURN nd:TIME - halfBurn - lead.
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _isComplete {
    PARAMETER nd, origDV.
    LOCAL remaining IS nd:DELTAV:MAG.
    LOCAL threshold IS MAX(ABS_CUTOFF, origDV * COMPLETE_FRAC).
    LOCAL dotCheck IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).
    IF remaining < 1.0 {
        RETURN remaining < threshold OR dotCheck < COS(ALIGN_TOLERANCE).
    }
    RETURN remaining < threshold OR dotCheck < 0.
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _findCmdModule {
    IF CORE:PART:HASMODULE("ModuleCommand") {
        RETURN CORE:PART:GETMODULE("ModuleCommand").
    }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleCommand") {
            RETURN p:GETMODULE("ModuleCommand").
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _markPendingBurn {
    PARAMETER nd.
    PARAMETER burnDV.
    PARAMETER startTime.
    stateSet("burn_pending", "true").
    stateSet("burn_phase", stateGet("phase", "")).
    stateSetNum("burn_node_time", nd:TIME).
    stateSetNum("burn_start_time", startTime).
    stateSetNum("burn_dv", burnDV).
}

LOCAL FUNCTION _clearPendingBurn {
    PARAMETER reason.
    IF stateGet("burn_pending", "") = "true" {
        mLog("Clearing pending burn state: " + reason + ".").
    }
    FOR key IN LIST(
        "burn_pending", "burn_phase", "burn_node_time",
        "burn_start_time", "burn_dv"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _wakeCmd {
    LOCAL cm IS _findCmdModule().
    IF cm = 0 { RETURN. }
    IF cm:HASFIELD("hibernation") { cm:SETFIELD("hibernation", FALSE). }
}
