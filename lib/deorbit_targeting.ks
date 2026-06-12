// ============================================================
// deorbit_targeting.ks  —  Precision deorbit targeting  (0:/lib/deorbit_targeting.ks)
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

LOCAL FUNCTION _deorbitNorm180 {
    PARAMETER angle.
    LOCAL result IS angle.
    UNTIL result >= -180 { SET result TO result + 360. }
    UNTIL result < 180 { SET result TO result - 360. }
    RETURN result.
}

// Post-burn finesse, three measured legs: along-track creep
// (prograde/retrograde slides the impact along the ground
// track), then CROSS-TRACK (normal-direction burns shift the
// track laterally — the only fix for pass-selection error, and
// the difference between 6km and 2km tolerances), then a final
// along-track touch-up. The normal direction's sign is MEASURED
// with a 1.5 m/s test pulse — never trust a cross product's sign
// in this left-handed frame; VCRS here only builds the axis.
// Budget-capped at 45 m/s; every leg is alignment-gated.
LOCAL FUNCTION _walkDist {
    PARAMETER targetLat.
    PARAMETER targetLng.
    IF NOT ADDONS:TR:HASIMPACT { RETURN -1. }
    LOCAL imp IS ADDONS:TR:IMPACTPOS.
    RETURN geoDistance(imp:LAT, imp:LNG, targetLat, targetLng).
}

