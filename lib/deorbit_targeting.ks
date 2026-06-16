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

LOCAL FUNCTION _deorbitOffsetLatLng {
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

LOCAL FUNCTION _deorbitGhostTarget {
    PARAMETER targetLat.
    PARAMETER targetLng.
    LOCAL out IS LEXICON("LAT", targetLat, "LNG", targetLng).
    LOCAL ghostDownrange IS 5000.
    LOCAL hv IS lmHorizontalVelocity().
    IF hv:MAG < 0.1 { RETURN out. }
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL northVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE + 0.01, SHIP:LONGITUDE):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL eastVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE, SHIP:LONGITUDE + 0.01):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL shifted IS _deorbitOffsetLatLng(targetLat, targetLng,
        VDOT(hv:NORMALIZED, northVec) * ghostDownrange,
        VDOT(hv:NORMALIZED, eastVec) * ghostDownrange).
    SET out["LAT"] TO shifted["LAT"].
    SET out["LNG"] TO shifted["LNG"].
    RETURN out.
}

GLOBAL FUNCTION targetedDeorbitAt {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER ignoredPe IS 0.
    PARAMETER ignoredTolerance IS 0.
    PARAMETER ignoredOvershoot IS 0.

    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available — cannot guarantee targeted deorbit.").
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

    LOCAL ghostTarget IS _deorbitGhostTarget(targetLat, targetLng).
    LOCAL ghostLat IS ghostTarget["LAT"].
    LOCAL ghostLng IS ghostTarget["LNG"].
    LOCAL targetPe IS 0.
    LOCAL targetTolerance IS 10000.
    LOCAL targetGeo IS LATLNG(targetLat, targetLng).
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
        + "  ghost=" + ROUND(ghostLat,4) + "," + ROUND(ghostLng,4)
        + "  Pe=0km  ghostTol=" + ROUND(targetTolerance/1000,1) + "km").
    mLog("Deorbit ghost target: 5000m downrange; TR target remains true site.").
    HUDTEXT("Searching deorbit window...", 3, 2, 13, CYAN, FALSE).

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL orbitSma IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL twoOverOrbitSma IS 2 / orbitSma.
    LOCAL scanOrbits IS 32.
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_ORBITS") {
        IF (CFG["TARGET_DEORBIT_SCAN_ORBITS"]:TYPENAME = "STRING") {
            SET scanOrbits TO CFG["TARGET_DEORBIT_SCAN_ORBITS"]:TONUMBER.
        } ELSE {
            SET scanOrbits TO CFG["TARGET_DEORBIT_SCAN_ORBITS"].
        }
    }
    LOCAL scanSamples IS 2048.
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_SAMPLES") {
        IF (CFG["TARGET_DEORBIT_SCAN_SAMPLES"]:TYPENAME = "STRING") {
            SET scanSamples TO CFG["TARGET_DEORBIT_SCAN_SAMPLES"]:TONUMBER.
        } ELSE {
            SET scanSamples TO CFG["TARGET_DEORBIT_SCAN_SAMPLES"].
        }
    }
    IF CFG:HASKEY("LANDING_SIM_MODE") AND CFG["LANDING_SIM_MODE"] > 0 {
        IF scanOrbits > 2 { SET scanOrbits TO 2. }
        IF scanSamples > 256 { SET scanSamples TO 256. }
    }
    LOCAL scanStart IS nowUt + 30.
    LOCAL scanEnd IS nowUt + period * scanOrbits + 30.
    LOCAL scanMode IS "orbits".
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_CENTER_MINUTES") {
        LOCAL centerMin IS CFG["TARGET_DEORBIT_SCAN_CENTER_MINUTES"].
        LOCAL windowMin IS 4.
        IF CFG:HASKEY("TARGET_DEORBIT_SCAN_WINDOW_MINUTES") {
            SET windowMin TO CFG["TARGET_DEORBIT_SCAN_WINDOW_MINUTES"].
        }
        LOCAL centerUT IS nowUt + centerMin * 60.
        LOCAL halfWin IS MAX(30, windowMin * 30).
        SET scanStart TO MAX(nowUt + 30, centerUT - halfWin).
        SET scanEnd TO centerUT + halfWin.
        SET scanMode TO "minutes".
        IF scanSamples > 256 { SET scanSamples TO 256. }
    }
    // Per-orbit sample density: the scan discovers the pass
    // windows in the first two orbits, then only checks those
    // windows on later orbits (with per-window narrowing).
    LOCAL perOrbit IS MAX(16, ROUND(scanSamples / MAX(1, scanOrbits))).
    LOCAL stepA IS period / perOrbit.
    IF scanMode = "minutes" {
        SET stepA TO (scanEnd - scanStart) / MAX(16, scanSamples).
    }
    LOCAL coarseStopDist IS 10000.
    LOCAL minLead IS _targetDeorbitMinLead().
    LOCAL refineStartLimit IS MAX(targetTolerance * 10, coarseStopDist * 6).

    LOCAL bestUT   IS nowUt + 30.
    LOCAL bestRad  IS 0.
    LOCAL bestNor  IS 0.
    LOCAL bestDist IS 999999999.
    LOCAL validSamples IS 0.

    LOCAL earlyStop IS FALSE.
    LOCAL floorUt IS nowUt + minLead.

    // ── Discovery: uniform scan of the FIRST TWO ORBITS only —
    // enough to learn the per-orbit pass phases (latitude
    // crossings recur at fixed orbital phase; only the longitude
    // under them drifts). Minutes mode scans its whole window.
    LOCAL discoverEnd IS MIN(scanEnd, scanStart + period * 2).
    IF scanMode = "minutes" { SET discoverEnd TO scanEnd. }
    LOCAL dTimes IS LIST().
    LOCAL dDists IS LIST().
    LOCAL focusOffsets IS LIST(-2, -1, 0, 1, 2).
    LOCAL scanUT IS scanStart.
    mLog("Discovery scan to T+" + ROUND(discoverEnd - nowUt, 0)
        + "s step=" + ROUND(stepA, 1) + "s mode=" + scanMode + ".").
    UNTIL scanUT > discoverEnd OR earlyStop {
        LOCAL trialDist IS _evalDeorbitDist(scanUT, targetPe, ghostLat, ghostLng,
            0, 0, bodyR, mu, orbitSma, twoOverOrbitSma,
            minLead).
        IF trialDist >= 0 {
            SET validSamples TO validSamples + 1.
            dTimes:ADD(scanUT).
            dDists:ADD(trialDist).
            IF trialDist < bestDist {
                SET bestDist TO trialDist.
                SET bestUT   TO scanUT.
                mLog("DEBUG coarse: T+" + ROUND(scanUT - nowUt,0)
                    + "s  dist=" + ROUND(bestDist/1000,1) + "km").
                IF bestDist <= coarseStopDist {
                    SET earlyStop TO TRUE.
                }
            }
        } ELSE {
            dTimes:ADD(scanUT).
            dDists:ADD(8.99e15).
        }
        SET scanUT TO scanUT + stepA.
        WAIT 0.
    }

    // Pass phases = local minima of the discovery curve.
    LOCAL phases IS LIST().
    LOCAL di IS 1.
    UNTIL di >= dTimes:LENGTH - 1 {
        IF dDists[di] < dDists[di-1] AND dDists[di] <= dDists[di+1]
                AND dDists[di] < 8e15 {
            LOCAL ph IS MOD(dTimes[di] - scanStart, period).
            LOCAL dup IS FALSE.
            FOR existing IN phases {
                IF ABS(existing - ph) < stepA * 2
                        OR ABS(ABS(existing - ph) - period) < stepA * 2 {
                    SET dup TO TRUE.
                }
            }
            IF NOT dup { phases:ADD(ph). }
        }
        SET di TO di + 1.
    }

    // ── Focus: on every remaining orbit, sample only around each
    // discovered window and NARROW it with halving steps — fixes
    // both costs of the old uniform scan: time wasted far from
    // the target, and good passes straddled by an unlucky step.
    IF NOT earlyStop AND phases:LENGTH > 0 AND scanMode = "orbits" {
        mLog("Focusing " + phases:LENGTH + " pass window(s)/orbit over "
            + scanOrbits + " orbits.").
        LOCAL orbitIdx IS 0.
        UNTIL orbitIdx >= scanOrbits OR earlyStop {
            FOR ph IN phases {
                LOCAL center IS scanStart + ph + orbitIdx * period.
                IF NOT earlyStop AND center > floorUt
                        AND center <= scanEnd + stepA {
                    LOCAL wBest IS 8.99e15.
                    LOCAL wBestT IS center.
                    // Locate the window's time-optimum at surface Pe.
                    FOR off IN focusOffsets {
                        LOCAL tt IS center + off * stepA * 0.66.
                        IF tt > floorUt {
                            LOCAL trDist IS _evalDeorbitDist(tt, targetPe,
                                ghostLat, ghostLng, 0, 0,
                                bodyR, mu, orbitSma, twoOverOrbitSma,
                                minLead).
                            IF trDist >= 0 {
                                SET validSamples TO validSamples + 1.
                                IF trDist < wBest {
                                    SET wBest TO trDist.
                                    SET wBestT TO tt.
                                }
                            }
                        }
                    }
                    // Narrow promising windows to their true minimum
                    // against the ghost target.
                    IF wBest < MAX(bestDist * 1.6, coarseStopDist * 6) {
                        LOCAL hstep IS stepA * 0.5.
                        UNTIL hstep < 0.8 {
                            FOR cand IN LIST(wBestT - hstep, wBestT + hstep) {
                                IF cand > floorUt {
                                    LOCAL tr2Dist IS _evalDeorbitDist(cand,
                                        targetPe, ghostLat, ghostLng, 0, 0,
                                        bodyR, mu, orbitSma, twoOverOrbitSma,
                                        minLead).
                                    IF tr2Dist >= 0
                                            AND tr2Dist < wBest {
                                        SET wBest TO tr2Dist.
                                        SET wBestT TO cand.
                                    }
                                }
                            }
                            SET hstep TO hstep / 2.
                            WAIT 0.
                        }
                    }
                    IF wBest < bestDist {
                        SET bestDist TO wBest.
                        SET bestUT TO wBestT.
                        mLog("DEBUG window: orbit " + orbitIdx
                            + "  T+" + ROUND(wBestT - nowUt, 0)
                            + "s  dist=" + ROUND(wBest / 1000, 1) + "km").
                        IF bestDist <= coarseStopDist {
                            SET earlyStop TO TRUE.
                        }
                    }
                }
            }
            SET orbitIdx TO orbitIdx + 1.
        }
    }
    mLog("Coarse best: T+" + ROUND(bestUT - nowUt,0)
        + "s  dist=" + ROUND(bestDist/1000,1) + "km").

    IF validSamples = 0 {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    IF bestUT <= TIME:SECONDS + minLead {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    IF bestDist > refineStartLimit {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    // Final polish: halving steps around the winner down to
    // sub-second burn timing (replaces the old multi-pass sweep).
    LOCAL fstep IS stepA * 0.5.
    UNTIL fstep < 0.05 {
        FOR cand IN LIST(bestUT - fstep, bestUT + fstep) {
            IF cand > floorUt {
                LOCAL tr3Dist IS _evalDeorbitDist(cand, targetPe,
                    ghostLat, ghostLng, 0, 0,
                    bodyR, mu, orbitSma, twoOverOrbitSma,
                    minLead).
                IF tr3Dist >= 0 AND tr3Dist < bestDist {
                    SET bestDist TO tr3Dist.
                    SET bestUT TO cand.
                }
            }
        }
        SET fstep TO fstep / 2.
        WAIT 0.
    }
    mLog("Polished best: T+" + ROUND(bestUT - nowUt, 0)
        + "s  dist=" + ROUND(bestDist, 0) + "m.").

    // The old iterative impact refinement is RETIRED: it never
    // converged reliably (every recipe set SKIP_REFINE=1) and the
    // post-burn three-leg impact walk does its job better, with
    // measurement instead of prediction. Coarse + pass + walk.

    mLog("Fine best: T+" + ROUND(bestUT - nowUt,0)
        + "s  Pe=" + ROUND(targetPe/1000,1) + "km"
        + "  Rad=" + ROUND(bestRad,2)
        + "  Nor=" + ROUND(bestNor,2)
        + "  ghostDist=" + ROUND(bestDist/1000,1) + "km").

    IF bestDist > targetTolerance {
        mLogWarn("Best solution misses ghost target by " + ROUND(bestDist/1000,1)
            + "km — exceeds tolerance of " + ROUND(targetTolerance/1000,1) + "km.").
        HUDTEXT("Warning: " + ROUND(bestDist/1000,0) + "km from ghost target", 5, 2, 14, YELLOW, FALSE).
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }

    IF bestUT <= TIME:SECONDS + minLead {
        RETURN FALSE.
    }

    LOCAL realNode IS _planDeorbitNode(bestUT, targetPe, bestRad, bestNor,
        bodyR, mu, orbitSma, twoOverOrbitSma).
    IF LAND_CFG_TERRAIN_VALIDATE {
        WAIT 0.1.
        LOCAL crashDist IS lmTerrainClearanceCheck(
            ghostLat, ghostLng,
            bestUT + 30, bestUT + 1800,
            2,
            LAND_CFG_TERRAIN_MIN_CLEARANCE,
            LAND_CFG_TERRAIN_SAFE_ALT).
        IF crashDist > LAND_CFG_TERRAIN_MAX_CRASH_DIST {
            mLogError("TERRAIN CHECK FAILED: trajectory hits terrain "
                + ROUND(crashDist,0) + "m from ghost target.").
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

    // executeDeorbitNode is supplied by deorbit_burn in the LAND_DEORBIT band.
    executeDeorbitNode(realNode).

    WAIT 2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL finalDist IS geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).
        LOCAL finalGhostDist IS geoDistance(impactPos:LAT, impactPos:LNG, ghostLat, ghostLng).
        mLog("Post-burn impact prediction: "
            + ROUND(impactPos:LAT,4) + "," + ROUND(impactPos:LNG,4)
            + "  targetDist=" + ROUND(finalDist/1000,1) + "km"
            + "  ghostDist=" + ROUND(finalGhostDist/1000,1) + "km").
        HUDTEXT("Impact predicted " + ROUND(finalGhostDist/1000,1) + "km from ghost",
            5, 2, 14, GREEN, FALSE).
    } ELSE {
        mLogWarn("Trajectories has no impact prediction post-burn.").
    }
    // The burn fired; the next phase owns the powered descent.
    RETURN TRUE.
}

LOCAL FUNCTION _evalDeorbitDist {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER radialDv.
    PARAMETER normalDv.
    PARAMETER bodyR.
    PARAMETER mu.
    PARAMETER orbitSma.
    PARAMETER twoOverOrbitSma.
    PARAMETER minLead.

    IF burnUT <= TIME:SECONDS + minLead { RETURN -1. }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planDeorbitNode(burnUT, entryPe, radialDv, normalDv,
        bodyR, mu, orbitSma, twoOverOrbitSma).
    WAIT 0.2.

    IF NOT ADDONS:TR:HASIMPACT {
        REMOVE nd.
        RETURN -1.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS geoDistance(impactPos:LAT, impactPos:LNG,
        targetLat, targetLng).
    REMOVE nd.
    RETURN dist.
}



LOCAL FUNCTION _targetDeorbitMinLead {
    LOCAL minLead IS 60.
    IF CFG:HASKEY("TARGET_DEORBIT_MIN_LEAD") {
        SET minLead TO CFG["TARGET_DEORBIT_MIN_LEAD"].
    }
    RETURN minLead.
}

LOCAL FUNCTION _planDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER radialDv IS 0.
    PARAMETER normalDv IS 0.
    PARAMETER bodyR IS -1.
    PARAMETER mu IS -1.
    PARAMETER orbitSma IS -1.
    PARAMETER twoOverOrbitSma IS -1.

    IF bodyR < 0 { SET bodyR TO SHIP:ORBIT:BODY:RADIUS. }
    IF mu < 0 { SET mu TO SHIP:ORBIT:BODY:MU. }
    IF orbitSma < 0 { SET orbitSma TO SHIP:ORBIT:SEMIMAJORAXIS. }
    IF twoOverOrbitSma < 0 { SET twoOverOrbitSma TO 2 / orbitSma. }
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL rPe IS bodyR + entryPe.
    LOCAL tSMA IS (orbitSma + rPe) / 2.
    LOCAL radicand IS twoOverOrbitSma - 1 / tSMA.
    IF radicand <= 0 { SET radicand TO 0. }
    LOCAL vNew IS SQRT(mu * radicand).
    LOCAL dv   IS vNew - vNow.

    LOCAL nd IS NODE(burnUT, radialDv, normalDv, dv).
    ADD nd.
    RETURN nd.
}

GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.
}
