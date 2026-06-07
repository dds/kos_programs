// ============================================================
// targeting.ks  —  Precision deorbit targeting  (0:/lib/targeting.ks)
// ============================================================

GLOBAL FUNCTION targetedDeorbit {
    LOCAL entryPe   IS 30000.
    IF CFG:HASKEY("PROBE_ENTRY_PE") { SET entryPe TO CFG["PROBE_ENTRY_PE"]. }
    LOCAL tolerance IS 5000.
    IF CFG:HASKEY("PROBE_TARGET_TOL") { SET tolerance TO CFG["PROBE_TARGET_TOL"]. }

    LOCAL targetInfo IS targetResolveDeorbitTarget().
    IF NOT targetInfo["FOUND"] {
        mLogError("No deorbit target set. Configure PROBE_TARGET_LAT/LNG or select a waypoint.").
        RETURN FALSE.
    }

    mLog("Deorbit target source: " + targetInfo["SOURCE"] + ".").
    RETURN targetedDeorbitAt(targetInfo["LAT"], targetInfo["LNG"], entryPe, tolerance).
}

GLOBAL FUNCTION targetResolveDeorbitTarget {
    LOCAL result IS LEXICON(
        "FOUND", FALSE,
        "LAT", 0,
        "LNG", 0,
        "SOURCE", "none"
    ).

    IF CFG:HASKEY("PROBE_TARGET_WAYPOINT") AND CFG["PROBE_TARGET_WAYPOINT"] <> "" {
        LOCAL namedWp IS _targetWaypointNamed(CFG["PROBE_TARGET_WAYPOINT"]).
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

    LOCAL selectedWp IS _targetSelectedWaypoint().
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
    PARAMETER entryPe IS 30000.
    PARAMETER tolerance IS 5000.

    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available — cannot guarantee targeted deorbit.").
        RETURN FALSE.
    }

    IF NOT targetReachable(targetLat) {
        mLogWarn("STATS deorbit abort reason=target-lat-unreachable targetLat="
            + ROUND(targetLat,4)
            + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
        mLogError("Target latitude is not reachable from this orbit inclination.").
        RETURN FALSE.
    }

    LOCAL site IS _selectScanSatLandingSite(targetLat, targetLng).
    IF site["FOUND"] {
        SET targetLat TO site["LAT"].
        SET targetLng TO site["LNG"].
    }

    LOCAL targetGeo IS LATLNG(targetLat, targetLng).
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
        + "  entryPe=" + ROUND(entryPe/1000,1) + "km"
        + "  tolerance=" + ROUND(tolerance/1000,1) + "km").
    mLogWarn("STATS deorbit setup target=" + ROUND(targetLat,4)
        + "," + ROUND(targetLng,4)
        + " entryPeKm=" + ROUND(entryPe/1000,1)
        + " toleranceKm=" + ROUND(tolerance/1000,1)).
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL scanOrbits IS 32.
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_ORBITS") {
        SET scanOrbits TO CFG["TARGET_DEORBIT_SCAN_ORBITS"].
    }
    LOCAL scanSamples IS 384.
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_SAMPLES") {
        SET scanSamples TO CFG["TARGET_DEORBIT_SCAN_SAMPLES"].
    }
    LOCAL scanStep IS period * scanOrbits / scanSamples.
    LOCAL passes    IS LIST(1.0, 0.1, 0.01, 0.001, 0.0001).

    LOCAL bestUT   IS TIME:SECONDS + 30.
    LOCAL bestPe   IS entryPe.
    LOCAL bestDist IS 999999999.
    LOCAL validSamples IS 0.
    LOCAL invalidSamples IS 0.

    LOCAL scanUT  IS TIME:SECONDS + 30.
    LOCAL scanEnd IS TIME:SECONDS + period * scanOrbits + 30.
    mLog("Coarse target scan: " + scanSamples + " samples over "
        + ROUND(scanOrbits,1) + " orbits.").
    UNTIL scanUT > scanEnd {
        LOCAL trial IS _evalDeorbitNode(scanUT, entryPe, targetLat, targetLng).
        IF trial["VALID"] {
            SET validSamples TO validSamples + 1.
            IF trial["DIST"] < bestDist {
                SET bestDist TO trial["DIST"].
                SET bestUT   TO scanUT.
                SET bestPe   TO entryPe.
                mLog("DEBUG coarse: T+" + ROUND(scanUT - TIME:SECONDS,0)
                    + "s  dist=" + ROUND(bestDist/1000,1) + "km"
                    + " impact=" + ROUND(trial["LAT"],4)
                    + "," + ROUND(trial["LNG"],4)).
            }
        } ELSE {
            SET invalidSamples TO invalidSamples + 1.
        }
        SET scanUT TO scanUT + scanStep.
        WAIT 0.1.
    }
    mLog("Coarse best: T+" + ROUND(bestUT - TIME:SECONDS,0)
        + "s  dist=" + ROUND(bestDist/1000,1) + "km").
    LOCAL coarseBest IS _evalDeorbitNode(bestUT, bestPe, targetLat, targetLng).
    mLogWarn("STATS deorbit coarse distKm=" + ROUND(bestDist/1000,1)
        + " burnT=" + ROUND(bestUT - TIME:SECONDS,0)
        + " scanOrbits=" + scanOrbits
        + " samples=" + scanSamples
        + " valid=" + validSamples
        + " invalid=" + invalidSamples
        + " impact=" + ROUND(coarseBest["LAT"],4)
        + "," + ROUND(coarseBest["LNG"],4)).

    FOR mult IN passes:SUBLIST(1, passes:LENGTH - 1) {
        LOCAL step    IS scanStep * mult.
        LOCAL winStart IS bestUT - (scanStep * (mult * 10)).
        LOCAL winEnd   IS bestUT + (scanStep * (mult * 10)).
        LOCAL passUT   IS winStart.
        LOCAL passBest IS bestDist.
        LOCAL passBestUT IS bestUT.
        LOCAL passBestPe IS bestPe.

        UNTIL passUT > winEnd {
            LOCAL trial IS _evalDeorbitNode(passUT, bestPe, targetLat, targetLng).
            IF trial["VALID"] AND trial["DIST"] < passBest {
                SET passBest   TO trial["DIST"].
                SET passBestUT TO passUT.
                SET passBestPe TO bestPe.
            }
            SET passUT TO passUT + step.
            WAIT 0.05.
        }

        SET bestDist TO passBest.
        SET bestUT   TO passBestUT.
        SET bestPe   TO passBestPe.
        mLog("Pass step=" + ROUND(step,2) + "s  best dist=" + ROUND(bestDist,0) + "m"
            + "  T+" + ROUND(bestUT - TIME:SECONDS,0) + "s").

        IF bestDist < tolerance { BREAK. }
    }

    LOCAL refined IS _refineDeorbitImpact(
        bestUT, bestPe, targetLat, targetLng, tolerance, scanStep).
    IF refined["VALID"] AND refined["DIST"] < bestDist {
        SET bestUT TO refined["UT"].
        SET bestPe TO refined["PE"].
        SET bestDist TO refined["DIST"].
    }

    mLog("Fine best: T+" + ROUND(bestUT - TIME:SECONDS,0)
        + "s  Pe=" + ROUND(bestPe/1000,1) + "km"
        + "  dist=" + ROUND(bestDist/1000,1) + "km").
    LOCAL deorbitStatus IS "ok".
    IF bestDist > tolerance { SET deorbitStatus TO "miss". }
    LOCAL finalEval IS _evalDeorbitNode(bestUT, bestPe, targetLat, targetLng).
    mLogWarn("STATS deorbit final status=" + deorbitStatus
        + " distKm=" + ROUND(bestDist/1000,1)
        + " toleranceKm=" + ROUND(tolerance/1000,1)
        + " burnT=" + ROUND(bestUT - TIME:SECONDS,0)
        + " PeKm=" + ROUND(bestPe/1000,1)
        + " impact=" + ROUND(finalEval["LAT"],4)
        + "," + ROUND(finalEval["LNG"],4)).

    IF bestDist > tolerance {
        mLogWarn("Best solution misses target by " + ROUND(bestDist/1000,1)
            + "km — exceeds tolerance of " + ROUND(tolerance/1000,1) + "km.").
        HUDTEXT("Warning: " + ROUND(bestDist/1000,0) + "km from target", 5, 2, 14, YELLOW, FALSE).
        LOCAL proceedOnMiss IS 0.
        IF CFG:HASKEY("TARGET_DEORBIT_PROCEED_ON_MISS") {
            SET proceedOnMiss TO CFG["TARGET_DEORBIT_PROCEED_ON_MISS"].
        }
        IF proceedOnMiss <= 0 {
            mLogWarn("STATS deorbit abort reason=miss-exceeds-tolerance distKm="
                + ROUND(bestDist/1000,1)
                + " toleranceKm=" + ROUND(tolerance/1000,1)).
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            RETURN FALSE.
        }
        mLogWarn("Proceeding anyway — check orbital inclination vs target latitude.").
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }

    LOCAL realNode IS _planDeorbitNode(bestUT, bestPe).
    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    archivePlannedManeuverLog("targeted-deorbit").
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s", 3, 2, 13, CYAN, FALSE).

    executeManeuver().

    WAIT 2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL finalDist IS _geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).
        mLog("Post-burn impact prediction: "
            + ROUND(impactPos:LAT,4) + "," + ROUND(impactPos:LNG,4)
            + "  dist=" + ROUND(finalDist/1000,1) + "km from target").
        mLogWarn("STATS deorbit postburn distKm=" + ROUND(finalDist/1000,1)
            + " impact=" + ROUND(impactPos:LAT,4)
            + "," + ROUND(impactPos:LNG,4)).
        HUDTEXT("Impact predicted " + ROUND(finalDist/1000,1) + "km from target",
            5, 2, 14, GREEN, FALSE).
        IF finalDist > tolerance {
            mLogWarn("STATS deorbit postburn status=miss distKm="
                + ROUND(finalDist/1000,1)
                + " toleranceKm=" + ROUND(tolerance/1000,1)).
            RETURN FALSE.
        }
    } ELSE {
        mLogWarn("Trajectories has no impact prediction post-burn.").
        RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _testDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL result IS _evalDeorbitNode(burnUT, entryPe, targetLat, targetLng).
    IF NOT result["VALID"] { RETURN -1. }
    RETURN result["DIST"].
}