LOCAL FUNCTION _deorbitImpactWalk {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER tolerance.
    IF NOT (ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT) { RETURN. }
    IF SHIP:AVAILABLETHRUST <= 0 { RETURN. }
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.
    LOCAL bullseye IS MAX(500, tolerance * 0.15).
    LOCAL dvCap IS 45.
    LOCAL dvSpent IS 0.
    LOCAL sgnN IS 1.
    LOCAL walkDeadline IS TIME:SECONDS + 420.
    LOCAL startDist IS _walkDist(targetLat, targetLng).
    IF startDist >= 0 AND startDist <= bullseye { RETURN. }
    mLog("Impact walk: " + ROUND(startDist / 1000, 1)
        + "km to close (bullseye " + ROUND(bullseye, 0) + "m).").

    LOCAL throttleCmd IS 0.
    FOR mode IN LIST("along", "cross", "along") {
        IF TIME:SECONDS > walkDeadline OR dvSpent >= dvCap { BREAK. }
        IF SHIP:AVAILABLETHRUST <= 0 { BREAK. }
        WAIT 2.   // let Trajectories settle before judging the leg
        LOCAL d0 IS _walkDist(targetLat, targetLng).
        IF d0 >= 0 AND d0 <= bullseye { BREAK. }

        LOCAL goPro IS TRUE.
        IF mode = "along" {
            SET goPro TO
                _deorbitNorm180(targetLng - ADDONS:TR:IMPACTPOS:LNG) > 0.
            IF goPro { LOCK STEERING TO SHIP:PROGRADE. }
            ELSE { LOCK STEERING TO SHIP:RETROGRADE. }
        } ELSE {
            // Cross burns fix pass-selection residue (2-15km);
            // a large miss is along-track damage they cannot
            // touch (flight-found: 45 m/s chased 189km for ~2km).
            IF d0 > 30000 {
                mLogWarn("Walk: skipping cross leg — "
                    + ROUND(d0 / 1000, 0) + "km is along-track scale.").
                BREAK.
            }
            LOCK STEERING TO sgnN * VCRS(SHIP:VELOCITY:ORBIT,
                SHIP:POSITION - SHIP:BODY:POSITION).
        }
        LOCAL legPe0 IS SHIP:PERIAPSIS.
        LOCAL legDv0 IS dvSpent.
        mLog("Walk leg (" + mode
            + (CHOOSE "/prograde" IF mode = "along" AND goPro
               ELSE CHOOSE "/retrograde" IF mode = "along" ELSE "")
            + "): " + ROUND(d0 / 1000, 1) + "km off.").

        LOCAL alignDeadline IS TIME:SECONDS + 90.
        UNTIL VANG(SHIP:FACING:FOREVECTOR,
                CHOOSE ((CHOOSE 1 IF goPro ELSE -1) * SHIP:VELOCITY:ORBIT)
                    IF mode = "along"
                ELSE (sgnN * VCRS(SHIP:VELOCITY:ORBIT,
                    SHIP:POSITION - SHIP:BODY:POSITION))) < 5
                OR TIME:SECONDS > alignDeadline {
            WAIT 0.2.
        }
        LOCK THROTTLE TO throttleCmd.

        LOCAL dMin IS 1e12.
        LOCAL nextLog IS 0.
        LOCAL nextPulse IS 0.
        LOCAL reason IS "".
        IF mode = "along" {
            // The lng-difference direction guess INVERTS on
            // descending polar passes (flight-found: a retrograde
            // leg grew an 18.7km miss to 69km — target ahead
            // along-track but west in longitude). Verify with a
            // single-tick micro-pulse and flip if it hurt.
            LOCK THROTTLE TO 0.012.
            WAIT 0.05.
            LOCK THROTTLE TO 0.
            SET dvSpent TO dvSpent
                + (SHIP:AVAILABLETHRUST / MAX(0.1, SHIP:MASS))
                  * 0.012 * 0.05.
            WAIT 2.
            LOCAL dProbe IS _walkDist(targetLat, targetLng).
            IF dProbe >= 0 AND d0 >= 0 AND dProbe > d0 + 200 {
                SET goPro TO NOT goPro.
                mLog("Along leg: measured flip — lng heuristic"
                    + " wrong for this pass geometry.").
                IF goPro { LOCK STEERING TO SHIP:PROGRADE. }
                ELSE { LOCK STEERING TO SHIP:RETROGRADE. }
                LOCAL flipDeadline IS TIME:SECONDS + 90.
                UNTIL VANG(SHIP:FACING:FOREVECTOR,
                        (CHOOSE 1 IF goPro ELSE -1)
                        * SHIP:VELOCITY:ORBIT) < 5
                        OR TIME:SECONDS > flipDeadline {
                    WAIT 0.2.
                }
            }
        }
        IF mode = "cross" {
            // Measured sign: 1.5 m/s test pulse, flip if it hurt.
            LOCAL v0 IS SHIP:VELOCITY:ORBIT.
            LOCAL pulseDeadline IS TIME:SECONDS + 30.
            UNTIL (SHIP:VELOCITY:ORBIT - v0):MAG >= 0.8
                    OR TIME:SECONDS > pulseDeadline {
                IF VANG(SHIP:FACING:FOREVECTOR,
                        sgnN * VCRS(SHIP:VELOCITY:ORBIT,
                            SHIP:POSITION - SHIP:BODY:POSITION)) < 10 {
                    SET throttleCmd TO 0.05.
                } ELSE {
                    SET throttleCmd TO 0.
                }
                WAIT 0.05.
            }
            SET throttleCmd TO 0.
            SET dvSpent TO dvSpent + (SHIP:VELOCITY:ORBIT - v0):MAG.
            WAIT 3.
            LOCAL d1 IS _walkDist(targetLat, targetLng).
            IF d1 >= 0 AND d0 >= 0 AND ABS(d1 - d0) < 300 {
                // The pulse barely moved the miss: the error is
                // along-track, which lateral burns only worsen
                // (in quadrature, EITHER direction — flight-found
                // masquerading as a sign flip). Nothing to do here.
                SET reason TO "cross-unobservable".
                mLog("Cross test pulse moved the impact only "
                    + ROUND(ABS(d1 - d0), 0)
                    + "m — miss is not lateral; skipping leg.").
            } ELSE IF d1 >= 0 AND d0 >= 0 AND d1 > d0 {
                SET sgnN TO -sgnN.
                mLog("Cross-track: measured flip to the other side.").
                LOCAL flipDeadline IS TIME:SECONDS + 90.
                UNTIL VANG(SHIP:FACING:FOREVECTOR,
                        sgnN * VCRS(SHIP:VELOCITY:ORBIT,
                            SHIP:POSITION - SHIP:BODY:POSITION)) < 5
                        OR TIME:SECONDS > flipDeadline {
                    WAIT 0.2.
                }
            }
        }

        UNTIL reason <> "" {
            LOCAL aimVec IS V(0, 0, 0).
            IF mode = "along" {
                SET aimVec TO (CHOOSE 1 IF goPro ELSE -1)
                    * SHIP:VELOCITY:ORBIT.
            } ELSE {
                SET aimVec TO sgnN * VCRS(SHIP:VELOCITY:ORBIT,
                    SHIP:POSITION - SHIP:BODY:POSITION).
            }
            LOCAL aligned IS VANG(SHIP:FACING:FOREVECTOR, aimVec) < 10.
            LOCAL d IS _walkDist(targetLat, targetLng).
            IF SHIP:AVAILABLETHRUST <= 0 {
                SET reason TO "out-of-fuel".
            } ELSE IF TIME:SECONDS > walkDeadline {
                SET reason TO "timeout".
            } ELSE IF dvSpent >= dvCap {
                SET reason TO "dv-cap".
            } ELSE IF dvSpent - legDv0
                    > (CHOOSE 1.0 IF mode = "along" ELSE 6)
                    AND dMin > d0 - 300 {
                // 6 m/s in and the minimum hasn't improved: this
                // leg is fighting the wrong axis (flight-found:
                // a cross leg monotonically worsening an
                // along-track residual). Stop wasting the budget.
                SET reason TO "ineffective".
            } ELSE IF SHIP:PERIAPSIS < 9000 {
                SET reason TO "pe-floor".
            } ELSE IF mode = "along"
                    AND ABS(SHIP:PERIAPSIS - legPe0) > 6000 {
                // A post-deorbit along fix needs <1 m/s; moving Pe
                // 6km means the leg is out of control (flight-
                // found: 18km of Pe damage before the old floor).
                SET reason TO "pe-excursion".
            } ELSE IF mode = "along" AND goPro
                    AND SHIP:PERIAPSIS > atmTop - 5000 {
                SET reason TO "pe-ceiling".
            } ELSE IF d >= 0 {
                IF d < dMin { SET dMin TO d. }
                IF d <= bullseye {
                    SET reason TO "on-target".
                } ELSE IF dMin < d0 - 200
                        AND d > dMin * 1.3 + 300 {
                    // Armed as soon as the leg has IMPROVED —
                    // scale-free (flight-found: a tolerance-scaled
                    // gate disarmed this at 2km tolerance and the
                    // leg blew through its minimum unbraked).
                    SET reason TO "past-closest".
                }
            }
            IF NOT aligned {
                SET throttleCmd TO 0.
            } ELSE IF mode = "along" {
                // Post-deorbit sensitivity: ~1 m/s moves the
                // impact tens of km AND Trajectories needs a beat
                // to settle. Below 15km: single-tick micro-pulses
                // (~0.6km each) with a settle gap — measurement-
                // paced (flight-found: continuous creep overshot
                // a 0.3km minimum out to 10km between readings).
                IF d >= 0 AND d < 15000 {
                    IF TIME:SECONDS > nextPulse {
                        SET throttleCmd TO 0.012.
                        SET nextPulse TO TIME:SECONDS + 1.2.
                    } ELSE {
                        SET throttleCmd TO 0.
                    }
                } ELSE {
                    SET throttleCmd TO 0.02.
                }
            } ELSE {
                SET throttleCmd TO
                    CHOOSE 0.02 IF d >= 0 AND d < tolerance * 3
                    ELSE CHOOSE 0.05 IF d >= 0 AND d < tolerance * 10
                    ELSE 0.15.
            }
            SET dvSpent TO dvSpent
                + (SHIP:AVAILABLETHRUST / MAX(0.1, SHIP:MASS))
                  * throttleCmd * 0.05.
            IF TIME:SECONDS > nextLog {
                SET nextLog TO TIME:SECONDS + 8.
                mLog("Walk[" + mode + "]: "
                    + (CHOOSE ROUND(d / 1000, 2) + "km off" IF d >= 0
                       ELSE "(no prediction)")
                    + "  dv=" + ROUND(dvSpent, 1)
                    + "  Pe=" + ROUND(SHIP:PERIAPSIS / 1000, 1) + "km.").
            }
            WAIT 0.05.
        }
        SET throttleCmd TO 0.
        mLog("Walk leg (" + mode + ") done: " + reason + ".").
        IF reason = "on-target" OR reason = "out-of-fuel"
                OR reason = "timeout" OR reason = "dv-cap" { BREAK. }
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLogWarn("STATS deorbit walk distKm="
        + ROUND(MAX(-1, _walkDist(targetLat, targetLng)) / 1000, 2)
        + " dvSpent=" + ROUND(dvSpent, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)).
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

    LOCAL site IS LEXICON("FOUND", FALSE).
    IF DEFINED BOOT_LIB_RAN AND BOOT_LIB_RAN:CONTAINS("landing_site") {
        SET site TO selectScanSatLandingSite(targetLat, targetLng).
    }
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
    LOCAL scanSamples IS 2048.
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_SAMPLES") {
        SET scanSamples TO CFG["TARGET_DEORBIT_SCAN_SAMPLES"].
    }
    IF CFG:HASKEY("LANDING_SIM_MODE") AND CFG["LANDING_SIM_MODE"] > 0 {
        IF scanOrbits > 2 { SET scanOrbits TO 2. }
        IF scanSamples > 256 { SET scanSamples TO 256. }
        mLogWarn("STATS deorbit scan mode=sim scanOrbits="
            + scanOrbits + " samples=" + scanSamples).
    }
    LOCAL scanStart IS TIME:SECONDS + 30.
    LOCAL scanEnd IS TIME:SECONDS + period * scanOrbits + 30.
    LOCAL scanMode IS "orbits".
    IF CFG:HASKEY("TARGET_DEORBIT_SCAN_CENTER_MINUTES") {
        LOCAL centerMin IS CFG["TARGET_DEORBIT_SCAN_CENTER_MINUTES"].
        LOCAL windowMin IS 4.
        IF CFG:HASKEY("TARGET_DEORBIT_SCAN_WINDOW_MINUTES") {
            SET windowMin TO CFG["TARGET_DEORBIT_SCAN_WINDOW_MINUTES"].
        }
        LOCAL centerUT IS TIME:SECONDS + centerMin * 60.
        LOCAL halfWin IS MAX(30, windowMin * 30).
        SET scanStart TO MAX(TIME:SECONDS + 30, centerUT - halfWin).
        SET scanEnd TO centerUT + halfWin.
        SET scanMode TO "minutes".
        IF scanSamples > 256 { SET scanSamples TO 256. }
        mLogWarn("STATS deorbit scan window centerMin="
            + ROUND(centerMin,1)
            + " windowMin=" + ROUND(windowMin,1)
            + " startT=" + ROUND(scanStart - TIME:SECONDS,0)
            + " endT=" + ROUND(scanEnd - TIME:SECONDS,0)
            + " samples=" + scanSamples).
    }
    // Per-orbit sample density: the scan discovers the pass
    // windows in the first two orbits, then only checks those
    // windows on later orbits (with per-window narrowing).
    LOCAL perOrbit IS MAX(16, ROUND(scanSamples / MAX(1, scanOrbits))).
    LOCAL stepA IS period / perOrbit.
    IF scanMode = "minutes" {
        SET stepA TO (scanEnd - scanStart) / MAX(16, scanSamples).
    }
    LOCAL coarseStopDist IS 1000.
    IF SHIP:BODY:ATM:EXISTS {
        SET coarseStopDist TO tolerance.
    } ELSE IF SHIP:BODY:NAME = "MUN" {
        SET coarseStopDist TO 8000.
    }
    IF CFG:HASKEY("TARGET_DEORBIT_COARSE_STOP_DIST") {
        SET coarseStopDist TO CFG["TARGET_DEORBIT_COARSE_STOP_DIST"].
    }
    LOCAL minLead IS _targetDeorbitMinLead().
    LOCAL refineStartLimit IS MAX(tolerance * 10, coarseStopDist * 6).
    IF CFG:HASKEY("TARGET_DEORBIT_REFINE_MAX_START_DIST") {
        SET refineStartLimit TO CFG["TARGET_DEORBIT_REFINE_MAX_START_DIST"].
    }

    LOCAL bestUT   IS TIME:SECONDS + 30.
    LOCAL bestPe   IS entryPe.
    LOCAL bestRad  IS 0.
    LOCAL bestNor  IS 0.
    LOCAL bestDist IS 999999999.
    LOCAL validSamples IS 0.
    LOCAL invalidSamples IS 0.

    LOCAL earlyStop IS FALSE.
    LOCAL floorUt IS TIME:SECONDS + minLead.

    // ── Discovery: uniform scan of the FIRST TWO ORBITS only —
    // enough to learn the per-orbit pass phases (latitude
    // crossings recur at fixed orbital phase; only the longitude
    // under them drifts). Minutes mode scans its whole window.
    LOCAL discoverEnd IS MIN(scanEnd, scanStart + period * 2).
    IF scanMode = "minutes" { SET discoverEnd TO scanEnd. }
    LOCAL dTimes IS LIST().
    LOCAL dDists IS LIST().
    LOCAL scanUT IS scanStart.
    mLog("Discovery scan to T+" + ROUND(discoverEnd - TIME:SECONDS, 0)
        + "s step=" + ROUND(stepA, 1) + "s mode=" + scanMode + ".").
    UNTIL scanUT > discoverEnd OR earlyStop {
        LOCAL trial IS _evalDeorbitNode(scanUT, entryPe, targetLat, targetLng).
        IF trial["VALID"] {
            SET validSamples TO validSamples + 1.
            dTimes:ADD(scanUT).
            dDists:ADD(trial["DIST"]).
            IF trial["DIST"] < bestDist {
                SET bestDist TO trial["DIST"].
                SET bestUT   TO scanUT.
                SET bestPe   TO entryPe.
                mLog("DEBUG coarse: T+" + ROUND(scanUT - TIME:SECONDS,0)
                    + "s  dist=" + ROUND(bestDist/1000,1) + "km").
                IF bestDist <= coarseStopDist {
                    mLogWarn("STATS deorbit coarse early-stop distKm="
                        + ROUND(bestDist/1000,2)
                        + " burnT=" + ROUND(scanUT - TIME:SECONDS,0)).
                    SET earlyStop TO TRUE.
                }
            }
        } ELSE {
            SET invalidSamples TO invalidSamples + 1.
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
                    FOR off IN LIST(-2, -1, 0, 1, 2) {
                        LOCAL tt IS center + off * stepA * 0.66.
                        IF tt > floorUt {
                            LOCAL tr IS _evalDeorbitNode(tt, entryPe,
                                targetLat, targetLng).
                            IF tr["VALID"] {
                                SET validSamples TO validSamples + 1.
                                IF tr["DIST"] < wBest {
                                    SET wBest TO tr["DIST"].
                                    SET wBestT TO tt.
                                }
                            } ELSE {
                                SET invalidSamples TO invalidSamples + 1.
                            }
                        }
                    }
                    // Narrow promising windows to their true minimum.
                    IF wBest < MAX(bestDist * 1.6, coarseStopDist * 6) {
                        LOCAL hstep IS stepA * 0.5.
                        UNTIL hstep < 0.8 {
                            FOR cand IN LIST(wBestT - hstep, wBestT + hstep) {
                                IF cand > floorUt {
                                    LOCAL tr2 IS _evalDeorbitNode(cand,
                                        entryPe, targetLat, targetLng).
                                    IF tr2["VALID"]
                                            AND tr2["DIST"] < wBest {
                                        SET wBest TO tr2["DIST"].
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
                        SET bestPe TO entryPe.
                        mLog("DEBUG window: orbit " + orbitIdx
                            + "  T+" + ROUND(wBestT - TIME:SECONDS, 0)
                            + "s  dist=" + ROUND(wBest / 1000, 1) + "km").
                        IF bestDist <= coarseStopDist {
                            mLogWarn("STATS deorbit window early-stop distKm="
                                + ROUND(bestDist/1000, 2)
                                + " burnT=" + ROUND(bestUT - TIME:SECONDS, 0)).
                            SET earlyStop TO TRUE.
                        }
                    }
                }
            }
            SET orbitIdx TO orbitIdx + 1.
        }
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

    IF validSamples = 0 {
        mLogWarn("STATS deorbit abort reason=no-valid-coarse-samples").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    IF bestUT <= TIME:SECONDS + minLead {
        mLogWarn("STATS deorbit abort reason=window-expired burnT="
            + ROUND(bestUT - TIME:SECONDS,0)
            + " minLead=" + ROUND(minLead,0)
            + " distKm=" + ROUND(bestDist/1000,1)).
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    IF bestDist > refineStartLimit {
        // Best-effort missions (TARGET_DEORBIT_PROCEED_ON_MISS)
        // fly the best pass found no matter how far — this gate
        // was vetoing them before the proceed logic had a say
        // (flight-found: a 98deg polar splashdown held at 224km).
        LOCAL proceedOnMiss IS CFG:HASKEY("TARGET_DEORBIT_PROCEED_ON_MISS")
            AND CFG["TARGET_DEORBIT_PROCEED_ON_MISS"] > 0.
        IF proceedOnMiss {
            mLogWarn("Coarse best " + ROUND(bestDist/1000,1)
                + "km exceeds refine-start limit "
                + ROUND(refineStartLimit/1000,1)
                + "km — proceeding anyway (best-effort mode).").
        } ELSE {
            mLogWarn("STATS deorbit abort reason=coarse-miss-too-large distKm="
                + ROUND(bestDist/1000,1)
                + " refineStartLimitKm=" + ROUND(refineStartLimit/1000,1)
                + " toleranceKm=" + ROUND(tolerance/1000,1)).
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
            RETURN FALSE.
        }
    }

    // Final polish: halving steps around the winner down to
    // sub-second burn timing (replaces the old multi-pass sweep).
    LOCAL fstep IS stepA * 0.5.
    UNTIL fstep < 0.05 {
        FOR cand IN LIST(bestUT - fstep, bestUT + fstep) {
            IF cand > floorUt {
                LOCAL tr3 IS _evalDeorbitNode(cand, entryPe,
                    targetLat, targetLng).
                IF tr3["VALID"] AND tr3["DIST"] < bestDist {
                    SET bestDist TO tr3["DIST"].
                    SET bestUT TO cand.
                }
            }
        }
        SET fstep TO fstep / 2.
        WAIT 0.
    }
    mLog("Polished best: T+" + ROUND(bestUT - TIME:SECONDS, 0)
        + "s  dist=" + ROUND(bestDist, 0) + "m.").

    // The old iterative impact refinement is RETIRED: it never
    // converged reliably (every recipe set SKIP_REFINE=1) and the
    // post-burn three-leg impact walk does its job better, with
    // measurement instead of prediction. Coarse + pass + walk.

    mLog("Fine best: T+" + ROUND(bestUT - TIME:SECONDS,0)
        + "s  Pe=" + ROUND(bestPe/1000,1) + "km"
        + "  Rad=" + ROUND(bestRad,2)
        + "  Nor=" + ROUND(bestNor,2)
        + "  dist=" + ROUND(bestDist/1000,1) + "km").
    LOCAL deorbitStatus IS "ok".
    IF bestDist > tolerance { SET deorbitStatus TO "miss". }
    LOCAL finalEval IS _evalDeorbitNode(bestUT, bestPe, targetLat, targetLng, bestRad, bestNor).
    mLogWarn("STATS deorbit final status=" + deorbitStatus
        + " distKm=" + ROUND(bestDist/1000,1)
        + " toleranceKm=" + ROUND(tolerance/1000,1)
        + " burnT=" + ROUND(bestUT - TIME:SECONDS,0)
        + " PeKm=" + ROUND(bestPe/1000,1)
        + " radial=" + ROUND(bestRad,2)
        + " normal=" + ROUND(bestNor,2)
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
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
            RETURN FALSE.
        }
        mLogWarn("Proceeding anyway — check orbital inclination vs target latitude.").
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }

    IF bestUT <= TIME:SECONDS + minLead {
        mLogWarn("STATS deorbit abort reason=burn-too-soon-after-refine burnT="
            + ROUND(bestUT - TIME:SECONDS,0)
            + " minLead=" + ROUND(minLead,0)
            + " distKm=" + ROUND(bestDist/1000,1)).
        RETURN FALSE.
    }

    LOCAL realNode IS _planDeorbitNode(bestUT, bestPe, bestRad, bestNor).
    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    archiveLog().
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s", 3, 2, 13, CYAN, FALSE).

    // Use lightweight burn executor from payload_landing (no maneuver.ks needed)
    executeDeorbitNode(realNode).

    WAIT 2.
    // Finesse pass: slide the impact the rest of the way.
    _deorbitImpactWalk(targetLat, targetLng, tolerance).

    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL finalDist IS geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).
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
        }
    } ELSE {
        mLogWarn("Trajectories has no impact prediction post-burn.").
    }
    // The burn FIRED: with Pe in the atmosphere the ship is
    // committed to entry, and the only forward path is DESCENT —
    // flight-found: returning FALSE here held the phase while the
    // crew fell toward 30km with no chutes armed.
    IF SHIP:PERIAPSIS < SHIP:BODY:ATM:HEIGHT {
        RETURN TRUE.
    }
    RETURN FALSE.
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


LOCAL FUNCTION _evalDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER radialDv IS 0.
    PARAMETER normalDv IS 0.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "UT", burnUT,
        "PE", entryPe,
        "RAD", radialDv,
        "NOR", normalDv,
        "DIST", 999999999,
        "LAT", 0,
        "LNG", 0
    ).

    IF burnUT <= TIME:SECONDS + _targetDeorbitMinLead() { RETURN result. }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planDeorbitNode(burnUT, entryPe, radialDv, normalDv).
    WAIT 0.2.

    IF NOT ADDONS:TR:HASIMPACT {
        REMOVE nd.
        RETURN result.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    SET result["VALID"] TO TRUE.
    SET result["LAT"] TO impactPos:LAT.
    SET result["LNG"] TO impactPos:LNG.
    SET result["DIST"] TO geoDistance(impactPos:LAT, impactPos:LNG, targetLat, targetLng).

    REMOVE nd.
    RETURN result.
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

    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL oRad IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL rPe  IS SHIP:ORBIT:BODY:RADIUS + entryPe.
    LOCAL tSMA IS (oRad + rPe) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2/oRad - 1/tSMA)).
    LOCAL dv   IS vNew - vNow.

    // Clamp retrograde dV to configurable min/max bounds.
    // From low orbits the Hohmann dV is tiny; the floor ensures a
    // steep ballistic trajectory that overshoots the target so the
    // suicide burn can steer onto it during descent.
    IF DEFINED CFG {
        LOCAL minDV IS 0.
        LOCAL maxDV IS 99999.
        IF CFG:HASKEY("LANDING_DEORBIT_MIN_DV") { SET minDV TO CFG["LANDING_DEORBIT_MIN_DV"]. }
        IF CFG:HASKEY("LANDING_DEORBIT_MAX_DV") { SET maxDV TO CFG["LANDING_DEORBIT_MAX_DV"]. }
        IF minDV > 0 OR maxDV < 99999 {
            SET dv TO MIN(-minDV, MAX(-maxDV, dv)).
        }
    }

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

