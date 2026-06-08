// ============================================================
// payload_landing.ks — Minimal landing payload phases
// (0:/lib/payload_landing.ks)
// ============================================================

GLOBAL FUNCTION phaseLandDeorbit {
    IF DEFINED fr3ApplyMissionProfile { fr3ApplyMissionProfile(). }
    mLogWarn("STATS land-deorbit phase setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " targetPeKm=" + ROUND(_landingDeorbitPe()/1000,1)).
    IF SHIP:STATUS = "SUB_ORBITAL"
            AND (CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH")
                AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0) {
        mLogWarn("STATS land-deorbit phase skip status=already-suborbital mode=sim").
        nextPhase(fr3Seq).
        RETURN.
    }
    IF SHIP:STATUS = "SUB_ORBITAL" AND landingImpactAcceptableForAssist() {
        mLogWarn("STATS land-deorbit phase skip status=already-suborbital").
        nextPhase(fr3Seq).
        RETURN.
    }
    IF CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH") AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0 {
        IF _timedLandingDeorbit() {
            nextPhase(fr3Seq).
        }
        RETURN.
    }
    IF NOT _confirmLandingTarget() { RETURN. }
    LOCAL deorbitOk IS landingTargetedDeorbit().
    mLogWarn("STATS land-deorbit phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " status=" + SHIP:STATUS
        + " ok=" + deorbitOk).
    IF NOT deorbitOk {
        mLogError("Landing deorbit did not meet target tolerance; holding for manual review.").
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING DEORBIT FAILED TARGET CHECK".
        PRINT "  Keep/reselect the waypoint, check orbit reachability, then resume manually.".
        yieldToPrompt().
        RETURN.
    }
    nextPhase(fr3Seq).
}

LOCAL FUNCTION _timedLandingDeorbit {
    LOCAL leadMin IS 0.5.
    IF CFG:HASKEY("LANDING_DEORBIT_LEAD_MINUTES") {
        SET leadMin TO CFG["LANDING_DEORBIT_LEAD_MINUTES"].
    }
    LOCAL burnUT IS TIME:SECONDS + MAX(30, leadMin * 60).
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL rBurn IS (POSITIONAT(SHIP, burnUT) - POSITIONAT(SHIP:BODY, burnUT)):MAG.
    LOCAL deorbitPe IS _landingDeorbitPe().
    LOCAL rPe IS bodyR + deorbitPe.
    LOCAL tSMA IS (rBurn + rPe) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL rawDV IS vNew - vNow.

    // Clamp dV to configurable min/max bounds
    LOCAL minDV IS 350.
    LOCAL maxDV IS 600.
    IF CFG:HASKEY("LANDING_DEORBIT_MIN_DV") { SET minDV TO CFG["LANDING_DEORBIT_MIN_DV"]. }
    IF CFG:HASKEY("LANDING_DEORBIT_MAX_DV") { SET maxDV TO CFG["LANDING_DEORBIT_MAX_DV"]. }
    LOCAL clampedDV IS MIN(-minDV, MAX(-maxDV, rawDV)).
    LOCAL nd IS NODE(burnUT, 0, 0, clampedDV).

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    ADD nd.
    mLogWarn("STATS land-deorbit timed setup leadMin=" + ROUND(leadMin,1)
        + " burnT=" + ROUND(burnUT - TIME:SECONDS,0)
        + " targetPeKm=" + ROUND(deorbitPe/1000,1)
        + " rawDV=" + ROUND(rawDV,1)
        + " dv=" + ROUND(clampedDV,1)).
    mLog("Timed sim deorbit node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s at T+" + ROUND(nd:ETA,0) + "s.").
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Planned maneuver log archived: timed-landing-deorbit.").
    }
    LOCAL ok IS executeDeorbitNode(nd).
    mLogWarn("STATS land-deorbit timed result ok=" + ok
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " status=" + SHIP:STATUS).
    IF NOT ok {
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  TIMED LANDING DEORBIT MISSED".
        PRINT "  Resume manually or rerun setup when ready.".
        yieldToPrompt().
        RETURN FALSE.
    }
    RETURN TRUE.
}

