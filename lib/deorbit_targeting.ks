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

LOCAL FUNCTION _deorbitAngleErr {
    PARAMETER actual.
    PARAMETER wanted.
    LOCAL err IS MOD(actual - wanted + 540, 360) - 180.
    RETURN err.
}

GLOBAL FUNCTION targetedDeorbitAt {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER ignoredPe IS 0.
    PARAMETER ignoredTolerance IS 0.
    PARAMETER ignoredOvershoot IS 0.

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
    LOCAL targetPe IS targetGeo:TERRAINHEIGHT.
    LOCAL targetTolerance IS 10000.
    IF ADDONS:TR:AVAILABLE {
        ADDONS:TR:SETTARGET(targetGeo).
        mLog("Trajectories target set to landing site.").
    }

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
        + "  flyoverPe=" + ROUND(targetPe/1000,1) + "km"
        + "  flyoverTol=" + ROUND(targetTolerance/1000,1) + "km").
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL scanOrbits IS 32.
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
    LOCAL minLead IS _targetDeorbitMinLead().
    LOCAL searchStart IS nowUt + minLead.
    LOCAL searchEnd IS nowUt + period * scanOrbits + 30.
    LOCAL solution IS _deorbitSolveFlyover(
        targetLat, targetLng, targetPe,
        searchStart, searchEnd, period, bodyR, mu, targetTolerance).
    IF NOT solution["VALID"] {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    LOCAL bestUT IS solution["UT"].
    LOCAL bestDist IS solution["DIST"].
    LOCAL bestRad IS 0.
    LOCAL bestNor IS 0.
    mLog("Direct flyover solve: T+" + ROUND(bestUT - nowUt,0)
        + "s  fall=" + ROUND(solution["FALL"],0)
        + "s  rot=" + ROUND(solution["ROT"],1)
        + "deg  flyover=" + ROUND(solution["LAT"],4)
        + "," + ROUND(solution["LNG"],4)
        + "  dist=" + ROUND(bestDist/1000,1) + "km").
    LOCAL seedRetroDv IS _deorbitRetroDvForPe(bestUT, targetPe, bodyR, mu).
    LOCAL gateAlt IS targetGeo:TERRAINHEIGHT + 8000.
    LOCAL opt IS _deorbitOptimizeGate(bestUT, seedRetroDv,
        targetLat, targetLng, gateAlt,
        searchStart, searchEnd, period).
    IF NOT opt["VALID"] {
        mLogError("Gate optimizer failed to find a safe 8km target crossing.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    SET bestUT TO opt["UT"].
    SET bestDist TO opt["DIST"].
    LOCAL bestRetroDv IS opt["DV"].
    mLog("Gate optimizer: T+" + ROUND(bestUT - nowUt,0)
        + "s  retroDv=" + ROUND(bestRetroDv,1)
        + "m/s  gateDist=" + ROUND(bestDist/1000,2)
        + "km  fpa=" + ROUND(opt["FPA"],1)
        + "deg  cost=" + ROUND(opt["COST"],2) + ".").
    _deorbitLogTrajectoryDiagnostic(bestUT, bestRetroDv, bestRad, bestNor,
        targetLat, targetLng).

    IF bestDist > targetTolerance {
        mLogWarn("Best solution misses target flyover by " + ROUND(bestDist/1000,1)
            + "km — exceeds tolerance of " + ROUND(targetTolerance/1000,1) + "km.").
        HUDTEXT("Warning: " + ROUND(bestDist/1000,0) + "km from target flyover", 5, 2, 14, YELLOW, FALSE).
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }

    IF bestUT <= TIME:SECONDS + minLead {
        RETURN FALSE.
    }

    LOCAL realNode IS _planRetroNode(bestUT, bestRetroDv, bestRad, bestNor).
    IF LAND_CFG_TERRAIN_VALIDATE {
        WAIT 0.1.
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
        LOCAL impactAngle IS lmTerrainImpactAngle(
            bestUT + 30, bestUT + 1800,
            2,
            LAND_CFG_TERRAIN_MIN_CLEARANCE,
            LAND_CFG_TERRAIN_SAFE_ALT).
        IF impactAngle >= 0
                AND impactAngle < LAND_CFG_TERRAIN_MIN_DESCENT_ANGLE {
            mLogError("TERRAIN CHECK FAILED: descent angle "
                + ROUND(impactAngle,1) + "deg is below "
                + ROUND(LAND_CFG_TERRAIN_MIN_DESCENT_ANGLE,1) + "deg.").
            REMOVE realNode.
            RETURN FALSE.
        }
        IF impactAngle >= 0 {
            mLog("Terrain check passed. Descent angle="
                + ROUND(impactAngle,1) + "deg.").
        } ELSE {
            mLog("Terrain check passed. No low-clearance angle sample.").
        }
    }
    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    archiveLog().
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s", 3, 2, 13, CYAN, FALSE).
    IF ADDONS:TR:AVAILABLE {
        ADDONS:TR:SETTARGET(targetGeo).
        mLog("Trajectories visualizer pause before burn.").
        WAIT 5.
    }

    // executeDeorbitNode is supplied by deorbit_burn in the LAND_DEORBIT band.
    executeDeorbitNode(realNode).

    WAIT 2.
    LOCAL flyUt IS TIME:SECONDS + ETA:PERIAPSIS.
    LOCAL flyGeo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, flyUt)).
    LOCAL flyDist IS geoDistance(flyGeo:LAT, flyGeo:LNG, targetLat, targetLng).
    mLog("Post-burn flyover prediction: "
        + ROUND(flyGeo:LAT,4) + "," + ROUND(flyGeo:LNG,4)
        + "  dist=" + ROUND(flyDist/1000,1) + "km"
        + "  PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)).
    HUDTEXT("Flyover predicted " + ROUND(flyDist/1000,1) + "km from target",
        5, 2, 14, GREEN, FALSE).
    // The burn fired; the next phase owns the powered descent.
    RETURN TRUE.
}

LOCAL FUNCTION _deorbitSolveFlyover {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER targetPe.
    PARAMETER startUt.
    PARAMETER endUt.
    PARAMETER period.
    PARAMETER bodyR.
    PARAMETER mu.
    PARAMETER stopDist IS 10000.

    LOCAL best IS LEXICON("VALID", FALSE, "DIST", 999999999).
    LOCAL orbitIdx IS 0.
    LOCAL phaseOffsets IS LIST(0, period * 0.5).

    UNTIL startUt + orbitIdx * period > endUt {
        LOCAL orbitStart IS startUt + orbitIdx * period.
        FOR phaseOffset IN phaseOffsets {
            LOCAL windowStart IS orbitStart + phaseOffset.
            LOCAL windowEnd IS MIN(endUt, windowStart + period * 0.5).
            IF windowStart <= endUt {
                LOCAL seedUt IS _deorbitSeedFlyover(windowStart, windowEnd,
                    targetLat, targetLng, targetPe, period, bodyR, mu).
                LOCAL info IS _deorbitRefineFlyover(seedUt,
                    targetLat, targetLng, targetPe,
                    windowStart, windowEnd, period, bodyR, mu).
                IF info["VALID"] AND info["DIST"] < best["DIST"] {
                    SET best TO info.
                    IF best["DIST"] <= stopDist {
                        RETURN best.
                    }
                }
            }
        }
        SET orbitIdx TO orbitIdx + 1.
        WAIT 0.
    }
    RETURN best.
}

LOCAL FUNCTION _deorbitSeedFlyover {
    PARAMETER orbitStart.
    PARAMETER orbitEnd.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER targetPe.
    PARAMETER period.
    PARAMETER bodyR.
    PARAMETER mu.

    LOCAL base IS _deorbitPredictFlyover(orbitStart, targetLat, targetLng,
        targetPe, bodyR, mu).
    IF NOT base["VALID"] { RETURN orbitStart. }
    LOCAL probeStep IS MIN(300, MAX(20, period / 16)).
    LOCAL probeUt IS MIN(orbitEnd, orbitStart + probeStep).
    IF probeUt <= orbitStart { RETURN orbitStart. }
    LOCAL probe IS _deorbitPredictFlyover(probeUt, targetLat, targetLng,
        targetPe, bodyR, mu).
    IF NOT probe["VALID"] { RETURN orbitStart. }

    LOCAL lngRate IS _deorbitAngleErr(probe["LNG"], base["LNG"])
        / (probeUt - orbitStart).
    IF ABS(lngRate) < 0.0001 { RETURN orbitStart. }

    LOCAL seedUt IS orbitStart
        - _deorbitAngleErr(base["LNG"], targetLng) / lngRate.
    UNTIL seedUt >= orbitStart {
        SET seedUt TO seedUt + period.
    }
    UNTIL seedUt <= orbitEnd {
        SET seedUt TO seedUt - period.
    }
    RETURN MAX(orbitStart, MIN(orbitEnd, seedUt)).
}

LOCAL FUNCTION _deorbitRefineFlyover {
    PARAMETER seedUt.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER targetPe.
    PARAMETER startUt.
    PARAMETER endUt.
    PARAMETER period.
    PARAMETER bodyR.
    PARAMETER mu.

    LOCAL burnUT IS MAX(startUt, MIN(endUt, seedUt)).
    IF burnUT > endUt { RETURN LEXICON("VALID", FALSE, "DIST", 999999999). }

    LOCAL iter IS 0.
    LOCAL info IS _deorbitPredictFlyover(burnUT, targetLat, targetLng,
        targetPe, bodyR, mu).
    UNTIL iter >= 5 {
        IF NOT info["VALID"] { RETURN info. }
        LOCAL lngErr IS _deorbitAngleErr(info["LNG"], targetLng).
        IF ABS(lngErr) < 0.01 { BREAK. }
        LOCAL rateStep IS 20.
        LOCAL rateUT IS MIN(endUt, burnUT + rateStep).
        IF rateUT = burnUT AND burnUT - rateStep >= startUt {
            SET rateUT TO burnUT - rateStep.
        }
        IF rateUT = burnUT { BREAK. }
        LOCAL nextInfo IS _deorbitPredictFlyover(rateUT,
            targetLat, targetLng, targetPe, bodyR, mu).
        IF NOT nextInfo["VALID"] { BREAK. }
        LOCAL lngRate IS _deorbitAngleErr(nextInfo["LNG"], info["LNG"])
            / (rateUT - burnUT).
        IF ABS(lngRate) < 0.0001 { BREAK. }
        SET burnUT TO MAX(startUt, MIN(endUt, burnUT - lngErr / lngRate)).
        IF burnUT > endUt { BREAK. }
        SET info TO _deorbitPredictFlyover(burnUT, targetLat, targetLng,
            targetPe, bodyR, mu).
        SET iter TO iter + 1.
    }
    IF burnUT < startUt OR burnUT > endUt {
        RETURN LEXICON("VALID", FALSE, "DIST", 999999999).
    }
    RETURN _deorbitPredictFlyover(burnUT, targetLat, targetLng,
        targetPe, bodyR, mu).
}

LOCAL FUNCTION _deorbitPredictFlyover {
    PARAMETER burnUT.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER targetPe.
    PARAMETER bodyR.
    PARAMETER mu.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "DIST", 999999999,
        "LAT", 0,
        "LNG", 0,
        "UT", burnUT,
        "ALT", 0,
        "FALL", 0,
        "ROT", 0
    ).
    LOCAL bdy IS SHIP:BODY.
    LOCAL burnRel IS POSITIONAT(SHIP, burnUT) - POSITIONAT(bdy, burnUT).
    LOCAL burnRad IS burnRel:MAG.
    IF burnRad > bdy:SOIRADIUS {
        SET burnRad TO SHIP:ORBIT:SEMIMAJORAXIS.
    }
    LOCAL peRad IS bodyR + targetPe.
    IF burnRad <= 0 OR peRad <= 0 { RETURN result. }
    LOCAL transferSma IS (burnRad + peRad) / 2.
    IF transferSma <= 0 { RETURN result. }
    LOCAL fallSec IS CONSTANT:PI
        * SQRT((transferSma * transferSma * transferSma) / mu).
    LOCAL flyUt IS burnUT + fallSec.
    LOCAL flyRel IS burnRel:NORMALIZED * (-peRad).
    LOCAL geo IS bdy:GEOPOSITIONOF(POSITIONAT(bdy, flyUt) + flyRel).
    LOCAL rotDeg IS 0.
    IF bdy:ROTATIONPERIOD <> 0 {
        SET rotDeg TO 360 * fallSec / bdy:ROTATIONPERIOD.
    }
    SET result["VALID"] TO TRUE.
    SET result["LAT"] TO geo:LAT.
    SET result["LNG"] TO geo:LNG.
    SET result["UT"] TO burnUT.
    SET result["ALT"] TO targetPe.
    SET result["FALL"] TO fallSec.
    SET result["ROT"] TO rotDeg.
    SET result["DIST"] TO geoDistance(geo:LAT, geo:LNG, targetLat, targetLng).
    RETURN result.
}