// ============================================================
// phaseKscDeorbit — KSC_DEORBIT phase: Trajectories-targeted
// deorbit from Kerbin orbit toward the splashdown point just
// offshore of KSC (or wherever LANDING_TARGET_LAT/LNG says).
// Pairs with the DESCENT phase for fully automatic landings:
//   SEQUENCE = KSC_DEORBIT,DESCENT,DONE   (cmd/landatksc.ks)
//
// CFG keys (defaults): LANDING_TARGET_WAYPOINT (wins when set —
//   a Waypoint Manager waypoint name on the current body),
//   LANDING_TARGET_LAT (-0.10), LANDING_TARGET_LNG (-74.25),
//   REENTRY_PE (30000), LANDING_TARGET_TOLERANCE (15000), plus
//   the TARGET_DEORBIT_* scan settings shared with the landing
//   flows.
// ============================================================
// Landing-site biome check against the SCANsat map. TRUE when
// the mapped biome at lat/lng substring-matches any token.
LOCAL FUNCTION _biomeMatchesAt {
    PARAMETER chkLat.
    PARAMETER chkLng.
    PARAMETER tokens.
    LOCAL nm IS ADDONS:SCANSAT:GETBIOME(SHIP:BODY, LATLNG(chkLat, chkLng)).
    IF nm = "" OR nm = "unknown" { RETURN FALSE. }
    LOCAL lower IS nm:TOLOWER.
    FOR tok IN tokens {
        IF lower:CONTAINS(tok) { RETURN TRUE. }
    }
    RETURN FALSE.
}