// Execute a maneuver node with align, staged throttle, and cleanup.
// Self-contained — no dependency on maneuver.ks. Used by both the
// timed deorbit path and targeted deorbit (via deorbit_targeting.ks).
GLOBAL FUNCTION executeDeorbitNode {
    PARAMETER nd.
    LOCAL burnDV IS nd:DELTAV:MAG.
    IF SHIP:AVAILABLETHRUST <= 0 OR SHIP:MASS <= 0 {
        mLogError("Timed deorbit cannot burn: no available thrust.").
        REMOVE nd.
        RETURN FALSE.
    }
    LOCAL maxAcc IS SHIP:AVAILABLETHRUST / SHIP:MASS.
    LOCAL burnTime IS burnDV / MAX(0.1, maxAcc).
    LOCAL startTime IS nd:TIME - burnTime / 2.
    IF startTime < TIME:SECONDS + 5 { SET startTime TO TIME:SECONDS + 5. }

    mLogWarn("STATS timed-burn setup dv=" + ROUND(burnDV,1)
        + " eta=" + ROUND(startTime - TIME:SECONDS,1)
        + " nodeEta=" + ROUND(nd:ETA,1)
        + " maxAcc=" + ROUND(maxAcc,2)).
    SET SAS TO FALSE.
    LOCK STEERING TO nd:BURNVECTOR.
    LOCAL alignDeadline IS MIN(startTime - 2, TIME:SECONDS + 45).
    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < 5
            OR TIME:SECONDS >= alignDeadline {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }
    mLogWarn("STATS timed-burn align angle="
        + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR),1)
        + " timeToBurn=" + ROUND(startTime - TIME:SECONDS,1)).

    WAIT UNTIL TIME:SECONDS >= startTime.
    LOCAL burnStart IS TIME:SECONDS.
    LOCAL origBurnVec IS nd:BURNVECTOR.
    mLog("Timed deorbit burn start. dV=" + ROUND(burnDV,1) + " m/s.").
    UNTIL nd:DELTAV:MAG < MAX(0.08, burnDV * 0.01)
            OR TIME:SECONDS - burnStart > burnTime * 2 + 8 {
        LOCK STEERING TO nd:BURNVECTOR.
        IF nd:DELTAV:MAG > 0.1
                AND VDOT(origBurnVec:NORMALIZED, nd:BURNVECTOR:NORMALIZED) < 0 {
            BREAK.
        }
        IF nd:DELTAV:MAG > 3 {
            LOCK THROTTLE TO 1.
        } ELSE IF nd:DELTAV:MAG > 0.4 {
            LOCK THROTTLE TO 0.25.
        } ELSE {
            LOCK THROTTLE TO 0.05.
        }
        WAIT 0.02.
    }

    LOCAL residual IS nd:DELTAV:MAG.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    REMOVE nd.
    SET SAS TO TRUE.
    mLog("Timed deorbit burn complete. Residual=" + ROUND(residual,2) + " m/s.").
    mLogWarn("STATS timed-burn result dv=" + ROUND(burnDV,1)
        + " residual=" + ROUND(residual,2)
        + " duration=" + ROUND(TIME:SECONDS - burnStart,1)).
    RETURN TRUE.
}

LOCAL FUNCTION _landingDeorbitPe {
    IF DEFINED LANDING_CFG {
        RETURN LANDING_CFG["DEORBIT_PE"].
    }
    IF CFG:HASKEY("LANDING_DEORBIT_PE") {
        RETURN CFG["LANDING_DEORBIT_PE"].
    }
    RETURN -3000.
}

LOCAL FUNCTION _confirmLandingTarget {
    LOCAL targetInfo IS landingResolveTarget().
    IF NOT targetInfo["FOUND"] {
        IF _autoLandingTarget() {
            SET targetInfo TO landingResolveTarget().
        }
    }
    PRINT " ".
    PRINT "  LANDING TARGET CHECK".
    IF targetInfo["FOUND"] {
        PRINT "  Source: " + targetInfo["SOURCE"].
        PRINT "  Lat/Lng: " + ROUND(targetInfo["LAT"],4)
            + ", " + ROUND(targetInfo["LNG"],4).
        mLogWarn("STATS landing target confirm source=" + targetInfo["SOURCE"]
            + " lat=" + ROUND(targetInfo["LAT"],4)
            + " lng=" + ROUND(targetInfo["LNG"],4)).
    } ELSE {
        PRINT "  No landing target found.".
        PRINT "  Select a waypoint, run simlandhere, or set LANDING_TARGET_LAT/LNG.".
        mLogWarn("STATS landing target confirm status=missing").
        yieldToPrompt().
        RETURN FALSE.
    }
    PRINT "  Press any key to plan targeted deorbit.".
    WAIT UNTIL TERMINAL:INPUT:HASCHAR.
    TERMINAL:INPUT:GETCHAR().
    RETURN TRUE.
}