LOCAL FUNCTION _deorbitOptimizeGate {
    PARAMETER seedUT.
    PARAMETER seedRetroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER gateAlt.
    PARAMETER startUt.
    PARAMETER endUt.
    PARAMETER period.

    LOCAL burnUT IS MAX(startUt, MIN(endUt, seedUT)).
    LOCAL retroDv IS MAX(0.1, seedRetroDv).
    LOCAL tStep IS MIN(300, MAX(30, period / 16)).
    LOCAL dvStep IS MAX(1, retroDv * 0.15).
    LOCAL best IS _deorbitEvalGate(burnUT, retroDv, targetLat, targetLng,
        gateAlt).
    LOCAL iter IS 0.

    UNTIL iter >= 5 {
        LOCAL posBest IS best.
        FOR candUT IN LIST(MAX(startUt, burnUT - tStep),
                MIN(endUt, burnUT + tStep)) {
            LOCAL cand IS _deorbitEvalGate(candUT, retroDv,
                targetLat, targetLng, gateAlt).
            IF cand["VALID"] AND cand["DIST_COST"] < posBest["DIST_COST"] {
                SET posBest TO cand.
            }
        }
        IF posBest["VALID"] {
            SET burnUT TO posBest["UT"].
            SET best TO posBest.
        }

        LOCAL angleBest IS best.
        FOR candDv IN LIST(MAX(0.1, retroDv - dvStep), retroDv + dvStep) {
            LOCAL cand IS _deorbitEvalGate(burnUT, candDv,
                targetLat, targetLng, gateAlt).
            IF cand["VALID"] AND cand["ANGLE_COST"] < angleBest["ANGLE_COST"] {
                SET angleBest TO cand.
            }
        }
        IF angleBest["VALID"] {
            SET retroDv TO angleBest["DV"].
            SET best TO angleBest.
        }

        SET tStep TO tStep / 2.
        SET dvStep TO MAX(0.25, dvStep / 2).
        SET iter TO iter + 1.
        WAIT 0.
    }

    RETURN _deorbitEvalGate(burnUT, retroDv, targetLat, targetLng,
        gateAlt).
}