// When LANDING_TARGET_BIOMES is set (CSV, e.g. "ice, tundra"),
// verify the target sits in one of them on the SCANsat biome map
// — the mapping mission's data becomes the crewed mission's site
// survey. On a mismatch, grid-search reachable latitudes near
// the target longitude for the closest-to-pole match.
LOCAL FUNCTION _resolveBiomeTarget {
    PARAMETER lat0.
    PARAMETER lng0.
    LOCAL out IS LEXICON("LAT", lat0, "LNG", lng0).
    IF NOT CFG:HASKEY("LANDING_TARGET_BIOMES") { RETURN out. }
    IF NOT ADDONS:SCANSAT:AVAILABLE { RETURN out. }
    LOCAL tokens IS LIST().
    FOR tok IN CFG["LANDING_TARGET_BIOMES"]:SPLIT(",") {
        IF tok:TRIM <> "" { tokens:ADD(tok:TRIM:TOLOWER). }
    }
    IF tokens:LENGTH = 0 { RETURN out. }
    IF _biomeMatchesAt(lat0, lng0, tokens) {
        mLog("Landing target biome confirmed on the SCANsat map.").
        RETURN out.
    }

    LOCAL maxLat IS SHIP:ORBIT:INCLINATION - 1.
    IF maxLat > 89 { SET maxLat TO 89. }
    LOCAL latStep IS 1.5.
    LOCAL tryLat IS maxLat.
    UNTIL tryLat < maxLat - 18 {
        LOCAL lngOff IS 0.
        UNTIL lngOff > 60 {
            FOR sgn IN LIST(1, -1) {
                LOCAL tryLng IS lng0 + sgn * lngOff.
                IF _biomeMatchesAt(tryLat, tryLng, tokens) {
                    mLog("Biome site found: " + ROUND(tryLat, 2) + ","
                        + ROUND(tryLng, 2) + " ("
                        + ADDONS:SCANSAT:GETBIOME(SHIP:BODY,
                            LATLNG(tryLat, tryLng)) + ").").
                    SET out["LAT"] TO tryLat.
                    SET out["LNG"] TO tryLng.
                    RETURN out.
                }
            }
            SET lngOff TO lngOff + 10.
        }
        SET tryLat TO tryLat - latStep.
    }
    mLogWarn("No mapped " + CFG["LANDING_TARGET_BIOMES"]
        + " site found near the target — is the biome map scanned"
        + " there? Keeping the configured target.").
    RETURN out.
}

