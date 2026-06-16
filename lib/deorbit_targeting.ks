// ============================================================
// deorbit_targeting.ks  —  Precision deorbit targeting  (0:/lib/deorbit_targeting.ks)
// ============================================================

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
    LOCAL tolerance IS LAND_CFG_TARGET_TOLERANCE.
    IF ignoredTolerance > 0 { SET tolerance TO ignoredTolerance. }
    LOCAL minAngle IS 45.
    LOCAL targetAngle IS 50.
    LOCAL angleTol IS 5.
    LOCAL seedRetroDv IS 10.
    LOCAL minRetroDv IS 1.
    LOCAL maxRetroDv IS 150.
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + ","
        + ROUND(targetLng,4)
        + "  tolerance=" + ROUND(tolerance/1000,1) + "km"
        + "  angle=" + ROUND(minAngle,0) + "-"
        + ROUND(targetAngle,0) + "deg.").
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
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
    LOCAL bestRetroDv IS seedRetroDv.
    LOCAL bestDist IS 999999999.
    LOCAL bestAngle IS -1.
    LOCAL bestScore IS 999999999.
    LOCAL validSamples IS 0.
    LOCAL angleSamples IS 0.
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

    LOCAL currentUT IS bestUT.
    LOCAL currentDv IS seedRetroDv.
    LOCAL dvStep IS 4.
    LOCAL prevDir IS 0.
    LOCAL prevAngle IS -1.
    LOCAL prevAngleDv IS currentDv.
    LOCAL didAngleShift IS FALSE.
    LOCAL iter IS 0.
    UNTIL iter >= 12 {
        LOCAL polished IS _polishRetroTime(currentUT, currentDv,
            targetLat, targetLng, minLead, stepA * 0.5).
        IF polished["VALID"] { SET currentUT TO polished["UT"]. }
        LOCAL candidate IS _evalRetroDeorbitNode(currentUT, currentDv,
            targetLat, targetLng, minLead, minAngle, targetAngle,
            angleTol).
        IF candidate["VALID"] {
            LOCAL sampledDv IS currentDv.
            LOCAL angleErr IS candidate["ANGLE"] - targetAngle.
            LOCAL angleRate IS 999999999.
            IF prevAngle >= 0 AND candidate["ANGLE"] >= 0
                    AND ABS(sampledDv - prevAngleDv) > 0.0001 {
                SET angleRate TO (candidate["ANGLE"] - prevAngle)
                    / (sampledDv - prevAngleDv).
            }
            mLog("DEBUG angle: T+" + ROUND(currentUT - nowUt,0)
                + "s dv=" + ROUND(currentDv,2)
                + " angle=" + ROUND(candidate["ANGLE"],1)
                + " dist=" + ROUND(candidate["DIST"]/1000,1) + "km"
                + " score=" + ROUND(candidate["SCORE"],1)).
            IF candidate["ANGLE_OK"] {
                SET angleSamples TO angleSamples + 1.
                IF candidate["SCORE"] < bestScore {
                    SET bestFound TO TRUE.
                    SET bestScore TO candidate["SCORE"].
                    SET bestDist TO candidate["DIST"].
                    SET bestAngle TO candidate["ANGLE"].
                    SET bestRetroDv TO currentDv.
                    SET bestUT TO currentUT.
                }
            }
            IF candidate["DIST"] <= tolerance
                    AND ABS(angleErr) <= angleTol
                    AND candidate["ANGLE_OK"] {
                BREAK.
            }
            LOCAL shiftedThisIter IS FALSE.
            IF NOT didAngleShift AND candidate["ANGLE"] > 0
                    AND ABS(angleErr) > angleTol {
                LOCAL shiftSec IS _estimateAngleTimeShift(currentUT,
                    targetLat, targetLng, candidate["ANGLE"], targetAngle).
                LOCAL shiftedUT IS MAX(TIME:SECONDS + minLead,
                    MIN(scanEnd, currentUT + shiftSec)).
                IF ABS(shiftedUT - currentUT) > stepA * 0.5 {
                    mLog("DEBUG time-est: angle=" + ROUND(candidate["ANGLE"],1)
                        + " target=" + ROUND(targetAngle,1)
                        + " shift=" + ROUND(shiftedUT - currentUT,0)
                        + "s to T+" + ROUND(shiftedUT - nowUt,0) + "s.").
                    SET currentUT TO shiftedUT.
                    SET didAngleShift TO TRUE.
                    SET shiftedThisIter TO TRUE.
                }
                SET didAngleShift TO TRUE.
            }
            IF NOT shiftedThisIter {
                IF ABS(angleRate) < 0.001 {
                    SET currentDv TO MAX(minRetroDv, MIN(maxRetroDv,
                        currentDv + (RANDOM() - 0.5) * 0.002)).
                    SET prevDir TO 0.
                }
                LOCAL dir IS 1.
                IF candidate["ANGLE"] >= targetAngle { SET dir TO -1. }
                IF candidate["ANGLE"] < 0 { SET dir TO 1. }
                IF prevDir <> 0 {
                    IF dir <> prevDir {
                        SET dvStep TO MAX(0.25, dvStep / 2).
                    } ELSE {
                        SET dvStep TO MIN(25, dvStep * 1.5).
                    }
                }
                SET prevDir TO dir.
                LOCAL nextDv IS MAX(minRetroDv, MIN(maxRetroDv,
                    currentDv + dir * dvStep)).
                IF nextDv = currentDv { BREAK. }
                SET prevAngle TO candidate["ANGLE"].
                SET prevAngleDv TO sampledDv.
                SET currentDv TO nextDv.
            }
        } ELSE {
            SET currentDv TO MIN(maxRetroDv, currentDv + dvStep).
            IF currentDv >= maxRetroDv { BREAK. }
        }
        SET iter TO iter + 1.
        WAIT 0.
    }

    IF NOT bestFound {
        mLogError("No deorbit node met minimum descent angle "
            + ROUND(minAngle,0) + "deg.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    LOCAL fstep IS stepA * 0.5.
    LOCAL dvFineStep IS 0.5.
    UNTIL fstep < 0.5 AND dvFineStep < 0.1 {
        FOR cand IN LIST(bestUT - fstep, bestUT + fstep) {
            IF cand > nowUt + minLead {
                FOR candDv IN LIST(MAX(minRetroDv, bestRetroDv - dvFineStep),
                        bestRetroDv, MIN(maxRetroDv, bestRetroDv + dvFineStep)) {
                    LOCAL refined IS _evalRetroDeorbitNode(cand, candDv,
                        targetLat, targetLng, minLead, minAngle,
                        targetAngle, angleTol).
                    IF refined["VALID"] AND refined["ANGLE_OK"]
                            AND refined["SCORE"] < bestScore {
                        SET bestScore TO refined["SCORE"].
                        SET bestDist TO refined["DIST"].
                        SET bestAngle TO refined["ANGLE"].
                        SET bestRetroDv TO candDv.
                        SET bestUT TO cand.
                    }
                }
            }
        }
        SET fstep TO fstep / 2.
        SET dvFineStep TO dvFineStep / 2.
        WAIT 0.
    }

    LOCAL finalCheck IS _evalRetroDeorbitNode(bestUT, bestRetroDv,
        targetLat, targetLng, minLead, minAngle, targetAngle, angleTol).
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

LOCAL FUNCTION _estimateAngleTimeShift {
    PARAMETER burnUT.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER actualAngle.
    PARAMETER targetAngle.

    LOCAL body IS SHIP:BODY.
    LOCAL burnGeo IS body:GEOPOSITIONOF(POSITIONAT(SHIP, burnUT)).
    LOCAL rangeNow IS geoDistance(burnGeo:LAT, burnGeo:LNG,
        targetLat, targetLng).
    LOCAL groundAhead IS body:GEOPOSITIONOF(POSITIONAT(SHIP, burnUT + 10)).
    LOCAL groundSpeed IS geoDistance(burnGeo:LAT, burnGeo:LNG,
        groundAhead:LAT, groundAhead:LNG) / 10.
    IF groundSpeed < 0.1 { RETURN 0. }

    LOCAL desiredRange IS rangeNow * TAN(actualAngle)
        / MAX(0.01, TAN(targetAngle)).
    LOCAL shiftSec IS (rangeNow - desiredRange) / groundSpeed.
    IF shiftSec > 1800 { RETURN 1800. }
    IF shiftSec < -1800 { RETURN -1800. }
    RETURN shiftSec.
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
        SET result["DIST"] TO geoDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
    }
    REMOVE nd.
    RETURN result.
}

LOCAL FUNCTION _evalRetroDeorbitNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER minAngle.
    PARAMETER targetAngle.
    PARAMETER angleTol.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "ANGLE_OK", FALSE,
        "SCORE", 999999999,
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
        LOCAL dist IS geoDistance(impactPos:LAT, impactPos:LNG,
            targetLat, targetLng).
        LOCAL angle IS _nodeImpactAngle(impactPos).
        LOCAL distCost IS (dist / 1000) * (dist / 1000).
        LOCAL angleCost IS 0.
        IF dist < 25000 {
            SET angleCost TO (angle - (-1 * targetAngle)) / 5  * (angle - (-1 * targetAngle)) / 5 * 50.
            IF angle >= 0 {
                SET angleCost TO MIN(5000, ((angle - targetAngle) / angleTol)
                    * ((angle - targetAngle) / angleTol)).
            }
        }
        SET result["VALID"] TO TRUE.
        SET result["LAT"] TO impactPos:LAT.
        SET result["LNG"] TO impactPos:LNG.
        SET result["DIST"] TO dist.
        SET result["ANGLE"] TO angle.
        SET result["SCORE"] TO distCost + angleCost.
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


    LOCAL dt IS 0.5. // Use 0.5 for better precision
    LOCAL body IS SHIP:BODY.

    // Get the velocity vector at impact (inertial frame)
    LOCAL rPlus IS POSITIONAT(SHIP, impactUT) - POSITIONAT(body, impactUT).
    LOCAL rMinus IS POSITIONAT(SHIP, impactUT - dt) - POSITIONAT(body, impactUT - dt).
    LOCAL impactVel IS ((rPlus - rMinus) / dt) - impactPos:VELOCITY:ORBIT.
    LOCAL impactUp IS (impactPos:POSITION - body:POSITION):NORMALIZED.

    // Calculate FPA: sin(gamma) = VDOT(velocity, up)
    // gamma = 0 is horizontal, gamma = -90 is vertical down
    LOCAL sinFpa IS VDOT(impactVel:NORMALIZED, impactUp).

    // Clamp to avoid domain errors in ARCSIN
    RETURN ARCSIN(MAX(-1, MIN(1, sinFpa))).


    // LOCAL dt IS 1.
    // LOCAL body IS SHIP:BODY.
    // LOCAL rPlus IS POSITIONAT(SHIP, impactUT) - POSITIONAT(body, impactUT).
    // LOCAL rMinus IS POSITIONAT(SHIP, impactUT - dt) - POSITIONAT(body, impactUT - dt).
    // LOCAL impactVel IS ((rPlus - rMinus) / dt) - impactPos:VELOCITY:ORBIT.
    // LOCAL impactUp IS (impactPos:POSITION - body:POSITION):NORMALIZED.

    // LOCAL velNorm IS impactVel:NORMALIZED.
    // LOCAL upNorm IS impactUp:NORMALIZED.

    // // The dot product of Velocity and Up gives us the Cosine of the angle between them.
    // // We want the angle between the Velocity and the Local Horizontal.
    // // Local Horizontal is 90 degrees away from the Up vector.
    // LOCAL fpa IS VANG(upNorm, velNorm).

    // RETURN 90 - fpa.

    // The sine of the flight path angle (angle from local horizontal)
    // is the dot product of the velocity vector and the up vector.
    // LOCAL sinFpa IS VDOT(velNorm, upNorm).
    // LOCAL fpa IS ARCSIN(sinFpa). // This will return values between -90 and 90.
    // RETURN fpa.
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