LOCAL FUNCTION _deorbitEvalGate {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER gateAlt.

    LOCAL penalty IS LEXICON(
        "VALID", FALSE,
        "COST", 999999999,
        "DIST_COST", 999999999,
        "ANGLE_COST", 999999999,
        "DIST", 999999999,
        "FPA", 0,
        "UT", burnUT,
        "DV", retroDv
    ).

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planRetroNode(burnUT, retroDv).
    WAIT 0.1.

    IF LAND_CFG_TERRAIN_VALIDATE {
        LOCAL crashDist IS lmTerrainClearanceCheck(
            targetLat, targetLng,
            burnUT + 30, burnUT + 1800,
            5,
            LAND_CFG_TERRAIN_MIN_CLEARANCE,
            LAND_CFG_TERRAIN_SAFE_ALT).
        IF crashDist > LAND_CFG_TERRAIN_MAX_CRASH_DIST {
            REMOVE nd.
            RETURN penalty.
        }
    }

    LOCAL gate IS _deorbitGateCrossing(targetLat, targetLng,
        gateAlt, burnUT + 30, burnUT + 1800, 5).
    REMOVE nd.
    IF NOT gate["VALID"] { RETURN penalty. }

    LOCAL distCost IS (gate["DIST"] / 500) * (gate["DIST"] / 500).
    LOCAL angleCost IS ((gate["FPA"] - 30) / 5) * ((gate["FPA"] - 30) / 5).
    SET gate["COST"] TO distCost + angleCost.
    SET gate["DIST_COST"] TO distCost.
    SET gate["ANGLE_COST"] TO angleCost.
    SET gate["DV"] TO retroDv.
    RETURN gate.
}

