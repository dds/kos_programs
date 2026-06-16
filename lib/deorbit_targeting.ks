// ============================================================
// deorbit_targeting.ks  —  Precision deorbit targeting  (0:/lib/deorbit_targeting.ks)
// ============================================================

GLOBAL FUNCTION targetedDeorbit {
    LOCAL targetInfo IS targetResolveDeorbitTarget().
    IF NOT targetInfo["FOUND"] {
        mLogError("No deorbit target set. Configure PROBE_TARGET_LAT/LNG or select a waypoint.").
        RETURN FALSE.
    }

    mLog("Deorbit target source: " + targetInfo["SOURCE"] + ".").
    RETURN targetedDeorbitAt(targetInfo["LAT"], targetInfo["LNG"]).
}

GLOBAL FUNCTION targetResolveDeorbitTarget {
    LOCAL result IS LEXICON(
        "FOUND", FALSE,
        "LAT", 0,
        "LNG", 0,
        "SOURCE", "none"
    ).

    IF CFG:HASKEY("PROBE_TARGET_WAYPOINT") AND CFG["PROBE_TARGET_WAYPOINT"] <> "" {
        LOCAL namedWp IS waypointNamed(CFG["PROBE_TARGET_WAYPOINT"]).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Probe waypoint '" + CFG["PROBE_TARGET_WAYPOINT"]
            + "' not found on " + SHIP:BODY:NAME + ".").
    }

    LOCAL selectedWp IS selectedWaypoint().
    IF selectedWp <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO selectedWp:GEOPOSITION:LAT.
        SET result["LNG"] TO selectedWp:GEOPOSITION:LNG.
        SET result["SOURCE"] TO "selected waypoint:" + selectedWp:NAME.
        RETURN result.
    }

    IF CFG:HASKEY("PROBE_TARGET_LAT") AND CFG:HASKEY("PROBE_TARGET_LNG") {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO CFG["PROBE_TARGET_LAT"].
        SET result["LNG"] TO CFG["PROBE_TARGET_LNG"].
        SET result["SOURCE"] TO "CFG PROBE_TARGET_LAT/LNG".
        RETURN result.
    }

    RETURN result.
}