GLOBAL FUNCTION phaseKscDeorbit {
    LOCAL lat IS -0.10.
    LOCAL lng IS -74.25.
    LOCAL entryPe IS 30000.
    LOCAL tol IS 15000.
    IF CFG:HASKEY("LANDING_TARGET_LAT") { SET lat TO CFG["LANDING_TARGET_LAT"]. }
    IF CFG:HASKEY("LANDING_TARGET_LNG") { SET lng TO CFG["LANDING_TARGET_LNG"]. }
    IF CFG:HASKEY("REENTRY_PE") { SET entryPe TO CFG["REENTRY_PE"]. }
    IF CFG:HASKEY("LANDING_TARGET_TOLERANCE") { SET tol TO CFG["LANDING_TARGET_TOLERANCE"]. }
    IF CFG:HASKEY("LANDING_TARGET_WAYPOINT")
            AND CFG["LANDING_TARGET_WAYPOINT"] <> "" {
        LOCAL namedWp IS waypointNamed(CFG["LANDING_TARGET_WAYPOINT"]).
        IF namedWp:ISTYPE("Waypoint") {
            SET lat TO namedWp:GEOPOSITION:LAT.
            SET lng TO namedWp:GEOPOSITION:LNG.
            mLog("Deorbit target from waypoint '" + namedWp:NAME + "'.").
        } ELSE {
            mLogError("KSC_DEORBIT: waypoint '"
                + CFG["LANDING_TARGET_WAYPOINT"] + "' not found on "
                + SHIP:BODY:NAME + " — holding.").
            yieldToPrompt().
            RETURN.
        }
    }

    IF SHIP:BODY:NAME <> "Kerbin" {
        mLogError("KSC_DEORBIT: not in Kerbin SOI (body="
            + SHIP:BODY:NAME + ") — holding.").
        yieldToPrompt().
        RETURN.
    }
    LOCAL biomeSite IS _resolveBiomeTarget(lat, lng).
    SET lat TO biomeSite["LAT"].
    SET lng TO biomeSite["LNG"].

    IF NOT targetReachable(lat) {
        mLogError("KSC_DEORBIT: target lat " + ROUND(lat, 2)
            + " unreachable from inc "
            + ROUND(SHIP:ORBIT:INCLINATION, 2) + " — holding.").
        yieldToPrompt().
        RETURN.
    }
    // Resume safety: a reboot after the burn lands here with the
    // periapsis already in the atmosphere — nothing left to do.
    IF SHIP:PERIAPSIS < SHIP:BODY:ATM:HEIGHT {
        mLog("KSC_DEORBIT: Pe already in atmosphere ("
            + ROUND(SHIP:PERIAPSIS / 1000, 1) + "km) — proceeding to descent.").
        nextPhase(xferSeq).
        RETURN.
    }

    // ORBIT_STAY_TIME: stay in orbit this many seconds (from orbit
    // insertion, or launch as fallback) before the return leg —
    // tourist/experience contracts. KAC-alarmed, reboot-safe.
    LOCAL stayTime IS 0.
    IF CFG:HASKEY("ORBIT_STAY_TIME") { SET stayTime TO CFG["ORBIT_STAY_TIME"]. }
    IF stayTime > 0 {
        LOCAL baseUt IS stateGetNum("orbit_start_time",
            stateGetNum("launch_time", TIME:SECONDS)).
        LOCAL resumeUt IS baseUt + stayTime.
        IF resumeUt > TIME:SECONDS + 30 {
            mLog("KSC_DEORBIT: holding in orbit "
                + ROUND(resumeUt - TIME:SECONDS, 0)
                + "s more (ORBIT_STAY_TIME=" + ROUND(stayTime, 0) + ").").
            LOCAL alarmId IS kacEnsureAlarm(
                "Return window: " + SHIP:NAME, resumeUt - 60,
                "Auto-created by KSC_DEORBIT").
            UNLOCK STEERING.
            trySolarOrient().
            SET SAS TO TRUE.
            // Biome announcer for crewed stays: call out biome
            // crossings so EVA reports can be timed (SCANsat's
            // CURRENTBIOME needs a crewed pod or KerbNet).
            // EVA_BIOMES (CSV, substring match): crossings into
            // these drop out of warp so the crew can get outside.
            LOCAL evaBiomes IS LIST().
            IF CFG:HASKEY("EVA_BIOMES") {
                FOR tok IN CFG["EVA_BIOMES"]:SPLIT(",") {
                    IF tok:TRIM <> "" { evaBiomes:ADD(tok:TRIM:TOLOWER). }
                }
            }
            LOCAL lastBiome IS "".
            // Flow-triggered, warp-aware solar maintenance (the
            // timer-based block this replaces re-aimed blind on a
            // schedule; this one only acts when the panels sag).
            LOCAL solarRef IS shipSolarFlow().
            UNTIL TIME:SECONDS >= resumeUt {
                SET solarRef TO solarHoldTick(solarRef).

                IF ADDONS:SCANSAT:AVAILABLE AND SHIP:CREW():LENGTH > 0 {
                    LOCAL nowBiome IS ADDONS:SCANSAT:CURRENTBIOME.
                    IF nowBiome <> lastBiome AND nowBiome <> "" {
                        SET lastBiome TO nowBiome.
                        LOCAL wanted IS FALSE.
                        LOCAL biomeLower IS nowBiome:TOLOWER.
                        FOR tok IN evaBiomes {
                            IF biomeLower:CONTAINS(tok) { SET wanted TO TRUE. }
                        }
                        // Science ledger: only the FIRST crossing
                        // of each wanted biome stops the warp —
                        // once its science is collected, later
                        // passes are HUD-only. Clear a state key
                        // (evaSci_<body>_<biome>) to re-arm one.
                        LOCAL ledgerKey IS "evaSci_" + SHIP:BODY:NAME
                            + "_" + nowBiome:REPLACE(" ", "_").
                        IF wanted AND stateGet(ledgerKey, "") = "" {
                            stateSet(ledgerKey, "done").
                            IF NOT warpHoldEnabled() { SET WARP TO 0. }
                            mLog("Science stop: first " + nowBiome
                                + " crossing — EVA/crew report time.").
                            HUDTEXT("NEW BIOME: " + nowBiome
                                + " — EVA + crew report!",
                                12, 2, 18, GREEN, FALSE).
                            IF DEFINED BOOT_LIB_RAN
                                    AND BOOT_LIB_RAN:CONTAINS("science") {
                                scienceRunAll().
                            }
                        } ELSE {
                            mLog("Now over: " + nowBiome
                                + (CHOOSE " (collected)." IF wanted ELSE ".")).
                            HUDTEXT("Now over: " + nowBiome
                                + (CHOOSE " (collected)" IF wanted ELSE ""),
                                8, 2, 15, CYAN, FALSE).
                        }
                    }
                }
                WAIT 5.
            }
            SET WARP TO 0.
            IF alarmId <> "" { DELETEALARM(alarmId). }
            mLog("KSC_DEORBIT: stay complete — planning the return.").
        }
    }

    mLog("KSC deorbit: target " + ROUND(lat, 4) + ", " + ROUND(lng, 4)
        + "  entryPe=" + ROUND(entryPe / 1000, 1) + "km"
        + "  tol=" + ROUND(tol / 1000, 1) + "km.").
    LOCAL ok IS targetedDeorbitAt(lat, lng, entryPe, tol).
    IF NOT ok {
        mLogError("KSC_DEORBIT: targeting failed — holding for review.").
        yieldToPrompt().
        RETURN.
    }
    IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        mLogWarn("STATS ksc-deorbit result impact="
            + ROUND(impactPos:LAT, 4) + "," + ROUND(impactPos:LNG, 4)).
    }
    nextPhase(xferSeq).
}