LOCAL FUNCTION _selectScanSatLandingSite {
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL out IS LEXICON(
        "FOUND", FALSE,
        "LAT", targetLat,
        "LNG", targetLng,
        "SLOPE", -1,
        "ELEV", -1,
        "DIST", 0
    ).

    LOCAL enabled IS 0.
    IF CFG:HASKEY("LANDING_SITE_SCAN_ENABLE") {
        SET enabled TO CFG["LANDING_SITE_SCAN_ENABLE"].
    }
    IF enabled <= 0 { RETURN out. }

    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("STATS site-scan status=no-scansat target="
            + ROUND(targetLat,4) + "," + ROUND(targetLng,4)).
        RETURN out.
    }

    LOCAL radius IS 1000.
    IF CFG:HASKEY("LANDING_SITE_SCAN_RADIUS") {
        SET radius TO CFG["LANDING_SITE_SCAN_RADIUS"].
    }
    LOCAL step IS 250.
    IF CFG:HASKEY("LANDING_SITE_SCAN_STEP") {
        SET step TO CFG["LANDING_SITE_SCAN_STEP"].
    }
    LOCAL maxSlope IS 12.
    IF CFG:HASKEY("LANDING_SITE_MAX_SLOPE") {
        SET maxSlope TO CFG["LANDING_SITE_MAX_SLOPE"].
    }

    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(targetLat)).
    LOCAL bestScore IS 999999999.
    LOCAL samples IS 0.
    LOCAL known IS 0.
    LOCAL rejectedSlope IS 0.

    FROM { LOCAL north_ IS -radius. } UNTIL north_ > radius STEP { SET north_ TO north_ + step. } DO {
        FROM { LOCAL east_ IS -radius. } UNTIL east_ > radius STEP { SET east_ TO east_ + step. } DO {
            LOCAL candLat IS targetLat + north_ * degPerM.
            LOCAL candLng IS targetLng + east_ * degPerM / lonScale.
            LOCAL candGeo IS LATLNG(candLat, candLng).
            SET samples TO samples + 1.

            LOCAL elev IS ADDONS:SCANSAT:ELEVATION(SHIP:BODY, candGeo).
            IF elev >= 0 {
                SET known TO known + 1.
                LOCAL slope IS ADDONS:SCANSAT:SLOPE(SHIP:BODY, candGeo).
                IF slope >= 0 AND slope <= maxSlope {
                    LOCAL dist IS SQRT(north_^2 + east_^2).
                    LOCAL score IS dist / 100 + slope * 25.
                    IF score < bestScore {
                        SET bestScore TO score.
                        SET out["FOUND"] TO TRUE.
                        SET out["LAT"] TO candLat.
                        SET out["LNG"] TO candLng.
                        SET out["SLOPE"] TO slope.
                        SET out["ELEV"] TO elev.
                        SET out["DIST"] TO dist.
                    }
                } ELSE {
                    SET rejectedSlope TO rejectedSlope + 1.
                }
            }
        }
        WAIT 0.01.
    }

    IF out["FOUND"] {
        mLogWarn("STATS site-scan result status=selected target="
            + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
            + " selected=" + ROUND(out["LAT"],4) + "," + ROUND(out["LNG"],4)
            + " distM=" + ROUND(out["DIST"],0)
            + " slope=" + ROUND(out["SLOPE"],1)
            + " elev=" + ROUND(out["ELEV"],0)
            + " samples=" + samples
            + " known=" + known
            + " rejectedSlope=" + rejectedSlope).
    } ELSE {
        mLogWarn("STATS site-scan result status=no-site target="
            + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
            + " radiusM=" + ROUND(radius,0)
            + " stepM=" + ROUND(step,0)
            + " maxSlope=" + ROUND(maxSlope,1)
            + " samples=" + samples
            + " known=" + known
            + " rejectedSlope=" + rejectedSlope).
    }

    RETURN out.
}

