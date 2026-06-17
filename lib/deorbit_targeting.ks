// ============================================================
// deorbit_targeting.ks  —  Precision deorbit targeting  (0:/lib/deorbit_targeting.ks)
// ============================================================

@CLOBBERBUILTINS ON.

// --- Config defaults owned by this file ---
GLOBAL PROBE_TARGET_WAYPOINT IS "".
GLOBAL PROBE_TARGET_LAT IS 90.
GLOBAL PROBE_TARGET_LNG IS 0.
GLOBAL TARGET_DEORBIT_SCAN_ORBITS IS 0.
GLOBAL TARGET_DEORBIT_SCAN_SAMPLES IS 128.
GLOBAL TARGET_DEORBIT_SCAN_CENTER_MINUTES IS 0.
GLOBAL TARGET_DEORBIT_SCAN_WINDOW_MINUTES IS 0.
GLOBAL TARGET_DEORBIT_MIN_LEAD IS 0.
GLOBAL LANDING_SIM_MODE IS 0.

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

    IF PROBE_TARGET_WAYPOINT <> "" {
        LOCAL namedWp IS waypointNamed(PROBE_TARGET_WAYPOINT).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Probe waypoint '" + PROBE_TARGET_WAYPOINT
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

    SET result["FOUND"] TO TRUE.
    SET result["LAT"] TO PROBE_TARGET_LAT.
    SET result["LNG"] TO PROBE_TARGET_LNG.
    SET result["SOURCE"] TO "PROBE_TARGET_LAT/LNG".
    RETURN result.
}