// Execute a maneuver node with align, staged throttle, and cleanup.
// Self-contained — no dependency on maneuver.ks. Used by both the
// timed deorbit path and targeted deorbit (via deorbit_targeting.ks).
GLOBAL FUNCTION executeDeorbitNode {
    PARAMETER nd.
    LOCAL burnDV IS nd:DELTAV:MAG.
    // No thrust usually means a deactivated engine or a spent
    // stage still attached. Try ACTIVATING dormant engines first —
    // it cannot pop chutes or decouplers (flight-found: a KSC
    // deorbit aborted at the burn over a right-click-deactivated
    // engine) — then stage like executeManeuver does fleet-wide.
    IF SHIP:AVAILABLETHRUST <= 0 {
        FOR eng IN SHIP:ENGINES {
            IF NOT eng:IGNITION {
                mLogWarn("Deorbit burn has no thrust — activating "
                    + eng:NAME + ".").
                eng:ACTIVATE.
            }
        }
        WAIT 0.5.
    }
    LOCAL stageTries IS 0.
    UNTIL SHIP:AVAILABLETHRUST > 0 OR stageTries >= 2 {
        SET stageTries TO stageTries + 1.
        mLogWarn("Deorbit burn still has no thrust — staging (attempt "
            + stageTries + ").").
        STAGE.
        WAIT 1.
    }
    IF SHIP:AVAILABLETHRUST <= 0 OR SHIP:MASS <= 0 {
        mLogError("Timed deorbit cannot burn: no available thrust"
            + " (engines dry, disabled, or absent).").
        REMOVE nd.
        RETURN FALSE.
    }
    LOCAL maxAcc IS SHIP:AVAILABLETHRUST / SHIP:MASS.
    LOCAL burnTime IS burnDV / MAX(0.1, maxAcc).
    LOCAL startTime IS nd:TIME - burnTime / 2.
    IF startTime < TIME:SECONDS + 5 { SET startTime TO TIME:SECONDS + 5. }

    mLogWarn("STATS timed-burn setup dv=" + ROUND(burnDV,1)
        + " eta=" + ROUND(startTime - TIME:SECONDS,1)
        + " nodeEta=" + ROUND(nd:ETA,1)
        + " maxAcc=" + ROUND(maxAcc,2)).

    // Warp/wait discipline — parity with executeManeuver
    // (flight-found: a 3.4h coast to the deorbit burn held a
    // steering lock with no KAC alarm; warping would sail
    // through the window).
    LOCAL kacAlarmId IS "".
    IF ADDONS:KAC:AVAILABLE AND startTime - 60 > TIME:SECONDS {
        LOCAL alm IS ADDALARM("Raw", startTime - 60,
            "Deorbit burn: " + ROUND(burnDV,1) + "m/s",
            "Auto-created by executeDeorbitNode").
        SET alm:ACTION TO "KillWarp".
        SET kacAlarmId TO alm:ID.
        mLog("KAC alarm set for deorbit burn in "
            + ROUND(startTime - 60 - TIME:SECONDS, 0) + "s.").
    }
    IF startTime - TIME:SECONDS > 300 {
        trySolarOrient().
        SET SAS TO TRUE.
        mLog("Long coast to deorbit burn ("
            + ROUND(startTime - TIME:SECONDS, 0) + "s). Warp at will.").
        LOCAL solarRef IS -1.
        UNTIL TIME:SECONDS >= startTime - 120 {
            SET solarRef TO trySolarHoldTick(solarRef).
            WAIT MIN(10, MAX(0.5, startTime - 120 - TIME:SECONDS)).
        }
        SET WARP TO 0.
        mLog("Awake — " + ROUND(startTime - TIME:SECONDS, 0)
            + "s to deorbit burn.").
    }

    SET SAS TO FALSE.
    // Use the ENTIRE remaining coast for alignment — flight-found:
    // a 45s cap left a weak-wheel (SAS-less) craft pointing the
    // wrong way with the burn 36s out.
    LOCK STEERING TO nd:BURNVECTOR.
    LOCAL alignDeadline IS startTime - 2.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < 5
            OR TIME:SECONDS >= alignDeadline {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }
    mLogWarn("STATS timed-burn align angle="
        + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR),1)
        + " timeToBurn=" + ROUND(startTime - TIME:SECONDS,1)).

    WAIT UNTIL TIME:SECONDS >= startTime.
    // Never light the engine badly off-axis: a misaligned deorbit
    // burn can RAISE or skew the orbit. Refusing costs one pass;
    // the caller replans.
    IF VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) > 15 {
        mLogError("Refusing burn: "
            + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR), 1)
            + " deg off the burn vector at ignition.").
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        RETURN FALSE.
    }
    LOCAL burnStart IS TIME:SECONDS.
    LOCAL origBurnVec IS nd:BURNVECTOR.
    mLog("Timed deorbit burn start. dV=" + ROUND(burnDV,1) + " m/s.").
    UNTIL nd:DELTAV:MAG < MAX(0.08, burnDV * 0.01)
            OR TIME:SECONDS - burnStart > burnTime * 2 + 8 {
        LOCK STEERING TO nd:BURNVECTOR.
        IF nd:DELTAV:MAG > 0.1
                AND VDOT(origBurnVec:NORMALIZED, nd:BURNVECTOR:NORMALIZED) < 0 {
            BREAK.
        }
        IF nd:DELTAV:MAG > 3 {
            LOCK THROTTLE TO 1.
        } ELSE IF nd:DELTAV:MAG > 0.4 {
            LOCK THROTTLE TO 0.25.
        } ELSE {
            LOCK THROTTLE TO 0.05.
        }
        WAIT 0.02.
    }

    LOCAL residual IS nd:DELTAV:MAG.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    // Guarded: the node can already be gone post-burn (flight-
    // found: REMOVE threw after a flip-guard exit at 1.7 m/s
    // residual — likely MechJeb's remove-after-execution eating
    // the depleted node first).
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    SET SAS TO TRUE.
    IF kacAlarmId <> "" { DELETEALARM(kacAlarmId). }
    mLog("Timed deorbit burn complete. Residual=" + ROUND(residual,2) + " m/s.").
    mLogWarn("STATS timed-burn result dv=" + ROUND(burnDV,1)
        + " residual=" + ROUND(residual,2)
        + " duration=" + ROUND(TIME:SECONDS - burnStart,1)).
    RETURN TRUE.
}