LOCAL FUNCTION _evalDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "UT", burnUT,
        "PE", entryPe,
        "DIST", 999999999,
        "LAT", 0,
        "LNG", 0
    ).

    IF burnUT <= TIME:SECONDS + 10 { RETURN result. }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
    LOCAL nd IS _planDeorbitNode(burnUT, entryPe).
    WAIT 0.35.

    IF NOT ADDONS:TR:HASIMPACT {
        REMOVE nd.
        RETURN result.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    SET result["VALID"] TO TRUE.
    SET result["LAT"] TO impactPos:LAT.
    SET result["LNG"] TO impactPos:LNG.
    SET result["DIST"] TO _geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).

    REMOVE nd.
    RETURN result.
}

LOCAL FUNCTION _refineDeorbitImpact {
    PARAMETER startUT.
    PARAMETER startPe.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER tolerance.
    PARAMETER coarseStep.

    LOCAL best IS _evalDeorbitNode(startUT, startPe, targetLat, targetLng).
    IF NOT best["VALID"] { RETURN best. }

    LOCAL timeStep IS MAX(1, coarseStep / 4).
    LOCAL peStep IS 10000.
    LOCAL minPe IS MAX(-50000, -SHIP:BODY:RADIUS * 0.2).
    LOCAL maxPe IS MIN(SHIP:PERIAPSIS - 100, MAX(startPe + 60000, 10000)).
    LOCAL axes IS LIST("TIME", "PE", "BOTH").
    LOCAL signs IS LIST(1, -1).

    mLog("Refining deorbit: start dist=" + ROUND(best["DIST"]/1000,1)
        + "km  timeStep=" + ROUND(timeStep,1) + "s"
        + "  peStep=" + ROUND(peStep/1000,1) + "km.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= 24 STEP { SET iter TO iter + 1. } DO {
        LOCAL improved IS FALSE.
        LOCAL bestTrial IS best.

        FOR axis IN axes {
            FOR sign IN signs {
                LOCAL tryUT IS best["UT"].
                LOCAL tryPe IS best["PE"].

                IF axis = "TIME" OR axis = "BOTH" {
                    SET tryUT TO tryUT + sign * timeStep.
                }
                IF axis = "PE" OR axis = "BOTH" {
                    SET tryPe TO tryPe + sign * peStep.
                }

                IF tryPe >= minPe AND tryPe <= maxPe
                        AND tryUT > TIME:SECONDS + 10 {
                    LOCAL trial IS _evalDeorbitNode(tryUT, tryPe, targetLat, targetLng).
                    IF trial["VALID"] AND trial["DIST"] < bestTrial["DIST"] {
                        SET bestTrial TO trial.
                    }
                }
            }
        }

        IF bestTrial["DIST"] < best["DIST"] {
            SET best TO bestTrial.
            SET improved TO TRUE.
            mLog("  refine[" + iter + "] T+" + ROUND(best["UT"] - TIME:SECONDS,0)
                + "s Pe=" + ROUND(best["PE"]/1000,1) + "km"
                + " dist=" + ROUND(best["DIST"]/1000,2) + "km.").
        }

        IF best["DIST"] < tolerance { BREAK. }

        IF NOT improved {
            SET timeStep TO timeStep / 2.
            SET peStep TO peStep / 2.
            IF timeStep < 0.25 AND peStep < 100 { BREAK. }
        }
    }

    RETURN best.
}

