// --- Config defaults owned by this file ---
GLOBAL LANDING_SKIP_TARGET_SEARCH IS 0.
GLOBAL LANDING_DEORBIT_LEAD_MINUTES IS 0.
GLOBAL LANDING_AUTO_TARGET IS 0.
GLOBAL LANDING_AUTO_TARGET_MINUTES IS 5.
GLOBAL LANDING_CONFIRM_TARGET IS 1.
GLOBAL TARGET_DEORBIT_SCAN_ORBITS IS 0.
GLOBAL TARGET_DEORBIT_SCAN_SAMPLES IS 128.
GLOBAL TARGET_DEORBIT_SCAN_CENTER_MINUTES IS 0.
GLOBAL TARGET_DEORBIT_SCAN_WINDOW_MINUTES IS 0.
GLOBAL TARGET_DEORBIT_MIN_LEAD IS 0.
GLOBAL LANDING_SIM_MODE IS 0.
GLOBAL REENTRY_PE IS 30000.

// Landing deorbit phase: target, create, and execute the deorbit node.

GLOBAL FUNCTION phaseLandDeorbit {
    landingApplyMissionConfig().
    IF SHIP:STATUS = "SUB_ORBITAL"
            AND (LANDING_SKIP_TARGET_SEARCH > 0) {
        _advanceAfterLandDeorbit().
        RETURN.
    }
    IF SHIP:STATUS = "SUB_ORBITAL" AND landingImpactAcceptableForAssist() {
        _advanceAfterLandDeorbit().
        RETURN.
    }
    IF _resumeExistingLandingDeorbitNode() { RETURN. }
    IF LANDING_SKIP_TARGET_SEARCH > 0 {
        IF _timedLandingDeorbit() {
            _advanceAfterLandDeorbit().
        }
        RETURN.
    }
    IF NOT _confirmLandingTarget() { RETURN. }
    LOCAL deorbitOk IS _landingTargetedDeorbit().
    IF NOT deorbitOk {
        mLogError("Landing deorbit did not meet target tolerance; holding for manual review.").
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING DEORBIT FAILED TARGET CHECK".
        PRINT "  Keep/reselect the waypoint, check orbit reachability, then resume manually.".
        yieldToPrompt().
        RETURN.
    }
    _advanceAfterLandDeorbit().
}

LOCAL FUNCTION _resumeExistingLandingDeorbitNode {
    IF NOT HASNODE { RETURN FALSE. }

    LOCAL nd IS NEXTNODE.
    mLogWarn("STATS landing-deorbit resume existing-node dv="
        + ROUND(nd:DELTAV:MAG,1)
        + " eta=" + ROUND(nd:ETA,1)
        + " body=" + SHIP:BODY:NAME).

    IF nd:ETA <= 10 {
        mLogWarn("Existing landing deorbit node is too close or past; leaving it for manual review.").
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING DEORBIT NODE TOO CLOSE".
        PRINT "  Existing maneuver node was preserved. Execute manually or resume after replanning.".
        yieldToPrompt().
        RETURN TRUE.
    }

    IF executeDeorbitNode(nd) {
        _advanceAfterLandDeorbit().
    } ELSE {
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING DEORBIT EXISTING NODE FAILED".
        PRINT "  Existing maneuver was not replaced. Review the node, then resume manually.".
        yieldToPrompt().
    }
    RETURN TRUE.
}

LOCAL FUNCTION _advanceAfterLandDeorbit {
    LOCAL nxt IS nextPhase(launchSeq).
    LOCAL requiredBand IS bootLibBandForPhase(nxt, "").
    LOCAL loadedBand IS stateGet("lib_band", "").
    IF requiredBand <> "" AND requiredBand <> loadedBand {
        stateSet("reload_required", "true").
        stateSet("reload_reason", "LAND_DEORBIT_COMPLETE").
        stateSet("reload_next_phase", nxt).
        stateSet("reload_next_band", requiredBand).
        mLogWarn("Landing deorbit complete; rebooting into band "
            + requiredBand + ".").
        WAIT 2.
        REBOOT.
    }
    RETURN nxt.
}

LOCAL FUNCTION _timedLandingDeorbit {
    LOCAL leadMin IS 0.5.
    SET leadMin TO LANDING_DEORBIT_LEAD_MINUTES.
    LOCAL burnUT IS TIME:SECONDS + MAX(30, leadMin * 60).
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL rBurn IS (POSITIONAT(SHIP, burnUT) - POSITIONAT(SHIP:BODY, burnUT)):MAG.
    LOCAL deorbitPe IS landingFlyoverPe().
    LOCAL rPe IS bodyR + deorbitPe.
    LOCAL tSMA IS (rBurn + rPe) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL rawDV IS vNew - vNow.
    LOCAL nd IS NODE(burnUT, 0, 0, rawDV).

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    ADD nd.
    mLog("Timed sim deorbit node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s at T+" + ROUND(nd:ETA,0) + "s.").
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Planned maneuver log archived: timed-landing-deorbit.").
    }
    LOCAL ok IS executeDeorbitNode(nd).
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
    } ELSE {
        PRINT "  No landing target found.".
        PRINT "  Select a waypoint, run simlandhere, or set TARGET_LAT/LNG.".
        yieldToPrompt().
        RETURN FALSE.
    }
    IF LANDING_CONFIRM_TARGET > 0 {
        PRINT "  Press any key to plan targeted deorbit.".
        WAIT UNTIL TERMINAL:INPUT:HASCHAR.
        TERMINAL:INPUT:GETCHAR().
    } ELSE {
        PRINT "  Target auto-confirmed by mission profile.".
        mLog("Landing target auto-confirmed.").
    }
    RETURN TRUE.
}

LOCAL FUNCTION _autoLandingTarget {
    IF LANDING_AUTO_TARGET <= 0 { RETURN FALSE. }

    LOCAL minutes IS 5.
    SET minutes TO LANDING_AUTO_TARGET_MINUTES.
    LOCAL geo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, TIME:SECONDS + minutes * 60)).
    SET TARGET_LAT TO geo:LAT.
    SET TARGET_LNG TO geo:LNG.
    SET TARGET_LOCK TO TRUE.
    stateSet("mission_cfg_TARGET_LAT", geo:LAT).
    stateSet("mission_cfg_TARGET_LNG", geo:LNG).
    stateSet("mission_cfg_TARGET_LOCK", 1).
    RETURN TRUE.
}

LOCAL FUNCTION _landingTargetedDeorbit {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set — refusing blind landing deorbit.").
        RETURN FALSE.
    }

    SET TARGET_LAT TO landingTarget["LAT"].
    SET TARGET_LNG TO landingTarget["LNG"].
    mLog("Landing deorbit target: " + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)
        + " from " + landingTarget["SOURCE"] + ".").

    RETURN targetedDeorbitAt(
        landingTarget["LAT"],
        landingTarget["LNG"]).
}
