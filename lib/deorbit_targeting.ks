// ============================================================
// deorbit_targeting.ks  —  Precision deorbit targeting  (0:/lib/deorbit_targeting.ks)
// ============================================================

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

@CLOBBERBUILTINS ON.

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

    IF TRUE {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO PROBE_TARGET_LAT.
        SET result["LNG"] TO PROBE_TARGET_LNG.
        SET result["SOURCE"] TO "PROBE_TARGET_LAT/LNG".
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
    LOCAL tolerance IS LAND_CFG_TARGET_TOLERANCE.
    IF ignoredTolerance > 0 { SET tolerance TO ignoredTolerance. }
    LOCAL minAngle IS 45.
    LOCAL seedRetroDv IS 10.
    LOCAL maxRetroDv IS 150.
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + ","
        + ROUND(targetLng,4)
        + "  tolerance=" + ROUND(tolerance/1000,1) + "km"
        + "  angle>=" + ROUND(minAngle,0) + "deg.").
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

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
    LOCAL stepA IS period / 64.
    LOCAL bestUT IS scanStart.
    LOCAL bestRetroDv IS seedRetroDv.
    LOCAL bestDist IS 999999999.
    LOCAL bestAngle IS -1.
    LOCAL validSamples IS 0.
    LOCAL bestFound IS FALSE.
    LOCAL scanUT IS scanStart.

    mLog("Node scan: T+" + ROUND(scanEnd - nowUt,0)
        + "s step=" + ROUND(stepA,1)
        + "s seedDv=" + ROUND(seedRetroDv,1)
        + " angle>=45 TR target=true-site.").
    UNTIL scanUT > scanEnd OR bestDist <= tolerance {
        LOCAL trial IS _evalRetroImpactNode(scanUT, seedRetroDv,
            targetLat, targetLng, minLead).
        IF trial["VALID"] {
            SET validSamples TO validSamples + 1.
            IF trial["DIST"] < bestDist {
                SET bestDist TO trial["DIST"].
                SET bestUT TO scanUT.
                mLog("DEBUG seed: T+" + ROUND(scanUT - nowUt,0)
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

    LOCAL seedPolish IS _polishRetroTime(bestUT, seedRetroDv,
        targetLat, targetLng, minLead, stepA * 0.5).
    IF seedPolish["VALID"] {
        SET bestUT TO seedPolish["UT"].
        SET bestDist TO seedPolish["DIST"].
    }
    mLog("Seed best: T+" + ROUND(bestUT - nowUt,0)
        + "s dv=" + ROUND(seedRetroDv,1)
        + " dist=" + ROUND(bestDist/1000,1)
        + "km samples=" + validSamples + ".").

    LOCAL currentDv IS seedRetroDv.
    LOCAL dvStep IS 2.5.
    UNTIL currentDv > maxRetroDv OR bestFound {
        LOCAL polished IS _polishRetroTime(bestUT, currentDv,
            targetLat, targetLng, minLead, stepA * 0.5).
        IF polished["VALID"] {
            IF polished["DIST"] <= tolerance {
                LOCAL candidate IS _evalRetroDeorbitNode(polished["UT"],
                    currentDv, targetLat, targetLng, minLead, minAngle).
                IF candidate["VALID"] {
                    mLog("DEBUG Check: dV=" + ROUND(currentDv,1)
                        + " T+" + ROUND(polished["UT"] - nowUt,0)
                        + " impact=" + ROUND(candidate["LAT"],4)
                        + "," + ROUND(candidate["LNG"],4)
                        + " target=" + ROUND(targetLat,4)
                        + "," + ROUND(targetLng,4)
                        + " dist=" + ROUND(candidate["DIST"]/1000,1)
                        + "km angle=" + ROUND(candidate["ANGLE"],1)).
                    IF candidate["ANGLE_OK"] {
                        SET bestFound TO TRUE.
                        SET bestDist TO candidate["DIST"].
                        SET bestAngle TO candidate["ANGLE"].
                        SET bestRetroDv TO currentDv.
                        SET bestUT TO polished["UT"].
                        BREAK.
                    }
                }
            }
        }
        SET currentDv TO currentDv + dvStep.
        WAIT 0.
    }

    IF NOT bestFound {
        mLogError("No deorbit node met target tolerance and minimum descent angle "
            + ROUND(minAngle,0) + "deg.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    LOCAL finalCheck IS _evalRetroDeorbitNode(bestUT, bestRetroDv,
        targetLat, targetLng, minLead, minAngle).
    IF finalCheck["VALID"] {
        SET bestDist TO finalCheck["DIST"].
        SET bestAngle TO finalCheck["ANGLE"].
        mLog("Polished best: T+" + ROUND(bestUT - nowUt,0)
            + "s dv=" + ROUND(bestRetroDv,2)
            + " angle=" + ROUND(bestAngle,1)
            + " impact=" + ROUND(finalCheck["LAT"],4)
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
    LOCAL realNode IS _planRetroNode(bestUT, bestRetroDv).
    _logDeorbitNode("Selected deorbit node", realNode).
    WAIT 0.5.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL trDist IS _targetDeorbitDistance(impactPos:LAT, impactPos:LNG,
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
        LOCAL postDist IS _targetDeorbitDistance(postImpact:LAT,
            postImpact:LNG, targetLat, targetLng).
        mLog("Post-burn impact prediction: "
            + ROUND(postImpact:LAT,4) + "," + ROUND(postImpact:LNG,4)
            + " dist=" + ROUND(postDist/1000,1) + "km.").
    } ELSE {
        mLogWarn("Post-burn: Trajectories has no impact prediction.").
    }
    RETURN TRUE.
}

LOCAL FUNCTION _polishRetroTime {
    PARAMETER seedUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER startStep.

    LOCAL best IS _evalRetroImpactNode(seedUT, retroDv,
        targetLat, targetLng, minLead).
    IF NOT best["VALID"] { RETURN best. }
    LOCAL fstep IS startStep.
    UNTIL fstep < 0.5 {
        FOR cand IN LIST(best["UT"] - fstep, best["UT"] + fstep) {
            IF cand > TIME:SECONDS + minLead {
                LOCAL trial IS _evalRetroImpactNode(cand, retroDv,
                    targetLat, targetLng, minLead).
                IF trial["VALID"] AND trial["DIST"] < best["DIST"] {
                    SET best TO trial.
                }
            }
        }
        SET fstep TO fstep / 2.
        WAIT 0.
    }
    RETURN best.
}

LOCAL FUNCTION _evalRetroImpactNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "UT", burnUT,
        "DIST", 999999999,
        "LAT", 0,
        "LNG", 0
    ).

    IF burnUT <= TIME:SECONDS + minLead { RETURN result. }
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planRetroNode(burnUT, retroDv).
    WAIT 0.2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        SET result["VALID"] TO TRUE.
        SET result["LAT"] TO impactPos:LAT.
        SET result["LNG"] TO impactPos:LNG.
        SET result["DIST"] TO _targetDeorbitDistance(impactPos:LAT,
            impactPos:LNG, targetLat, targetLng).
    }
    REMOVE nd.
    RETURN result.
}

LOCAL FUNCTION _targetDeorbitDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    RETURN (LATLNG(lat1, lng1):POSITION - LATLNG(lat2, lng2):POSITION):MAG.
}

LOCAL FUNCTION _evalRetroDeorbitNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER minAngle.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "ANGLE_OK", FALSE,
        "DIST", 999999999,
        "ANGLE", -1,
        "LAT", 0,
        "LNG", 0
    ).

    IF burnUT <= TIME:SECONDS + minLead { RETURN result. }
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planRetroNode(burnUT, retroDv).
    WAIT 0.2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL dist IS _targetDeorbitDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
        LOCAL angle IS _nodeImpactAngle(impactPos).
        SET result["VALID"] TO TRUE.
        SET result["LAT"] TO impactPos:LAT.
        SET result["LNG"] TO impactPos:LNG.
        SET result["DIST"] TO dist.
        SET result["ANGLE"] TO angle.
        IF angle >= minAngle {
            SET result["ANGLE_OK"] TO TRUE.
        }
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