LOCAL FUNCTION _autoLandingTarget {
    IF NOT CFG:HASKEY("LANDING_AUTO_TARGET") { RETURN FALSE. }
    IF CFG["LANDING_AUTO_TARGET"] <= 0 { RETURN FALSE. }

    LOCAL minutes IS 5.
    IF CFG:HASKEY("LANDING_AUTO_TARGET_MINUTES") {
        SET minutes TO CFG["LANDING_AUTO_TARGET_MINUTES"].
    }
    LOCAL geo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, TIME:SECONDS + minutes * 60)).
    SET LANDING_CFG["TARGET_LAT"] TO geo:LAT.
    SET LANDING_CFG["TARGET_LNG"] TO geo:LNG.
    SET LANDING_CFG["TARGET_LOCK"] TO TRUE.
    IF DEFINED stateSet {
        stateSet("mission_cfg_LANDING_TARGET_LAT", geo:LAT).
        stateSet("mission_cfg_LANDING_TARGET_LNG", geo:LNG).
        stateSet("mission_cfg_LANDING_TARGET_LOCK", "1").
    }
    mLogWarn("STATS landing target auto source=ground-track minutes="
        + ROUND(minutes,1)
        + " lat=" + ROUND(geo:LAT,4)
        + " lng=" + ROUND(geo:LNG,4)).
    RETURN TRUE.
}

GLOBAL FUNCTION phaseLandAssist {
    IF DEFINED fr3ApplyMissionProfile { fr3ApplyMissionProfile(). }
    mLogWarn("STATS land-assist phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)).
    IF _redirectOrbitalLandingPhase("LAND_ASSIST") { RETURN. }
    IF CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH") AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0 {
        mLogWarn("STATS landing-impact skipped reason=sim-no-target-search").
    } ELSE IF NOT landingImpactAcceptableForAssist() {
        mLogError("Predicted landing impact is not within target tolerance; holding LAND_ASSIST.").
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        PRINT " ".
        PRINT "  LANDING IMPACT CHECK FAILED".
        PRINT "  Replan deorbit or verify selected waypoint before descent.".
        yieldToPrompt().
        RETURN.
    }
    LOCAL assistOk IS landingAssistStage().
    mLogWarn("STATS land-assist phase result ok=" + assistOk
        + " alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " status=" + SHIP:STATUS).
    IF NOT assistOk {
        mLogError("Landing assist failed; holding current phase for manual review.").
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        PRINT " ".
        PRINT "  LANDING ASSIST FAILED".
        PRINT "  Review target, decoupler tag, attitude, fuel, and phase before resuming.".
        yieldToPrompt().
        RETURN.
    }
    nextPhase(fr3Seq).
}

GLOBAL FUNCTION phaseLand {
    mLogWarn("STATS land phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).

    IF _redirectOrbitalLandingPhase("LAND") { RETURN. }

    landingExecute().
    mLogWarn("STATS land phase result alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).
    nextPhase(fr3Seq).
}

LOCAL FUNCTION _redirectOrbitalLandingPhase {
    PARAMETER phaseName.
    IF (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "SUB_ORBITAL")
            AND SHIP:PERIAPSIS > LANDING_CFG["DEORBIT_PE"] {
        mLogWarn(phaseName + " requested while still in orbit; returning to LAND_DEORBIT.").
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING TARGET CHECK".
        PRINT "  Select the landing waypoint in map/navigation.".
        PRINT "  Phase reset to LAND_DEORBIT. Resume manually when ready.".
        yieldToPrompt().
        RETURN TRUE.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION phaseRover {
    roverInit().
    roverHUD().
}