LOCAL FUNCTION _deorbitGateCrossing {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER gateAlt.
    PARAMETER startUt.
    PARAMETER endUt.
    PARAMETER stepSec.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "COST", 999999999,
        "DIST_COST", 999999999,
        "ANGLE_COST", 999999999,
        "DIST", 999999999,
        "FPA", 0,
        "UT", startUt,
        "DV", 0
    ).
    LOCAL bdy IS SHIP:BODY.
    LOCAL bodyR IS bdy:RADIUS.
    LOCAL gateR IS bodyR + gateAlt.
    LOCAL prevUt IS startUt.
    LOCAL prevPos IS POSITIONAT(SHIP, prevUt).
    LOCAL prevRad IS (prevPos - POSITIONAT(bdy, prevUt)):MAG.
    LOCAL sampleUt IS startUt + stepSec.

    UNTIL sampleUt > endUt {
        LOCAL pos IS POSITIONAT(SHIP, sampleUt).
        LOCAL rad IS (pos - POSITIONAT(bdy, sampleUt)):MAG.
        IF prevRad > gateR AND rad <= gateR AND rad < prevRad {
            LOCAL frac IS (prevRad - gateR) / MAX(0.001, prevRad - rad).
            LOCAL gateUt IS prevUt + frac * stepSec.
            LOCAL gatePos IS POSITIONAT(SHIP, gateUt).
            LOCAL gateRel IS gatePos - POSITIONAT(bdy, gateUt).
            LOCAL geo IS bdy:GEOPOSITIONOF(gatePos).
            LOCAL beforeRel IS POSITIONAT(SHIP, gateUt - 1)
                - POSITIONAT(bdy, gateUt - 1).
            LOCAL afterRel IS POSITIONAT(SHIP, gateUt + 1)
                - POSITIONAT(bdy, gateUt + 1).
            LOCAL velVec IS (afterRel - beforeRel) / 2.
            LOCAL upVec IS gateRel:NORMALIZED.
            LOCAL downRate IS -VDOT(velVec, upVec).
            LOCAL sideRate IS VXCL(upVec, velVec):MAG.
            LOCAL fpa IS 90.
            IF sideRate >= 0.01 {
                SET fpa TO ARCTAN2(downRate, sideRate).
            }
            IF downRate <= 0 {
                RETURN result.
            }
            SET result["VALID"] TO TRUE.
            SET result["UT"] TO gateUt.
            SET result["FPA"] TO fpa.
            SET result["DIST"] TO geoDistance(geo:LAT, geo:LNG,
                targetLat, targetLng).
            RETURN result.
        }
        SET prevUt TO sampleUt.
        SET prevRad TO rad.
        SET sampleUt TO sampleUt + stepSec.
    }

    RETURN result.
}