GLOBAL FUNCTION targetedDeorbitAt {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER ignoredPe IS 0.
    PARAMETER ignoredTolerance IS 0.
    PARAMETER ignoredOvershoot IS 0.

    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available; targeted landing deorbit requires TR.").
        RETURN FALSE.
    }

    IF NOT targetReachable(targetLat) {
        mLogError("Target latitude is not reachable from this orbit inclination.").
        RETURN FALSE.
    }

    LOCAL site IS LEXICON("FOUND", FALSE).
    IF DEFINED BOOT_LIB_RAN AND BOOT_LIB_RAN:CONTAINS("landing_site") {
        SET site TO selectScanSatLandingSite(targetLat, targetLng).
    }
    IF site["FOUND"] {
        SET targetLat TO site["LAT"].
        SET targetLng TO site["LNG"].
    }

    LOCAL targetGeo IS LATLNG(targetLat, targetLng).
    LOCAL entryPe IS targetGeo:TERRAINHEIGHT - 1000.
    IF ignoredPe <> 0 { SET entryPe TO ignoredPe. }
    LOCAL tolerance IS LAND_CFG_TARGET_TOLERANCE.
    IF ignoredTolerance > 0 { SET tolerance TO ignoredTolerance. }
    LOCAL coarseStopDist IS MAX(10000, tolerance).
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + ","
        + ROUND(targetLng,4)
        + "  entryPe=" + ROUND(entryPe/1000,1) + "km"
        + "  tolerance=" + ROUND(tolerance/1000,1) + "km").
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL orbitSma IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL twoOverOrbitSma IS 2 / orbitSma.
    LOCAL minLead IS _targetDeorbitMinLead().
    LOCAL scanOrbits IS 8.
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_ORBITS") {
        IF (CFG["TARGET_DEORBIT_SCAN_ORBITS"]:TYPENAME = "STRING") {
            SET scanOrbits TO CFG["TARGET_DEORBIT_SCAN_ORBITS"]:TONUMBER.
        } ELSE {
            SET scanOrbits TO CFG["TARGET_DEORBIT_SCAN_ORBITS"].
        }
    }
    IF CFG:HASKEY("LANDING_SIM_MODE") AND CFG["LANDING_SIM_MODE"] > 0 {
        IF scanOrbits > 2 { SET scanOrbits TO 2. }
    }

    LOCAL scanStart IS nowUt + minLead.
    LOCAL scanEnd IS nowUt + period * scanOrbits + 30.
    LOCAL stepA IS period / 64.
    LOCAL bestUT IS scanStart.
    LOCAL bestDist IS 999999999.
    LOCAL validSamples IS 0.
    LOCAL scanUT IS scanStart.

    mLog("Node scan: T+" + ROUND(scanEnd - nowUt,0)
        + "s step=" + ROUND(stepA,1)
        + "s TR target=true-site.").
    UNTIL scanUT > scanEnd OR bestDist <= coarseStopDist {
        LOCAL trial IS _evalDeorbitNode(scanUT, entryPe, targetLat, targetLng,
            bodyR, mu, orbitSma, twoOverOrbitSma, minLead).
        IF trial["VALID"] {
            SET validSamples TO validSamples + 1.
            IF trial["DIST"] < bestDist {
                SET bestDist TO trial["DIST"].
                SET bestUT TO scanUT.
                mLog("DEBUG node: T+" + ROUND(scanUT - nowUt,0)
                    + "s impact=" + ROUND(trial["LAT"],4)
                    + "," + ROUND(trial["LNG"],4)
                    + " dist=" + ROUND(bestDist/1000,1) + "km").
            }
        }
        SET scanUT TO scanUT + stepA.
        WAIT 0.
    }

    IF validSamples = 0 {
        mLogError("No deorbit node produced a Trajectories impact.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    mLog("Coarse best: T+" + ROUND(bestUT - nowUt,0)
        + "s dist=" + ROUND(bestDist/1000,1)
        + "km samples=" + validSamples + ".").

    LOCAL fstep IS stepA * 0.5.
    UNTIL fstep < 0.5 {
        FOR cand IN LIST(bestUT - fstep, bestUT + fstep) {
            IF cand > nowUt + minLead {
                LOCAL refined IS _evalDeorbitNode(cand, entryPe,
                    targetLat, targetLng, bodyR, mu, orbitSma,
                    twoOverOrbitSma, minLead).
                IF refined["VALID"] AND refined["DIST"] < bestDist {
                    SET bestDist TO refined["DIST"].
                    SET bestUT TO cand.
                }
            }
        }
        SET fstep TO fstep / 2.
        WAIT 0.
    }

    LOCAL finalCheck IS _evalDeorbitNode(bestUT, entryPe, targetLat, targetLng,
        bodyR, mu, orbitSma, twoOverOrbitSma, minLead).
    IF finalCheck["VALID"] {
        SET bestDist TO finalCheck["DIST"].
        mLog("Polished best: T+" + ROUND(bestUT - nowUt,0)
            + "s impact=" + ROUND(finalCheck["LAT"],4)
            + "," + ROUND(finalCheck["LNG"],4)
            + " dist=" + ROUND(bestDist,0) + "m.").
    }

    IF bestDist > tolerance {
        mLogWarn("Best solution misses target by " + ROUND(bestDist/1000,1)
            + "km; tolerance is " + ROUND(tolerance/1000,1) + "km.").
        HUDTEXT("Landing deorbit miss " + ROUND(bestDist/1000,1) + "km",
            5, 2, 14, YELLOW, FALSE).
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL realNode IS _planDeorbitNode(bestUT, entryPe, bodyR, mu,
        orbitSma, twoOverOrbitSma).
    WAIT 0.5.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL trDist IS geoDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
        mLog("TR final: impact=" + ROUND(impactPos:LAT,4)
            + "," + ROUND(impactPos:LNG,4)
            + " dist=" + ROUND(trDist/1000,2) + "km"
            + " Pe=" + ROUND(realNode:ORBIT:PERIAPSIS/1000,1) + "km.").
    } ELSE {
        mLogWarn("TR final: no impact predicted for selected node.").
    }

    IF LAND_CFG_TERRAIN_VALIDATE {
        LOCAL crashDist IS lmTerrainClearanceCheck(
            targetLat, targetLng,
            bestUT + 30, bestUT + 1800,
            2,
            LAND_CFG_TERRAIN_MIN_CLEARANCE,
            LAND_CFG_TERRAIN_SAFE_ALT).
        IF crashDist > LAND_CFG_TERRAIN_MAX_CRASH_DIST {
            mLogError("TERRAIN CHECK FAILED: trajectory hits terrain "
                + ROUND(crashDist,0) + "m from target.").
            REMOVE realNode.
            RETURN FALSE.
        }
        mLog("Terrain check passed.").
    }

    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    archiveLog().
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s",
        3, 2, 13, CYAN, FALSE).
    executeDeorbitNode(realNode).

    WAIT 2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL postImpact IS ADDONS:TR:IMPACTPOS.
        LOCAL postDist IS geoDistance(postImpact:LAT, postImpact:LNG,
            targetLat, targetLng).
        mLog("Post-burn impact prediction: "
            + ROUND(postImpact:LAT,4) + "," + ROUND(postImpact:LNG,4)
            + " dist=" + ROUND(postDist/1000,1) + "km.").
    } ELSE {
        mLogWarn("Post-burn: Trajectories has no impact prediction.").
    }
    RETURN TRUE.
}

