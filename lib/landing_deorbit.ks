// Landing deorbit phase: target, create, and execute the deorbit node.

GLOBAL FUNCTION phaseLandDeorbit {
    landingApplyMissionConfig().
    IF SHIP:STATUS = "SUB_ORBITAL"
            AND (CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH")
                AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0) {
        _advanceAfterLandDeorbit().
        RETURN.
    }
    IF SHIP:STATUS = "SUB_ORBITAL" AND landingImpactAcceptableForAssist() {
        _advanceAfterLandDeorbit().
        RETURN.
    }
    IF CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH") AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0 {
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

    LOCAL minDV IS 350.
    LOCAL maxDV IS 600.
    IF CFG:HASKEY("LANDING_DEORBIT_MIN_DV") { SET minDV TO CFG["LANDING_DEORBIT_MIN_DV"]. }
    IF CFG:HASKEY("LANDING_DEORBIT_MAX_DV") { SET maxDV TO CFG["LANDING_DEORBIT_MAX_DV"]. }
    LOCAL clampedDV IS MIN(-minDV, MAX(-maxDV, rawDV)).
    LOCAL nd IS NODE(burnUT, 0, 0, clampedDV).

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

LOCAL FUNCTION _landingDeorbitPe {
    RETURN LANDING_CFG["DEORBIT_PE"].
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
        PRINT "  Select a waypoint, run simlandhere, or set LANDING_TARGET_LAT/LNG.".
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
    stateSet("mission_cfg_LANDING_TARGET_LAT", geo:LAT).
    stateSet("mission_cfg_LANDING_TARGET_LNG", geo:LNG).
    stateSet("mission_cfg_LANDING_TARGET_LOCK", "1").
    RETURN TRUE.
}

LOCAL FUNCTION _landingHVel {
    LOCAL upVec IS SHIP:UP:VECTOR.
    RETURN SHIP:VELOCITY:SURFACE - (VDOT(SHIP:VELOCITY:SURFACE, upVec) * upVec).
}

LOCAL FUNCTION _landingOffsetLatLng {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER northM.
    PARAMETER eastM.
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(lat)).
    RETURN LEXICON(
        "LAT", lat + northM * degPerM,
        "LNG", lng + eastM * degPerM / lonScale
    ).
}

LOCAL FUNCTION _landingOvershootTarget {
    PARAMETER landingTarget.
    LOCAL out IS LEXICON("LAT", landingTarget["LAT"], "LNG", landingTarget["LNG"]).
    LOCAL overshoot IS LANDING_CFG["DEORBIT_OVERSHOOT"].
    IF overshoot <= 0 { RETURN out. }

    LOCAL hv IS _landingHVel().
    IF hv:MAG < 0.1 { RETURN out. }
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL northVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE + 0.01, SHIP:LONGITUDE):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL eastVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE, SHIP:LONGITUDE + 0.01):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL northM IS VDOT(hv:NORMALIZED, northVec) * overshoot.
    LOCAL eastM IS VDOT(hv:NORMALIZED, eastVec) * overshoot.
    LOCAL shifted IS _landingOffsetLatLng(
        landingTarget["LAT"], landingTarget["LNG"], northM, eastM).
    SET out["LAT"] TO shifted["LAT"].
    SET out["LNG"] TO shifted["LNG"].
    RETURN out.
}

LOCAL FUNCTION _landingTargetedDeorbit {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set — refusing blind landing deorbit.").
        RETURN FALSE.
    }

    SET LANDING_CFG["TARGET_LAT"] TO landingTarget["LAT"].
    SET LANDING_CFG["TARGET_LNG"] TO landingTarget["LNG"].
    mLog("Landing deorbit target: " + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)
        + " from " + landingTarget["SOURCE"] + ".").

    IF (LANDING_CFG["DEORBIT_PE"]:TYPENAME = "STRING") {
        SET LANDING_CFG["DEORBIT_PE"] TO LANDING_CFG["DEORBIT_PE"]:TONUMBER:
    }
    LOCAL aimTarget IS _landingOvershootTarget(landingTarget).
    RETURN targetedDeorbitAt(
        aimTarget["LAT"],
        aimTarget["LNG"],
        LANDING_CFG["DEORBIT_PE"],
        LANDING_CFG["TARGET_TOLERANCE"]).
}