GLOBAL FUNCTION targetedDeorbitAt {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER overrideTolerance IS 0.
    PARAMETER overrideOvershoot IS 0.

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
    LOCAL tolerance IS TARGET_TOLERANCE.
    IF overrideTolerance > 0 { SET tolerance TO overrideTolerance. }
    LOCAL nodeGroundAngle IS 50.
    LOCAL desiredDownfield IS 15000.
    IF overrideOvershoot > 0 { SET desiredDownfield TO overrideOvershoot. }
    LOCAL minDownfield IS 10000.
    LOCAL maxDownfield IS 20000.
    LOCAL minRetroDv IS 2.
    LOCAL seedRetroDv IS 15.
    LOCAL maxRetroDv IS 50.
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + ","
        + ROUND(targetLng,4)
        + "  nodeAngle=" + ROUND(nodeGroundAngle,0) + "deg"
        + "  downfield=" + ROUND(desiredDownfield/1000,1) + "km"
        + " band=" + ROUND(minDownfield/1000,1)
        + "-" + ROUND(maxDownfield/1000,1) + "km.").
    HUDTEXT("Solving geometric deorbit...", 3, 2, 13, CYAN, FALSE).

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL minLead IS _targetDeorbitMinLead().
    LOCAL scanOrbits IS 8.
    IF TARGET_DEORBIT_SCAN_ORBITS > 0 {
        SET scanOrbits TO TARGET_DEORBIT_SCAN_ORBITS.
    }
    IF LANDING_SIM_MODE > 0 {
        IF scanOrbits > 2 { SET scanOrbits TO 2. }
    }

    LOCAL scanStart IS nowUt + minLead.
    LOCAL scanEnd IS nowUt + period * scanOrbits + 30.
    LOCAL stepA IS period / 128.
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL geometry IS _findDeorbitGeometryNode(targetLat, targetLng,
        scanStart, scanEnd, stepA, nodeGroundAngle).
    IF NOT geometry["VALID"] {
        mLogError("No deorbit node found at ground angle "
            + ROUND(nodeGroundAngle,0) + "deg from target.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    LOCAL bestUT IS geometry["UT"].
    mLog("Geometry node: T+" + ROUND(bestUT - nowUt,0)
        + "s angle=" + ROUND(geometry["ANGLE"],2)
        + " subpoint=" + ROUND(geometry["LAT"],4)
        + "," + ROUND(geometry["LNG"],4) + ".").

    LOCAL solved IS _solveGeometricDeorbitDv(bestUT, targetLat, targetLng,
        minLead, minRetroDv, maxRetroDv, seedRetroDv,
        desiredDownfield, minDownfield, maxDownfield).
    IF NOT solved["VALID"] {
        mLogError("No retrograde dV in " + ROUND(minRetroDv,1)
            + "-" + ROUND(maxRetroDv,1) + "m/s put TR impact "
            + ROUND(minDownfield/1000,1) + "-"
            + ROUND(maxDownfield/1000,1) + "km downfield.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    LOCAL bestRetroDv IS solved["DV"].
    LOCAL bestDist IS solved["DIST"].
    LOCAL bestAngle IS solved["ANGLE"].
    LOCAL bestDownfield IS solved["DOWNFIELD"].
    LOCAL bestPe IS solved["PE"].

    LOCAL solvedImpactText IS " impact=none".
    IF solved["HAS_IMPACT"] {
        SET solvedImpactText TO " impact=" + ROUND(solved["LAT"],4)
            + "," + ROUND(solved["LNG"],4)
            + " dist=" + ROUND(bestDist/1000,2) + "km"
            + " downfield=" + ROUND(bestDownfield/1000,2) + "km".
    }
    mLog("Solved deorbit: T+" + ROUND(bestUT - nowUt,0)
        + "s dv=" + ROUND(bestRetroDv,2)
        + solvedImpactText
        + " Pe=" + ROUND(bestPe/1000,2) + "km"
        + " fpa=" + ROUND(bestAngle,1) + ".").
    IF NOT solved["HAS_IMPACT"] {
        mLogError("Solved node has no Trajectories impact.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF bestDownfield < 0 {
        mLogError("Solved node impacts upfield of target: downfield="
            + ROUND(bestDownfield/1000,2) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF bestDownfield < minDownfield OR bestDownfield > maxDownfield {
        mLogError("Solved node impact is outside downfield band: "
            + ROUND(bestDownfield/1000,2) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF bestDist < minDownfield OR bestDist > maxDownfield {
        mLogError("Solved node impact is outside target-distance band: "
            + ROUND(bestDist/1000,2) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL realNode IS _planRetroNode(bestUT, bestRetroDv).
    _logDeorbitNode("Selected deorbit node", realNode).
    WAIT 0.5.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL trDist IS _targetDeorbitDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
        LOCAL trDownfield IS _targetDownfieldDistance(impactPos:LAT,
            impactPos:LNG, targetLat, targetLng, bestUT).
        mLog("TR final: impact=" + ROUND(impactPos:LAT,4)
            + "," + ROUND(impactPos:LNG,4)
            + " dist=" + ROUND(trDist/1000,2) + "km"
            + " downfield=" + ROUND(trDownfield/1000,2) + "km"
            + " Pe=" + ROUND(realNode:ORBIT:PERIAPSIS/1000,1) + "km.").
    } ELSE {
        mLogWarn("TR final: no impact predicted for selected node.").
    }

    IF TERRAIN_VALIDATE {
        LOCAL crashInfo IS lmTerrainClearanceInfo(
            targetLat, targetLng,
            bestUT,
            bestUT + 30, bestUT + 1800,
            2,
            TERRAIN_MIN_CLEARANCE,
            TERRAIN_SAFE_ALT).
        IF crashInfo["HIT"] AND crashInfo["DOWNFIELD"] < 0 {
            mLogError("TERRAIN CHECK FAILED: trajectory hits terrain before target pass "
                + "downfield=" + ROUND(crashInfo["DOWNFIELD"],0)
                + "m dist=" + ROUND(crashInfo["DIST"],0)
                + "m clearance=" + ROUND(crashInfo["CLEARANCE"],1) + "m.").
            REMOVE realNode.
            RETURN FALSE.
        }
        IF crashInfo["HIT"] {
            mLogWarn("Terrain check ignored post-target impact: downfield="
                + ROUND(crashInfo["DOWNFIELD"],0)
                + "m dist=" + ROUND(crashInfo["DIST"],0)
                + "m clearance=" + ROUND(crashInfo["CLEARANCE"],1) + "m.").
        } ELSE {
            mLog("Terrain check passed.").
        }
    }

    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    archiveLog().
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s",
        3, 2, 13, CYAN, FALSE).
    executeDeorbitNode(realNode).

    WAIT 2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL postImpact IS ADDONS:TR:IMPACTPOS.
        LOCAL postDist IS _targetDeorbitDistance(postImpact:LAT,
            postImpact:LNG, targetLat, targetLng).
        LOCAL postDownfield IS _targetDownfieldDistance(postImpact:LAT,
            postImpact:LNG, targetLat, targetLng, bestUT).
        mLog("Post-burn impact prediction: "
            + ROUND(postImpact:LAT,4) + "," + ROUND(postImpact:LNG,4)
            + " dist=" + ROUND(postDist/1000,1) + "km"
            + " downfield=" + ROUND(postDownfield/1000,1) + "km.").
    } ELSE {
        mLogWarn("Post-burn: Trajectories has no impact prediction.").
    }
    RETURN TRUE.
}

LOCAL FUNCTION _findDeorbitGeometryNode {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER scanStart.
    PARAMETER scanEnd.
    PARAMETER stepSec.
    PARAMETER desiredAngle.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "UT", scanStart,
        "ANGLE", 999999999,
        "ERR", 999999999,
        "LAT", 0,
        "LNG", 0
    ).

    LOCAL prevT IS scanStart.
    LOCAL prevInfo IS _targetGroundAngleAt(prevT, targetLat, targetLng).
    LOCAL bestInfo IS prevInfo.
    LOCAL bestErr IS ABS(prevInfo["ANGLE"] - desiredAngle).
    LOCAL scanT IS scanStart + stepSec.

    UNTIL scanT > scanEnd {
        LOCAL info IS _targetGroundAngleAt(scanT, targetLat, targetLng).
        LOCAL err IS ABS(info["ANGLE"] - desiredAngle).
        IF err < bestErr {
            SET bestErr TO err.
            SET bestInfo TO info.
        }

        IF prevInfo["ANGLE"] >= desiredAngle
                AND info["ANGLE"] <= desiredAngle {
            LOCAL lo IS prevT.
            LOCAL hi IS scanT.
            LOCAL iter IS 0.
            UNTIL iter >= 24 {
                LOCAL mid IS (lo + hi) / 2.
                LOCAL midInfo IS _targetGroundAngleAt(mid,
                    targetLat, targetLng).
                IF midInfo["ANGLE"] > desiredAngle {
                    SET lo TO mid.
                } ELSE {
                    SET hi TO mid.
                }
                SET iter TO iter + 1.
            }

            SET result TO _targetGroundAngleAt((lo + hi) / 2,
                targetLat, targetLng).
            SET result["VALID"] TO TRUE.
            SET result["ERR"] TO ABS(result["ANGLE"] - desiredAngle).
            RETURN result.
        }

        SET prevT TO scanT.
        SET prevInfo TO info.
        SET scanT TO scanT + stepSec.
        WAIT 0.
    }

    IF bestErr < 1 {
        SET result TO bestInfo.
        SET result["VALID"] TO TRUE.
        SET result["ERR"] TO bestErr.
    }
    RETURN result.
}

LOCAL FUNCTION _targetGroundAngleAt {
    PARAMETER ut.
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL geo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, ut)).
    RETURN LEXICON(
        "VALID", TRUE,
        "UT", ut,
        "ANGLE", _targetCentralAngle(geo:LAT, geo:LNG,
            targetLat, targetLng),
        "LAT", geo:LAT,
        "LNG", geo:LNG
    ).
}

LOCAL FUNCTION _targetCentralAngle {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL bodyPos IS SHIP:BODY:POSITION.
    RETURN VANG(LATLNG(lat1, lng1):POSITION - bodyPos,
        LATLNG(lat2, lng2):POSITION - bodyPos).
}

LOCAL FUNCTION _targetDeorbitDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    RETURN (LATLNG(lat1, lng1):POSITION - LATLNG(lat2, lng2):POSITION):MAG.
}

LOCAL FUNCTION _targetDownfieldDistance {
    PARAMETER impactLat.
    PARAMETER impactLng.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER burnUT.

    LOCAL bodyPos IS SHIP:BODY:POSITION.
    LOCAL targetVec IS LATLNG(targetLat, targetLng):POSITION.
    LOCAL impactVec IS LATLNG(impactLat, impactLng):POSITION.
    LOCAL upVec IS (targetVec - bodyPos):NORMALIZED.
    LOCAL trackDir IS VXCL(upVec,
        POSITIONAT(SHIP, burnUT + 10) - POSITIONAT(SHIP, burnUT)).
    LOCAL impactOffset IS VXCL(upVec, impactVec - targetVec).

    IF trackDir:MAG < 0.01 { RETURN impactOffset:MAG. }
    RETURN VDOT(impactOffset, trackDir:NORMALIZED).
}

LOCAL FUNCTION _solveGeometricDeorbitDv {
    PARAMETER burnUT.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER minDv.
    PARAMETER maxDv.
    PARAMETER seedDv.
    PARAMETER desiredDownfield.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.

    LOCAL best IS LEXICON(
        "VALID", FALSE,
        "DV", seedDv,
        "DIST", 999999999,
        "DOWNFIELD", -999999999,
        "ERR", 999999999,
        "PE", 999999999,
        "ANGLE", -1,
        "HAS_IMPACT", FALSE,
        "LAT", 0,
        "LNG", 0
    ).
    LOCAL bestErr IS 999999999.

    LOCAL lowDv IS 0.
    LOCAL highDv IS 0.
    LOCAL lowSet IS FALSE.
    LOCAL highSet IS FALSE.
    LOCAL currentDv IS seedDv.
    LOCAL iter IS 0.

    UNTIL iter >= 18 {
        LOCAL trial IS _evalGeometricDeorbitNode(burnUT, currentDv,
            targetLat, targetLng, minLead, desiredDownfield).
        IF trial["VALID"] {
            LOCAL trialErr IS ABS(trial["ERR"]).
            IF trialErr < bestErr {
                SET best TO trial.
                SET bestErr TO trialErr.
            }
            LOCAL impactText IS " impact=none".
            IF trial["HAS_IMPACT"] {
                SET impactText TO " impact=" + ROUND(trial["LAT"],4)
                    + "," + ROUND(trial["LNG"],4)
                    + " downfield=" + ROUND(trial["DOWNFIELD"]/1000,2)
                    + "km downErr=" + ROUND(trial["ERR"]/1000,2)
                    + "km dist=" + ROUND(trial["DIST"]/1000,2)
                    + "km".
            }
            mLog("DEBUG dv-solve: dv=" + ROUND(currentDv,2)
                + " Pe=" + ROUND(trial["PE"]/1000,2)
                + "km" + impactText
                + " fpa=" + ROUND(trial["ANGLE"],1)).
            IF trial["HAS_IMPACT"]
                    AND trial["DOWNFIELD"] >= minDownfield
                    AND trial["DOWNFIELD"] <= maxDownfield
                    AND trial["DIST"] >= minDownfield
                    AND trial["DIST"] <= maxDownfield {
                RETURN trial.
            }

            IF trial["ERR"] > 0 {
                SET lowDv TO currentDv.
                SET lowSet TO TRUE.
            } ELSE {
                SET highDv TO currentDv.
                SET highSet TO TRUE.
            }
        } ELSE {
            mLog("DEBUG dv-solve: dv=" + ROUND(currentDv,2)
                + " produced no TR impact.").
            SET lowDv TO currentDv.
            SET lowSet TO TRUE.
        }

        IF lowSet AND highSet {
            IF ABS(highDv - lowDv) < 0.05 { BREAK. }
            SET currentDv TO (lowDv + highDv) / 2.
        } ELSE IF lowSet {
            LOCAL nextHigh IS MIN(maxDv, currentDv * 1.5).
            IF nextHigh = currentDv { BREAK. }
            SET currentDv TO nextHigh.
        } ELSE {
            LOCAL nextLow IS MAX(minDv, currentDv * 0.75).
            IF nextLow = currentDv { BREAK. }
            SET currentDv TO nextLow.
        }
        SET iter TO iter + 1.
        WAIT 0.
    }

    IF best["VALID"] {
        mLogWarn("Best deorbit dV misses downfield target by "
            + ROUND(bestErr/1000,2) + "km.").
    }
    RETURN best.
}

LOCAL FUNCTION _evalGeometricDeorbitNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER desiredDownfield.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "DV", retroDv,
        "DIST", 999999999,
        "DOWNFIELD", -999999999,
        "ERR", 999999999,
        "PE", 999999999,
        "ANGLE", -1,
        "HAS_IMPACT", FALSE,
        "LAT", 0,
        "LNG", 0
    ).

    IF burnUT <= TIME:SECONDS + minLead { RETURN result. }
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planRetroNode(burnUT, retroDv).
    WAIT 0.2.
    SET result["PE"] TO nd:ORBIT:PERIAPSIS.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL dist IS _targetDeorbitDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
        LOCAL downfield IS _targetDownfieldDistance(impactPos:LAT,
            impactPos:LNG, targetLat, targetLng, burnUT).
        LOCAL angle IS _nodeImpactAngle(impactPos).
        SET result["HAS_IMPACT"] TO TRUE.
        SET result["LAT"] TO impactPos:LAT.
        SET result["LNG"] TO impactPos:LNG.
        SET result["DIST"] TO dist.
        SET result["DOWNFIELD"] TO downfield.
        SET result["ERR"] TO downfield - desiredDownfield.
        SET result["ANGLE"] TO angle.
        SET result["VALID"] TO TRUE.
    }
    REMOVE nd.
    RETURN result.
}

