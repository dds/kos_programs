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
GLOBAL TARGET_TOLERANCE IS 5000.
GLOBAL TARGET_DEORBIT_MIN_LEAD IS 0.
GLOBAL TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM IS 0.
GLOBAL LANDING_SIM_MODE IS 0.
GLOBAL DEORBIT_CROSSTRACK_AUTHORITY_KM IS 0.
GLOBAL DEORBIT_MIN_FPA IS 0.
// Opt-in small lateral correction combined with the retrograde burn.
GLOBAL TARGET_DEORBIT_NORMAL_DV_CAP IS 0.

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
    PARAMETER refineSite IS TRUE.

    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available; targeted landing deorbit requires TR.").
        RETURN FALSE.
    }
    IF NOT ADDONS:TR:ISVERTWOTWO {
        mLogError("Targeted deorbit requires Trajectories 2.2+ impact timing.").
        RETURN FALSE.
    }

    IF NOT targetReachable(targetLat) {
        mLogError("Target latitude is not reachable from this orbit inclination.").
        RETURN FALSE.
    }

    LOCAL site IS LEXICON("FOUND", FALSE).
    IF refineSite AND DEFINED BOOT_LIB_RAN AND BOOT_LIB_RAN:CONTAINS("landing_site") {
        SET site TO selectScanSatLandingSite(targetLat, targetLng).
    }
    IF site["FOUND"] {
        SET targetLat TO site["LAT"].
        SET targetLng TO site["LNG"].
    }

    LOCAL targetGeo IS LATLNG(targetLat, targetLng).
    LOCAL tolerance IS TARGET_TOLERANCE.
    IF overrideTolerance > 0 { SET tolerance TO overrideTolerance. }
    LOCAL desiredDownfield IS 15000.
    IF overrideOvershoot > 0 { SET desiredDownfield TO overrideOvershoot. }
    LOCAL minDownfield IS 10000.
    LOCAL maxDownfield IS 20000.
    LOCAL minRetroDv IS 2.
    LOCAL seedRetroDv IS 15.
    LOCAL maxRetroDv IS 120.
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + ","
        + ROUND(targetLng,4)
        + "  nodeAngles=50,35,65,20,80deg"
        + "  downfield=" + ROUND(desiredDownfield/1000,1) + "km"
        + " band=" + ROUND(minDownfield/1000,1)
        + "-" + ROUND(maxDownfield/1000,1) + "km.").
    HUDTEXT("Solving geometric deorbit...", 3, 2, 13, CYAN, FALSE).

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL minLead IS _targetDeorbitMinLead().
    LOCAL scanOrbits IS 4.
    IF TARGET_DEORBIT_SCAN_ORBITS > 0 {
        SET scanOrbits TO TARGET_DEORBIT_SCAN_ORBITS.
    }
    IF LANDING_SIM_MODE > 0 {
        IF scanOrbits > 2 { SET scanOrbits TO 2. }
    }

    LOCAL stepA IS period / MAX(128, TARGET_DEORBIT_SCAN_SAMPLES).
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL geometry IS LEXICON(
        "VALID", FALSE,
        "UT", nowUt + minLead,
        "ANGLE", 999999999,
        "ERR", 999999999,
        "LAT", 0,
        "LNG", 0
    ).
    LOCAL solved IS LEXICON(
        "VALID", FALSE,
        "DV", seedRetroDv,
        "DIST", 999999999,
        "DOWNFIELD", -999999999,
        "ERR", 999999999,
        "PE", 999999999,
        "ANGLE", -1,
        "HAS_IMPACT", FALSE,
        "LAT", 0,
        "LNG", 0,
        "TTI", 0
    ).
    LOCAL foundGeometry IS FALSE.
    LOCAL acceptedSolution IS FALSE.
    LOCAL bestAccepted IS LEXICON("VALID", FALSE).
    LOCAL bestAcceptedGeometry IS LEXICON("VALID", FALSE).
    LOCAL bestAcceptedCross IS 999999999.
    LOCAL preferredCrossTrack IS 0.
    IF TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM > 0 {
        SET preferredCrossTrack TO TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM * 1000.
    }
    LOCAL orbitScan IS 0.

    UNTIL orbitScan >= scanOrbits OR acceptedSolution {
        // The old single 50-degree seed can miss a usable approach on
        // an eccentric orbit. Try nearby burn locations before waiting
        // another orbit; every candidate retains the same limits.
        FOR candidateAngle IN LIST(50, 35, 65, 20, 80) {
            IF acceptedSolution { BREAK. }
            LOCAL scanStart IS MAX(TIME:SECONDS + minLead + 5,
                nowUt + minLead + orbitScan * period).
            LOCAL scanEnd IS scanStart + period + 30.
            SET geometry TO _findDeorbitGeometryNode(targetLat, targetLng,
                scanStart, scanEnd, stepA, candidateAngle).

            IF geometry["VALID"] {
                SET foundGeometry TO TRUE.
                LOCAL candidateUT IS geometry["UT"].
                mLog("Geometry node orbit " + (orbitScan + 1)
                    + "/" + scanOrbits
                    + ": T+" + ROUND(candidateUT - nowUt,0)
                    + "s angle=" + ROUND(geometry["ANGLE"],2)
                    + " subpoint=" + ROUND(geometry["LAT"],4)
                    + "," + ROUND(geometry["LNG"],4) + ".").

                SET solved TO _solveGeometricDeorbitDv(candidateUT,
                    targetLat, targetLng,
                    minLead, minRetroDv, maxRetroDv, seedRetroDv,
                    desiredDownfield, minDownfield, maxDownfield).
                IF NOT solved["VALID"] {
                    mLogWarn("Orbit " + (orbitScan + 1)
                        + " geometry did not solve a valid deorbit.").
                } ELSE IF _targetDeorbitSolutionAccepted(solved,
                        minDownfield, maxDownfield) {
                    LOCAL crossTrack IS _targetCrossTrackFromSolved(solved).
                    IF NOT bestAccepted["VALID"]
                            OR crossTrack < bestAcceptedCross {
                        SET bestAccepted TO solved.
                        SET bestAcceptedGeometry TO geometry.
                        SET bestAcceptedCross TO crossTrack.
                    }

                    IF preferredCrossTrack <= 0 OR crossTrack <= preferredCrossTrack {
                        SET acceptedSolution TO TRUE.
                    } ELSE {
                        mLogWarn("Orbit " + (orbitScan + 1)
                            + " solution accepted but wide: cross="
                            + ROUND(crossTrack/1000,2)
                            + "km preferred<="
                            + ROUND(preferredCrossTrack/1000,2)
                            + "km; scanning later orbit(s).").
                    }
                } ELSE {
                    LOCAL crossTrack IS _targetCrossTrackFromSolved(solved).
                    LOCAL crossAuth IS _targetDeorbitCrossAuthority(solved).
                    mLogWarn("STATS deorbit candidate orbit=" + (orbitScan + 1)
                        + " nodeAngle=" + candidateAngle
                        + " dv=" + ROUND(solved["DV"],2)
                        + " reason=" + _targetDeorbitRejection(solved, minDownfield, maxDownfield)
                        + " solution outside deorbit band: dist="
                        + ROUND(solved["DIST"]/1000,2)
                        + "km downfield="
                        + ROUND(solved["DOWNFIELD"]/1000,2)
                        + "km cross="
                        + ROUND(crossTrack/1000,2)
                        + "/" + ROUND(crossAuth/1000,2)
                        + "km fpa=" + ROUND(solved["ANGLE"],1) + ".").
                }
            } ELSE {
                mLogWarn("No deorbit node found at ground angle "
                    + ROUND(candidateAngle,0) + "deg during orbit "
                    + (orbitScan + 1) + "/" + scanOrbits + ".").
            }
        }

        SET orbitScan TO orbitScan + 1.
        WAIT 0.
    }

    IF NOT acceptedSolution AND bestAccepted["VALID"] {
        SET solved TO bestAccepted.
        SET geometry TO bestAcceptedGeometry.
        SET acceptedSolution TO TRUE.
        mLogWarn("No later pass met preferred cross-track <= "
            + ROUND(preferredCrossTrack/1000,2)
            + "km; using best acceptable cross="
            + ROUND(bestAcceptedCross/1000,2) + "km.").
    }

    IF NOT acceptedSolution {
        IF NOT foundGeometry {
            mLogError("STATS deorbit result=hold: no approaching burn geometry within "
                + scanOrbits + " orbit(s).").
        } ELSE {
            mLogError("STATS deorbit result=hold: no retrograde dV in " + ROUND(minRetroDv,1)
                + "-" + ROUND(maxRetroDv,1) + "m/s put TR impact "
                + ROUND(minDownfield/1000,1) + "-"
                + ROUND(maxDownfield/1000,1)
                + "km downfield with acceptable cross-track after scanning "
                + scanOrbits + " orbit(s).").
        }
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    LOCAL bestUT IS geometry["UT"].
    LOCAL bestRetroDv IS solved["RETRO"].
    LOCAL bestNormalDv IS solved["NORMAL"].
    LOCAL bestDist IS solved["DIST"].
    LOCAL bestAngle IS solved["ANGLE"].
    LOCAL bestDownfield IS solved["DOWNFIELD"].
    LOCAL bestPe IS solved["PE"].
    LOCAL bestCross IS _targetCrossTrackFromSolved(solved).
    LOCAL bestCrossAuthority IS _targetDeorbitCrossAuthority(solved).

    LOCAL solvedImpactText IS " impact=none".
    IF solved["HAS_IMPACT"] {
        SET solvedImpactText TO " impact=" + ROUND(solved["LAT"],4)
            + "," + ROUND(solved["LNG"],4)
            + " dist=" + ROUND(bestDist/1000,2) + "km"
            + " downfield=" + ROUND(bestDownfield/1000,2) + "km"
            + " cross=" + ROUND(bestCross/1000,2)
            + "/" + ROUND(bestCrossAuthority/1000,2) + "km".
    }
    mLog("STATS deorbit solved: T+" + ROUND(bestUT - nowUt,0)
        + "s dv=" + ROUND(solved["DV"],2)
        + " retro=" + ROUND(bestRetroDv,2)
        + " normal=" + ROUND(bestNormalDv,2)
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
    IF bestCross > bestCrossAuthority {
        mLogError("Solved node impact exceeds cross-track authority: "
            + ROUND(bestCross/1000,2) + "km > "
            + ROUND(bestCrossAuthority/1000,2) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF DEORBIT_MIN_FPA > 0
            AND (bestAngle < 0 OR bestAngle < DEORBIT_MIN_FPA) {
        mLogError("Solved node impact FPA below safe floor: "
            + ROUND(bestAngle,1) + "deg < "
            + ROUND(DEORBIT_MIN_FPA,1) + "deg.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    IF bestUT <= TIME:SECONDS + minLead {
        mLogWarn("STATS deorbit result=hold reason=planning-window-expired").
        RETURN FALSE.
    }
    LOCAL realNode IS _planRetroNode(bestUT, bestRetroDv, bestNormalDv).
    _logDeorbitNode("Selected deorbit node", realNode).
    WAIT 0.5.
    LOCAL finalCheck IS _readGeometricDeorbitNode(realNode,
        targetLat, targetLng, desiredDownfield).
    mLog("STATS deorbit final valid=" + finalCheck["VALID"]
        + " dv=" + ROUND(solved["DV"],2)
        + " downfieldKm=" + ROUND(finalCheck["DOWNFIELD"]/1000,2)
        + " crossKm=" + ROUND(finalCheck["CROSS"]/1000,2)
        + " reason=" + _targetDeorbitRejection(finalCheck, minDownfield, maxDownfield)).
    IF NOT _targetDeorbitSolutionAccepted(finalCheck, minDownfield, maxDownfield) {
        mLogWarn("Final deorbit prediction failed revalidation; retaining orbit.").
        REMOVE realNode.
        RETURN FALSE.
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

    IF bestUT <= TIME:SECONDS + minLead {
        mLogWarn("STATS deorbit result=hold reason=validation-window-expired").
        REMOVE realNode.
        RETURN FALSE.
    }
    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    archiveLog().
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s",
        3, 2, 13, CYAN, FALSE).
    IF NOT executeDeorbitNode(realNode) { RETURN FALSE. }

    WAIT 2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL postImpact IS ADDONS:TR:IMPACTPOS.
        LOCAL postDist IS _targetDeorbitDistance(postImpact:LAT,
            postImpact:LNG, targetLat, targetLng).
        LOCAL postDownfield IS _targetDownfieldDistance(postImpact:LAT,
            postImpact:LNG, targetLat, targetLng,
            TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT).
        mLog("Post-burn impact prediction: "
            + ROUND(postImpact:LAT,4) + "," + ROUND(postImpact:LNG,4)
            + " dist=" + ROUND(postDist/1000,1) + "km"
            + " downfield=" + ROUND(postDownfield/1000,1) + "km.").
    } ELSE {
        mLogWarn("Post-burn: Trajectories has no impact prediction.").
    }
    RETURN TRUE.
}

LOCAL FUNCTION _targetCrossTrackFromSolved {
    PARAMETER solved.
    IF NOT solved["HAS_IMPACT"] { RETURN 999999999. }
    RETURN solved["CROSS"].
}

LOCAL FUNCTION _targetDeorbitSolutionAccepted {
    PARAMETER solved.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    RETURN _targetDeorbitRejection(solved, minDownfield, maxDownfield) = "accepted".
}

LOCAL FUNCTION _targetDeorbitRejection {
    PARAMETER solved.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    IF NOT solved["VALID"] OR NOT solved["HAS_IMPACT"] { RETURN "no-impact-prediction". }
    IF solved["DOWNFIELD"] < minDownfield { RETURN "insufficient-braking-lead". }
    IF solved["DOWNFIELD"] > maxDownfield { RETURN "excessive-braking-lead". }
    IF DEORBIT_MIN_FPA > 0
            AND (solved["ANGLE"] < 0 OR solved["ANGLE"] < DEORBIT_MIN_FPA) {
        RETURN "impact-angle".
    }
    IF _targetCrossTrackFromSolved(solved) > _targetDeorbitCrossAuthority(solved) {
        RETURN "cross-track".
    }
    RETURN "accepted".
}

LOCAL FUNCTION _targetDeorbitCrossAuthority {
    PARAMETER solved.
    IF DEORBIT_CROSSTRACK_AUTHORITY_KM > 0 {
        RETURN DEORBIT_CROSSTRACK_AUTHORITY_KM * 1000.
    }

    LOCAL maxAcc IS 0.
    IF SHIP:MASS > 0 {
        SET maxAcc TO MAX(SHIP:AVAILABLETHRUST, SHIP:MAXTHRUST)
            / SHIP:MASS.
    }
    IF maxAcc <= 0 { RETURN 0. }

    LOCAL tti IS 0.
    IF solved:HASKEY("TTI") { SET tti TO solved["TTI"]. }
    LOCAL mccWindow IS tti
        - LANDING_COAST_MCC_MIN_BRAKE_ETA
        - LANDING_BRAKE_ALIGN_LEAD.
    IF mccWindow < 0 { SET mccWindow TO 0. }

    LOCAL pulseCycle IS LANDING_COAST_MCC_PULSE_TIME
        + LANDING_COAST_MCC_SETTLE_TIME.
    LOCAL duty IS 1.
    IF pulseCycle > 0 {
        SET duty TO LANDING_COAST_MCC_PULSE_TIME / pulseCycle.
    }
    LOCAL mccAcc IS maxAcc * LANDING_COAST_MCC_THROTTLE_MAX * duty.
    LOCAL mccAuthority IS 0.5 * mccAcc * mccWindow ^ 2.

    LOCAL brakeWindow IS LANDING_COAST_MCC_MIN_BRAKE_ETA
        + LANDING_BRAKE_ALIGN_LEAD.
    LOCAL brakeBias IS MIN(TR_BRAKE_BIAS, ABS(SIN(CROSS_PID_MAX))).
    LOCAL brakeAcc IS maxAcc * LANDING_HKILL_THROTTLE_MIN * brakeBias.
    LOCAL brakeAuthority IS 0.5 * brakeAcc * brakeWindow ^ 2.

    RETURN mccAuthority + brakeAuthority.
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
    LOCAL samplesSinceYield IS 0.

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
            // Sub-second timing is sufficient here; avoid refining a
            // coarse orbital seed to microseconds before consulting TR.
            UNTIL iter >= 24 OR hi - lo <= 0.25 {
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
        // Pure geometry needs no physics update for each future sample.
        // Keep the UI responsive without spending 512 ticks per scan.
        SET samplesSinceYield TO samplesSinceYield + 1.
        IF samplesSinceYield >= 16 {
            WAIT 0.
            SET samplesSinceYield TO 0.
        }
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

    LOCAL geo IS lmGroundGeoAt(ut).
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
    RETURN VANG(LATLNG(lat1, lng1):ALTITUDEPOSITION(0) - bodyPos,
        LATLNG(lat2, lng2):ALTITUDEPOSITION(0) - bodyPos).
}

LOCAL FUNCTION _targetDeorbitDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    RETURN _targetCentralAngle(lat1, lng1, lat2, lng2)
        * SHIP:BODY:RADIUS * CONSTANT:PI / 180.
}

LOCAL FUNCTION _targetDownfieldDistance {
    PARAMETER impactLat.
    PARAMETER impactLng.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER impactUT.
    LOCAL offset IS lmSurfaceTrackOffset(targetLat, targetLng,
        impactLat, impactLng, lmGroundVelocityAt(impactUT)).
    RETURN offset["DOWNFIELD"].
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
        "LNG", 0,
        "TTI", 0
    ).
    LOCAL bestErr IS 999999999.

    LOCAL lowDv IS 0.
    LOCAL highDv IS 0.
    LOCAL lowSet IS FALSE.
    LOCAL highSet IS FALSE.
    LOCAL currentDv IS seedDv.
    LOCAL normalDv IS 0.
    LOCAL normalTried IS FALSE.
    LOCAL iter IS 0.

    UNTIL iter >= 18 {
        IF burnUT <= TIME:SECONDS + minLead {
            mLogWarn("STATS deorbit solve stop=burn-window-expired").
            RETURN LEXICON("VALID", FALSE).
        }
        LOCAL trial IS _evalGeometricDeorbitNode(burnUT, currentDv,
            targetLat, targetLng, minLead, desiredDownfield, normalDv).
        IF NOT normalTried AND TARGET_DEORBIT_NORMAL_DV_CAP > 0
                AND _targetDeorbitRejection(trial, minDownfield, maxDownfield) = "cross-track" {
            SET normalTried TO TRUE.
            SET trial TO _correctDeorbitCrossTrack(burnUT, trial,
                targetLat, targetLng, minLead, desiredDownfield, minDownfield, maxDownfield).
            IF trial["NORMAL"] <> normalDv {
                // A changed normal component changes the downrange curve.
                // Old retrograde brackets no longer describe this solve.
                SET lowSet TO FALSE.
                SET highSet TO FALSE.
                SET bestErr TO 999999999.
                SET best TO LEXICON("VALID", FALSE).
            }
            SET normalDv TO trial["NORMAL"].
        }
        IF trial["VALID"] {
            LOCAL trialErr IS ABS(trial["ERR"]).
            IF trialErr < bestErr {
                SET best TO trial.
                SET bestErr TO trialErr.
            }
            LOCAL impactText IS " impact=none".
            IF trial["HAS_IMPACT"] {
                LOCAL crossTrack IS _targetCrossTrackFromSolved(trial).
                LOCAL crossAuth IS _targetDeorbitCrossAuthority(trial).
                SET impactText TO " impact=" + ROUND(trial["LAT"],4)
                    + "," + ROUND(trial["LNG"],4)
                    + " downfield=" + ROUND(trial["DOWNFIELD"]/1000,2)
                    + "km downErr=" + ROUND(trial["ERR"]/1000,2)
                    + "km dist=" + ROUND(trial["DIST"]/1000,2)
                    + "km cross=" + ROUND(crossTrack/1000,2)
                    + "/" + ROUND(crossAuth/1000,2)
                    + "km tti=" + ROUND(trial["TTI"],0) + "s".
            }
            mLog("DEBUG dv-solve: dv=" + ROUND(trial["DV"],2)
                + " retro=" + ROUND(currentDv,2) + " normal=" + ROUND(normalDv,2)
                + " Pe=" + ROUND(trial["PE"]/1000,2)
                + "km" + impactText
                + " fpa=" + ROUND(trial["ANGLE"],1)).
            IF _targetDeorbitSolutionAccepted(trial,
                    minDownfield, maxDownfield) {
                mLog("STATS deorbit solve stop=first-acceptable dv="
                    + ROUND(trial["DV"],2) + " trials=" + (iter + 1)).
                RETURN trial.
            }

            // This is a 1-D solve for downrange, not for lateral error
            // or FPA. Once along-track is close, change the burn location
            // instead of repeatedly polishing the same unusable root.
            IF _targetDeorbitDownrangeConverged(trial, minDownfield, maxDownfield) {
                mLogWarn("STATS deorbit solve stop=change-burn-location dv="
                    + ROUND(trial["DV"],2)
                    + " downErrKm=" + ROUND(trial["ERR"]/1000,2)
                    + " crossKm=" + ROUND(trial["CROSS"]/1000,2)
                    + " crossLimitKm=" + ROUND(_targetDeorbitCrossAuthority(trial)/1000,2)
                    + " reason=" + _targetDeorbitRejection(trial, minDownfield, maxDownfield)).
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
        mLogWarn("STATS deorbit solve stop=search-limit reason="
            + _targetDeorbitRejection(best, minDownfield, maxDownfield)
            + " downErrKm=" + ROUND(bestErr/1000,2)).
    }
    RETURN best.
}

LOCAL FUNCTION _correctDeorbitCrossTrack {
    PARAMETER burnUT.
    PARAMETER base.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER desiredDownfield.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.

    // Measure the sign in the game's node frame; do not assume normal's
    // handedness. At most three extra TR evaluations per burn location.
    LOCAL capDv IS TARGET_DEORBIT_NORMAL_DV_CAP.
    LOCAL probeDv IS MIN(1, capDv).
    LOCAL best IS base.
    LOCAL plus IS _evalGeometricDeorbitNode(burnUT, base["RETRO"],
        targetLat, targetLng, minLead, desiredDownfield, probeDv).
    IF plus["VALID"] {
        IF _targetDeorbitSolutionAccepted(plus, minDownfield, maxDownfield) { RETURN plus. }
        IF plus["CROSS"] < best["CROSS"] { SET best TO plus. }
    }
    LOCAL minus IS _evalGeometricDeorbitNode(burnUT, base["RETRO"],
        targetLat, targetLng, minLead, desiredDownfield, -probeDv).
    IF minus["VALID"] {
        IF _targetDeorbitSolutionAccepted(minus, minDownfield, maxDownfield) { RETURN minus. }
        IF minus["CROSS"] < best["CROSS"] { SET best TO minus. }
    }
    IF NOT plus["VALID"] OR NOT minus["VALID"] { RETURN best. }
    LOCAL normalGuess IS _targetDeorbitNormalGuess(base["SIGNED_CROSS"],
        plus["SIGNED_CROSS"], minus["SIGNED_CROSS"], probeDv, capDv).
    IF ABS(normalGuess) < 0.01 { RETURN best. }
    LOCAL corrected IS _evalGeometricDeorbitNode(burnUT, base["RETRO"],
        targetLat, targetLng, minLead, desiredDownfield, normalGuess).
    IF corrected["VALID"] {
        IF _targetDeorbitSolutionAccepted(corrected, minDownfield, maxDownfield) {
            SET best TO corrected.
        } ELSE IF corrected["CROSS"] < best["CROSS"] {
            SET best TO corrected.
        }
    }
    mLog("STATS deorbit normal dv=" + ROUND(best["DV"],2)
        + " normal=" + ROUND(best["NORMAL"],2)
        + " crossKm=" + ROUND(best["CROSS"]/1000,2)
        + " reason=" + _targetDeorbitRejection(best, minDownfield, maxDownfield)).
    RETURN best.
}

LOCAL FUNCTION _targetDeorbitNormalGuess {
    PARAMETER baseCross.
    PARAMETER plusCross.
    PARAMETER minusCross.
    PARAMETER probeDv.
    PARAMETER capDv.
    LOCAL slope IS (plusCross - minusCross) / (2 * probeDv).
    IF ABS(slope) < 1 { RETURN 0. }
    RETURN MAX(-capDv, MIN(capDv, -baseCross / slope)).
}

LOCAL FUNCTION _targetDeorbitDownrangeConverged {
    PARAMETER solved.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    RETURN solved["VALID"] AND solved["HAS_IMPACT"]
        AND solved["DOWNFIELD"] >= minDownfield
        AND solved["DOWNFIELD"] <= maxDownfield
        AND ABS(solved["ERR"]) <= 250.
}

LOCAL FUNCTION _evalGeometricDeorbitNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER desiredDownfield.
    PARAMETER normalDv IS 0.

    IF burnUT <= TIME:SECONDS + minLead {
        RETURN LEXICON("VALID", FALSE, "HAS_IMPACT", FALSE).
    }
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planRetroNode(burnUT, retroDv, normalDv).
    WAIT 0.5.
    LOCAL result IS _readGeometricDeorbitNode(nd,
        targetLat, targetLng, desiredDownfield).
    REMOVE nd.
    RETURN result.
}

LOCAL FUNCTION _readGeometricDeorbitNode {
    PARAMETER nd.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER desiredDownfield.
    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "DV", nd:DELTAV:MAG,
        "RETRO", ABS(nd:PROGRADE),
        "NORMAL", nd:NORMAL,
        "DIST", 999999999,
        "DOWNFIELD", -999999999,
        "CROSS", 999999999,
        "ERR", 999999999,
        "PE", 999999999,
        "ANGLE", -1,
        "HAS_IMPACT", FALSE,
        "LAT", 0,
        "LNG", 0,
        "TTI", 0
    ).

    SET result["PE"] TO nd:ORBIT:PERIAPSIS.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL impactUT IS TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT.
        IF impactUT <= nd:TIME { RETURN result. }
        LOCAL offset IS lmSurfaceTrackOffset(targetLat, targetLng,
            impactPos:LAT, impactPos:LNG, lmGroundVelocityAt(impactUT)).
        IF NOT offset["VALID"] { RETURN result. }
        SET result["HAS_IMPACT"] TO TRUE.
        SET result["LAT"] TO impactPos:LAT.
        SET result["LNG"] TO impactPos:LNG.
        SET result["DIST"] TO offset["DIST"].
        SET result["DOWNFIELD"] TO offset["DOWNFIELD"].
        SET result["CROSS"] TO offset["CROSS"].
        SET result["SIGNED_CROSS"] TO offset["SIGNED_CROSS"].
        SET result["ERR"] TO offset["DOWNFIELD"] - desiredDownfield.
        SET result["ANGLE"] TO _nodeImpactAngle(impactUT).
        // Lateral guidance starts AFTER the burn, not while waiting for it.
        SET result["TTI"] TO impactUT - nd:TIME.
        SET result["VALID"] TO TRUE.
    }
    RETURN result.
}

LOCAL FUNCTION _nodeImpactAngle {
    PARAMETER impactUT.
    LOCAL impactVel IS lmGroundVelocityAt(impactUT).
    IF impactVel:MAG < 0.01 { RETURN -1. }
    LOCAL impactUp IS lmGroundPositionAt(impactUT):NORMALIZED.

    // Descent FPA magnitude: 0 is horizontal, 90 is vertical.
    LOCAL sinFpa IS VDOT(impactVel:NORMALIZED, impactUp).

    RETURN ABS(ARCSIN(MAX(-1, MIN(1, sinFpa)))).
}

LOCAL FUNCTION _planRetroNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER normalDv IS 0.

    LOCAL nd IS NODE(burnUT, 0, normalDv, -ABS(retroDv)).
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