LOCAL FUNCTION _evalDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER bodyR.
    PARAMETER mu.
    PARAMETER orbitSma.
    PARAMETER twoOverOrbitSma.
    PARAMETER minLead.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "DIST", 999999999,
        "LAT", 0,
        "LNG", 0
    ).

    IF burnUT <= TIME:SECONDS + minLead { RETURN result. }
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planDeorbitNode(burnUT, entryPe, bodyR, mu,
        orbitSma, twoOverOrbitSma).
    WAIT 0.2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        SET result["VALID"] TO TRUE.
        SET result["LAT"] TO impactPos:LAT.
        SET result["LNG"] TO impactPos:LNG.
        SET result["DIST"] TO geoDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
    }
    REMOVE nd.
    RETURN result.
}

LOCAL FUNCTION _deorbitVNewFast {
    PARAMETER entryPe.
    PARAMETER bodyR.
    PARAMETER mu.
    PARAMETER orbitSma.
    PARAMETER twoOverOrbitSma.

    LOCAL rPe IS bodyR + entryPe.
    LOCAL tSMA IS (orbitSma + rPe) / 2.
    LOCAL radicand IS twoOverOrbitSma - 1 / tSMA.
    IF radicand <= 0 { RETURN 0. }
    RETURN SQRT(mu * radicand).
}

LOCAL FUNCTION _planDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER bodyR.
    PARAMETER mu.
    PARAMETER orbitSma.
    PARAMETER twoOverOrbitSma.

    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS _deorbitVNewFast(entryPe, bodyR, mu, orbitSma,
        twoOverOrbitSma).
    LOCAL nd IS NODE(burnUT, 0, 0, vNew - vNow).
    ADD nd.
    RETURN nd.
}

LOCAL FUNCTION _targetDeorbitMinLead {
    LOCAL minLead IS 60.
    IF CFG:HASKEY("TARGET_DEORBIT_MIN_LEAD") {
        SET minLead TO CFG["TARGET_DEORBIT_MIN_LEAD"].
    }
    RETURN minLead.
}

GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.
}