LOCAL FUNCTION _nodeImpactAngle {
    PARAMETER impactPos.

    IF NOT ADDONS:TR:ISVERTWOTWO { RETURN -1. }

    LOCAL impactUT IS TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT.
    LOCAL dt IS 0.5.
    LOCAL body IS SHIP:BODY.

    LOCAL rPlus IS POSITIONAT(SHIP, impactUT) - POSITIONAT(body, impactUT).
    LOCAL rMinus IS POSITIONAT(SHIP, impactUT - dt) - POSITIONAT(body, impactUT - dt).
    LOCAL impactVel IS ((rPlus - rMinus) / dt) - impactPos:VELOCITY:ORBIT.
    LOCAL impactUp IS (impactPos:POSITION - body:POSITION):NORMALIZED.

    // Descent FPA magnitude: 0 is horizontal, 90 is vertical.
    LOCAL sinFpa IS VDOT(impactVel:NORMALIZED, impactUp).

    RETURN ABS(ARCSIN(MAX(-1, MIN(1, sinFpa)))).
}

LOCAL FUNCTION _planRetroNode {
    PARAMETER burnUT.
    PARAMETER retroDv.

    LOCAL nd IS NODE(burnUT, 0, 0, -ABS(retroDv)).
    ADD nd.
    RETURN nd.
}

LOCAL FUNCTION _logDeorbitNode {
    PARAMETER label.
    PARAMETER nd.

    mLog(label + ": N("
        + ROUND(nd:PROGRADE,3) + " pro, "
        + ROUND(nd:NORMAL,3) + " norm, "
        + ROUND(nd:RADIALOUT,3) + " rad, "
        + ROUND(nd:TIME,3) + " UT)"
        + " dv=" + ROUND(nd:DELTAV:MAG,2)
        + " eta=" + ROUND(nd:ETA,1) + "s.").
}

LOCAL FUNCTION _targetDeorbitMinLead {
    LOCAL minLead IS 60.
    IF TARGET_DEORBIT_MIN_LEAD > 0 {
        SET minLead TO TARGET_DEORBIT_MIN_LEAD.
    }
    RETURN minLead.
}

GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.
}