LOCAL FUNCTION _planDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.

    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL oRad IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL rPe  IS SHIP:ORBIT:BODY:RADIUS + entryPe.
    LOCAL tSMA IS (oRad + rPe) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2/oRad - 1/tSMA)).
    LOCAL dv   IS vNew - vNow.

    LOCAL nd IS NODE(burnUT, 0, 0, dv).
    ADD nd.
    RETURN nd.
}

LOCAL FUNCTION _geoDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL oRad IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL dLat IS lat2 - lat1.
    LOCAL dLng IS lng2 - lng1.
    LOCAL a    IS SIN(dLat/2)^2
               + COS(lat1) * COS(lat2) * SIN(dLng/2)^2.
    LOCAL c    IS 2 * ARCSIN(MIN(1, SQRT(a))).
    RETURN oRad * c * CONSTANT:PI / 180.
}

LOCAL FUNCTION _targetWaypointNamed {
    PARAMETER waypointName.
    LOCAL allWps IS ALLWAYPOINTS().
    LOCAL targetName IS waypointName:TOUPPER.
    FOR wp IN allWps {
        IF wp:BODY:NAME = SHIP:BODY:NAME {
            IF wp:NAME:TOUPPER = targetName {
                RETURN wp.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _targetSelectedWaypoint {
    LOCAL allWps IS ALLWAYPOINTS().
    FOR wp IN allWps {
        IF wp:ISSELECTED {
            IF wp:BODY:NAME = SHIP:BODY:NAME {
                RETURN wp.
            }
        }
    }
    RETURN 0.
}

GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.
}