LOCAL FUNCTION _deorbitLogTrajectoryDiagnostic {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER radialDv.
    PARAMETER normalDv.
    PARAMETER targetLat.
    PARAMETER targetLng.

    IF NOT ADDONS:TR:AVAILABLE {
        mLogWarn("TR diag: Trajectories unavailable.").
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planRetroNode(burnUT, retroDv, radialDv, normalDv).
    ADDONS:TR:SETTARGET(LATLNG(targetLat, targetLng)).
    WAIT 0.5.

    LOCAL nodePe IS nd:ORBIT:PERIAPSIS.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL trDist IS geoDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
        mLog("TR diag: nodePe=" + ROUND(nodePe/1000,1)
            + "km  impact=" + ROUND(impactPos:LAT,4)
            + "," + ROUND(impactPos:LNG,4)
            + "  dist=" + ROUND(trDist/1000,1) + "km.").
    } ELSE {
        mLog("TR diag: nodePe=" + ROUND(nodePe/1000,1)
            + "km  no impact predicted.").
    }
    REMOVE nd.
}



LOCAL FUNCTION _targetDeorbitMinLead {
    LOCAL minLead IS 60.
    IF CFG:HASKEY("TARGET_DEORBIT_MIN_LEAD") {
        SET minLead TO CFG["TARGET_DEORBIT_MIN_LEAD"].
    }
    RETURN minLead.
}

LOCAL FUNCTION _deorbitRetroDvForPe {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER bodyR IS -1.
    PARAMETER mu IS -1.

    IF bodyR < 0 { SET bodyR TO SHIP:ORBIT:BODY:RADIUS. }
    IF mu < 0 { SET mu TO SHIP:ORBIT:BODY:MU. }
    LOCAL burnRad IS (POSITIONAT(SHIP, burnUT) - POSITIONAT(SHIP:BODY, burnUT)):MAG.
    IF burnRad > SHIP:BODY:SOIRADIUS {
        SET burnRad TO SHIP:ORBIT:SEMIMAJORAXIS.
    }
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL rPe IS bodyR + entryPe.
    LOCAL tSMA IS (burnRad + rPe) / 2.
    LOCAL radicand IS 2 / burnRad - 1 / tSMA.
    IF radicand <= 0 { RETURN 0. }
    LOCAL vNew IS SQRT(mu * radicand).
    RETURN MAX(0, vNow - vNew).
}

LOCAL FUNCTION _planRetroNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER radialDv IS 0.
    PARAMETER normalDv IS 0.

    LOCAL nd IS NODE(burnUT, radialDv, normalDv, -ABS(retroDv)).
    ADD nd.
    RETURN nd.
}

GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.
}
