// --- Config defaults owned by this file ---
GLOBAL LANDING_SKIP_TARGET_SEARCH IS 0.
GLOBAL LANDING_DEORBIT_LEAD_MINUTES IS 0.
GLOBAL LANDING_AUTO_TARGET IS 0.
GLOBAL LANDING_AUTO_TARGET_MINUTES IS 5.
GLOBAL LANDING_CONFIRM_TARGET IS 1.
// Opt-in: remain in orbit unless SCANsat finds a site within the slope limit.
GLOBAL LANDING_REQUIRE_SITE IS 0.
GLOBAL TARGET_DEORBIT_SCAN_ORBITS IS 0.
GLOBAL TARGET_DEORBIT_SCAN_SAMPLES IS 128.
GLOBAL TARGET_DEORBIT_SCAN_CENTER_MINUTES IS 0.
GLOBAL TARGET_DEORBIT_SCAN_WINDOW_MINUTES IS 0.
GLOBAL TARGET_DEORBIT_MIN_LEAD IS 0.
GLOBAL LANDING_SIM_MODE IS 0.
GLOBAL REENTRY_PE IS 30000.
GLOBAL RELOAD_AFTER_LAND_ASSIST IS 1.
GLOBAL RELOAD_AFTER_LAND IS 1.
// Ephemeral context for this freshly selected site, not a cached orbit plan.
LOCAL _landingTargetPassUT IS 0.

// Landing deorbit phase: target, create, and execute the deorbit node.

GLOBAL FUNCTION phaseLandDeorbit {
    landingApplyMissionConfig().
    IF ABORT {
        mLogWarn("LAND_DEORBIT paused: Abort action group is ON; no site search or burn attempted.").
        PRINT "Clear Abort deliberately with SET ABORT TO FALSE. then REBOOT when ready.".
        yieldToPrompt().
        RETURN.
    }
    IF NOT vesselLandingPrepareRoles() AND SHIP:STATUS = "ORBITING" {
        mLogError("Landing role tags failed validation; retaining orbit. Review STATS landing roles.").
        yieldToPrompt().
        RETURN.
    }
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
    IF stateGet("deorbit_burn_started", "false") = "true" {
        mLogError("Interrupted deorbit has no retained node; refusing a replacement burn. Review the actual trajectory manually.").
        yieldToPrompt().
        RETURN.
    }
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
    mLog("STATS landing-deorbit resume existing-node dv="
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

    // An unflown retained node may predate tighter geometry/fuel settings.
    // Preserve it on rejection. Do not turn committed descent recovery into
    // a new orbital planning hold after a partial burn.
    LOCAL beforeBurn IS 0.
    LOCAL targetLat IS 999.
    LOCAL targetLng IS 999.
    IF LANDING_SKIP_TARGET_SEARCH <= 0 AND SHIP:STATUS = "ORBITING"
            AND SHIP:PERIAPSIS > 0
            AND stateGet("deorbit_burn_started", "false") <> "true" {
        LOCAL landingTarget IS landingResolveTarget().
        IF NOT landingTarget["FOUND"] {
            mLogError("Retained deorbit node has no resolved target; node preserved.").
            yieldToPrompt(). RETURN TRUE.
        }
        SET beforeBurn TO landingDeorbitNodeAccepted@.
        SET targetLat TO landingTarget["LAT"].
        SET targetLng TO landingTarget["LNG"].
        IF NOT landingDeorbitNodeAccepted(nd, landingTarget["LAT"], landingTarget["LNG"]) {
            mLogError("Retained deorbit node fails geometry/terrain/fuel limits; node preserved. Replan from orbit with cmd/landlight apply.").
            yieldToPrompt(). RETURN TRUE.
        }
    }

    IF executeDeorbitNode(nd,targetLat,targetLng,beforeBurn) {
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
    stateRemove("deorbit_burn_started").
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
    SET _landingTargetPassUT TO 0.
    LOCAL targetInfo IS landingResolveTarget().
    // Economy intent is the current orbit's ground track, not a coordinate
    // cached before capture/corrections. Refresh even an old locked target.
    // Existing/interrupted nodes are handled before this function is called.
    IF LANDING_FLEXIBLE_SITE > 0 AND LANDING_AUTO_TARGET > 0
            AND SHIP:STATUS = "ORBITING" AND SHIP:PERIAPSIS > 0 {
        IF NOT _autoLandingTarget() {
            mLogWarn("Economy target refresh failed; retaining orbit instead of using an old site.").
            yieldToPrompt().
            RETURN FALSE.
        }
        SET targetInfo TO landingResolveTarget().
    } ELSE IF NOT targetInfo["FOUND"] {
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
        IF landingLightActive() {
            PRINT "  Use cmd/landlight to review ground-track light/Kerbin constraints.".
        } ELSE {
            PRINT "  Select a waypoint or set TARGET_LAT/LNG.".
        }
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

LOCAL FUNCTION _landingWriteTargetOverrides {
    // Keep unrelated overrides, especially the surface-return sequence.
    missionOverrideUpdate(LEXICON("TARGET_LAT", TARGET_LAT, "TARGET_LNG", TARGET_LNG,
        "TARGET_LOCK", TARGET_LOCK, "TARGET_WAYPOINT", TARGET_WAYPOINT)).
}

LOCAL FUNCTION _autoLandingTarget {
    IF LANDING_AUTO_TARGET <= 0 { RETURN FALSE. }

    LOCAL minutes IS 5.
    SET minutes TO LANDING_AUTO_TARGET_MINUTES.
    LOCAL passUT IS TIME:SECONDS + minutes * 60.
    IF landingLightActive() {
        LOCAL site IS landingAwaitLitGroundTrack().
        IF NOT site["FOUND"] {
            mLogWarn("STATS landing-light selection result=not-selected reason=" + site["REASON"]
                + " abort=" + ABORT).
            IF ABORT {
                mLogWarn("Landing site selection canceled by Abort; no light-window failure established.").
            } ELSE {
                mLogWarn("No ground-track site selected; reason=" + site["REASON"]
                    + ". Orbit retained. Use cmd/landlight to review policy.").
            }
            RETURN FALSE.
        }
        SET TARGET_LAT TO site["LAT"].
        SET TARGET_LNG TO site["LNG"].
        SET passUT TO site["UT"].
    } ELSE {
        LOCAL geo IS lmGroundGeoAt(passUT).
        SET TARGET_LAT TO geo:LAT.
        SET TARGET_LNG TO geo:LNG.
    }
    SET TARGET_LOCK TO 1.
    SET TARGET_WAYPOINT TO "".
    SET _landingTargetPassUT TO passUT.
    _landingWriteTargetOverrides().
    mLog("STATS landing-target selected source=current-ground-track"
        + " targetLat=" + ROUND(TARGET_LAT,4)
        + " targetLng=" + ROUND(TARGET_LNG,4)
        + " orbitInc=" + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " passUT=" + ROUND(passUT,1)).
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
    LOCAL site IS selectScanSatLandingSite(TARGET_LAT, TARGET_LNG).
    IF LANDING_REQUIRE_SITE > 0 AND NOT site["FOUND"] {
        mLogWarn("STATS landing-site result=hold reason=no-suitable-scanned-site").
        mLogWarn("No suitable scanned site nearby. Check SCANsat coverage or choose another ground-track site before retrying.").
        RETURN FALSE.
    }
    IF site["FOUND"] {
        SET TARGET_LAT TO site["LAT"].
        SET TARGET_LNG TO site["LNG"].
        SET TARGET_LOCK TO 1.
        SET TARGET_WAYPOINT TO "".
        // LAND_ASSIST loads after a reboot: preserve the same refined site.
        _landingWriteTargetOverrides().
        mLog("STATS landing-site result=selected lat=" + TARGET_LAT
            + " lng=" + TARGET_LNG + " slope=" + site["SLOPE"]
            + " distance=" + site["DIST"]).
    }
    mLog("Landing deorbit target: " + ROUND(TARGET_LAT,4)
        + "," + ROUND(TARGET_LNG,4)
        + " from " + landingTarget["SOURCE"] + ".").

    // Already selected/persisted above; do not refine a second time.
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) {
        stateSet("landing_prior_ipu", priorIpu).
        SET CONFIG:IPU TO MIN(2000, LANDING_MIN_IPU).
    }
    LOCAL success IS targetedDeorbitAt(TARGET_LAT, TARGET_LNG, 0, 0, FALSE,
        _landingTargetPassUT).
    SET CONFIG:IPU TO priorIpu.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) { stateRemove("landing_prior_ipu"). }
    RETURN success.
}
