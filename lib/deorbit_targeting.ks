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
    // NEVER walk inside the atmosphere: the impact prediction
    // shifts continuously from drag (measured flips become drag
    // noise) and Pe decays on its own — flight-found: an in-atmo
    // walk turned a 10km miss into 20km while drag drove Pe from
    // 18km to below ground. Entry targeting ended at entry.
    IF SHIP:BODY:ATM:EXISTS
            AND SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT + 2000 {
        mLogWarn("Impact walk skipped: inside the atmosphere —"
            + " descent rides what it has.").
        RETURN.
    }
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
                // Confirm before trusting: a jitter spike during
                // the settle can fake a worsening (operator-
                // flagged). Flip, pulse the NEW direction, and
                // require a measured IMPROVEMENT; if both
                // directions read worse, the axis is unobservable
                // right now — skip the leg.
                SET goPro TO NOT goPro.
                IF goPro { LOCK STEERING TO SHIP:PROGRADE. }
                ELSE { LOCK STEERING TO SHIP:RETROGRADE. }
                LOCAL flipDeadline IS TIME:SECONDS + 90.
                UNTIL VANG(SHIP:FACING:FOREVECTOR,
                        (CHOOSE 1 IF goPro ELSE -1)
                        * SHIP:VELOCITY:ORBIT) < 5
                        OR TIME:SECONDS > flipDeadline {
                    WAIT 0.2.
                }
                LOCK THROTTLE TO 0.012.
                WAIT 0.05.
                LOCK THROTTLE TO 0.
                SET dvSpent TO dvSpent
                    + (SHIP:AVAILABLETHRUST / MAX(0.1, SHIP:MASS))
                      * 0.012 * 0.05.
                WAIT 2.
                LOCAL dConfirm IS _walkDist(targetLat, targetLng).
                IF dConfirm >= 0 AND dConfirm > dProbe + 200 {
                    SET reason TO "along-unobservable".
                    mLog("Along leg: BOTH directions measured worse"
                        + " — axis unobservable; skipping leg.").
                } ELSE {
                    mLog("Along leg: measured flip confirmed —"
                        + " lng heuristic wrong for this geometry.").
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

// ── Entry-Pe as a deorbit-targeting degree of freedom ─────────
// The scan's only natural lever is burn TIME (which pass). For a
// near-equatorial target from an inclined orbit, the binding miss
// is along-track: a pass whose ground-track crossing overshoots
// the target by tens-to-hundreds of km. A STEEPER deorbit (deeper
// Pe = harder retrograde burn) shortens the descent's downrange
// arc and pulls the impact back toward (west of) the deorbit
// point — trading the mission's spare dV to hit the target on a
// SOONER pass instead of waiting orbits for one that lands short
// on its own. Pe only pulls the impact shorter, never longer (Pe
// can't rise above the atmosphere), so the burn-time sweep still
// owns "deorbit earlier"; together they cover both signs of miss.
//
// vNow cancels in a same-time dV difference, so the budget bound
// needs no VELOCITYAT (which CLAUDE.md forbids for planning): the
// extra dV of a deeper Pe is just vNew(defaultPe) - vNew(deepPe).
LOCAL FUNCTION _deorbitVNew {
    PARAMETER entryPe.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL orbitSma IS SHIP:ORBIT:SEMIMAJORAXIS.
    RETURN _deorbitVNewFast(entryPe, bodyR, mu, orbitSma, 2 / orbitSma).
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

// Candidate entry-Pe values: the shallow default, plus deeper
// rungs spanning the spare-dV budget (LANDING_DEORBIT_BUDGET_DV).
// budget<=0 returns just the default — exact legacy behavior.
LOCAL FUNCTION _deorbitPeCandidates {
    PARAMETER defaultPe.
    PARAMETER budgetDv.
    PARAMETER bodyR IS -1.
    PARAMETER mu IS -1.
    PARAMETER orbitSma IS -1.
    PARAMETER twoOverOrbitSma IS -1.
    IF bodyR < 0 { SET bodyR TO SHIP:ORBIT:BODY:RADIUS. }
    IF mu < 0 { SET mu TO SHIP:ORBIT:BODY:MU. }
    IF orbitSma < 0 { SET orbitSma TO SHIP:ORBIT:SEMIMAJORAXIS. }
    IF twoOverOrbitSma < 0 { SET twoOverOrbitSma TO 2 / orbitSma. }
    LOCAL out IS LIST(defaultPe).
    IF budgetDv <= 0 { RETURN out. }
    LOCAL vBase IS _deorbitVNewFast(defaultPe, bodyR, mu, orbitSma,
        twoOverOrbitSma).
    // Deepest Pe still inside budget (5 km probe steps; rPe must
    // stay well positive or the vis-viva radicand goes negative).
    LOCAL peFloor IS defaultPe.
    LOCAL probe IS defaultPe - 5000.
    UNTIL probe <= -bodyR * 0.5 {
        IF vBase - _deorbitVNewFast(probe, bodyR, mu, orbitSma,
                twoOverOrbitSma) > budgetDv { BREAK. }
        SET peFloor TO probe.
        SET probe TO probe - 5000.
    }
    IF peFloor < defaultPe {
        LOCAL span IS defaultPe - peFloor.
        LOCAL i IS 1.
        UNTIL i > 6 {
            out:ADD(defaultPe - span * i / 6).
            SET i TO i + 1.
        }
    }
    RETURN out.
}

// Best (distance, Pe) at a fixed burn time across the Pe rungs.
// A single-rung peList (no budget) reduces to one legacy eval.
LOCAL FUNCTION _deorbitEvalBestPe {
    PARAMETER burnT.
    PARAMETER peList.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER bodyR.
    PARAMETER mu.
    PARAMETER orbitSma.
    PARAMETER twoOverOrbitSma.
    PARAMETER minLead.
    PARAMETER minDV.
    PARAMETER maxDV.
    LOCAL bestValid IS FALSE.
    LOCAL bestDist IS 8.99e15.
    LOCAL bestPe IS peList[0].
    FOR candPe IN peList {
        LOCAL dist IS _evalDeorbitDist(burnT, candPe, targetLat, targetLng,
            0, 0, bodyR, mu, orbitSma, twoOverOrbitSma,
            minLead, minDV, maxDV).
        IF dist >= 0 AND dist < bestDist {
            SET bestValid TO TRUE.
            SET bestDist TO dist.
            SET bestPe TO candPe.
        }
    }
    RETURN LIST(bestValid, bestDist, bestPe).
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

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL bodyName IS SHIP:BODY:NAME.
    LOCAL bodyHasAtm IS SHIP:BODY:ATM:EXISTS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL orbitSma IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL twoOverOrbitSma IS 2 / orbitSma.
    LOCAL minDV IS 0.
    LOCAL maxDV IS 99999.
    IF CFG:HASKEY("LANDING_DEORBIT_MIN_DV") {
        SET minDV TO CFG["LANDING_DEORBIT_MIN_DV"].
    }
    IF CFG:HASKEY("LANDING_DEORBIT_MAX_DV") {
        SET maxDV TO CFG["LANDING_DEORBIT_MAX_DV"].
    }
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
        mLogWarn("STATS deorbit scan window centerMin="
            + ROUND(centerMin,1)
            + " windowMin=" + ROUND(windowMin,1)
            + " startT=" + ROUND(scanStart - nowUt,0)
            + " endT=" + ROUND(scanEnd - nowUt,0)
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
    IF bodyHasAtm {
        SET coarseStopDist TO tolerance.
    } ELSE IF bodyName = "MUN" {
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

    // Spare-dV budget for a steeper (harder) deorbit: when set,
    // the focus/polish search also varies entry Pe to drag the
    // impact onto the target on a SOONER pass instead of waiting.
    LOCAL budgetDv IS 0.
    IF CFG:HASKEY("LANDING_DEORBIT_BUDGET_DV") {
        SET budgetDv TO CFG["LANDING_DEORBIT_BUDGET_DV"].
    }
    LOCAL peList IS _deorbitPeCandidates(entryPe, budgetDv, bodyR, mu,
        orbitSma, twoOverOrbitSma).
    IF peList:LENGTH > 1 {
        mLog("Deorbit Pe search: " + peList:LENGTH + " rungs "
            + ROUND(entryPe / 1000, 0) + "km .. "
            + ROUND(peList[peList:LENGTH - 1] / 1000, 0) + "km"
            + " (budget " + ROUND(budgetDv, 0) + " m/s).").
        mLogWarn("STATS deorbit pe-search rungs=" + peList:LENGTH
            + " defaultPeKm=" + ROUND(entryPe / 1000, 1)
            + " floorPeKm=" + ROUND(peList[peList:LENGTH - 1] / 1000, 1)
            + " budgetDv=" + ROUND(budgetDv, 0)).
    }

    LOCAL bestUT   IS nowUt + 30.
    LOCAL bestPe   IS entryPe.
    LOCAL bestRad  IS 0.
    LOCAL bestNor  IS 0.
    LOCAL bestDist IS 999999999.
    LOCAL validSamples IS 0.
    LOCAL invalidSamples IS 0.

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
        LOCAL trialDist IS _evalDeorbitDist(scanUT, entryPe, targetLat, targetLng,
            0, 0, bodyR, mu, orbitSma, twoOverOrbitSma,
            minLead, minDV, maxDV).
        IF trialDist >= 0 {
            SET validSamples TO validSamples + 1.
            dTimes:ADD(scanUT).
            dDists:ADD(trialDist).
            IF trialDist < bestDist {
                SET bestDist TO trialDist.
                SET bestUT   TO scanUT.
                SET bestPe   TO entryPe.
                mLog("DEBUG coarse: T+" + ROUND(scanUT - nowUt,0)
                    + "s  dist=" + ROUND(bestDist/1000,1) + "km").
                IF bestDist <= coarseStopDist {
                    mLogWarn("STATS deorbit coarse early-stop distKm="
                        + ROUND(bestDist/1000,2)
                        + " burnT=" + ROUND(scanUT - nowUt,0)).
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
                    LOCAL wBestPe IS entryPe.
                    // Locate the window's time-optimum at the shallow
                    // default Pe (cheap); the pass geometry — which
                    // crossing — is what time selects, independent of
                    // how hard we later choose to burn.
                    FOR off IN focusOffsets {
                        LOCAL tt IS center + off * stepA * 0.66.
                        IF tt > floorUt {
                            LOCAL trDist IS _evalDeorbitDist(tt, entryPe,
                                targetLat, targetLng, 0, 0,
                                bodyR, mu, orbitSma, twoOverOrbitSma,
                                minLead, minDV, maxDV).
                            IF trDist >= 0 {
                                SET validSamples TO validSamples + 1.
                                IF trDist < wBest {
                                    SET wBest TO trDist.
                                    SET wBestT TO tt.
                                }
                            } ELSE {
                                SET invalidSamples TO invalidSamples + 1.
                            }
                        }
                    }
                    // Then spend the dV budget: a deeper Pe at this
                    // window's time can pull an overshoot back onto
                    // target. No-budget peList is a single eval.
                    IF peList:LENGTH > 1 AND wBest < 8e15 {
                        LOCAL pb IS _deorbitEvalBestPe(wBestT, peList,
                            targetLat, targetLng, bodyR, mu, orbitSma,
                            twoOverOrbitSma, minLead, minDV, maxDV).
                        SET validSamples TO validSamples + peList:LENGTH.
                        IF pb[0] AND pb[1] < wBest {
                            SET wBest TO pb[1].
                            SET wBestPe TO pb[2].
                        }
                    }
                    // Narrow promising windows to their true minimum
                    // (at the Pe chosen above).
                    IF wBest < MAX(bestDist * 1.6, coarseStopDist * 6) {
                        LOCAL hstep IS stepA * 0.5.
                        UNTIL hstep < 0.8 {
                            FOR cand IN LIST(wBestT - hstep, wBestT + hstep) {
                                IF cand > floorUt {
                                    LOCAL tr2Dist IS _evalDeorbitDist(cand,
                                        wBestPe, targetLat, targetLng, 0, 0,
                                        bodyR, mu, orbitSma, twoOverOrbitSma,
                                        minLead, minDV, maxDV).
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
                        SET bestPe TO wBestPe.
                        mLog("DEBUG window: orbit " + orbitIdx
                            + "  T+" + ROUND(wBestT - nowUt, 0)
                            + "s  dist=" + ROUND(wBest / 1000, 1) + "km").
                        IF bestDist <= coarseStopDist {
                            mLogWarn("STATS deorbit window early-stop distKm="
                                + ROUND(bestDist/1000, 2)
                                + " burnT=" + ROUND(bestUT - nowUt, 0)).
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
    LOCAL coarseBest IS _evalDeorbitNode(bestUT, bestPe, targetLat, targetLng,
        0, 0, bodyR, mu, orbitSma, twoOverOrbitSma,
        minLead, minDV, maxDV).
    mLogWarn("STATS deorbit coarse distKm=" + ROUND(bestDist/1000,1)
        + " burnT=" + ROUND(bestUT - nowUt,0)
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
            + ROUND(bestUT - nowUt,0)
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
                LOCAL tr3Dist IS _evalDeorbitDist(cand, bestPe,
                    targetLat, targetLng, 0, 0,
                    bodyR, mu, orbitSma, twoOverOrbitSma,
                    minLead, minDV, maxDV).
                IF tr3Dist >= 0 AND tr3Dist < bestDist {
                    SET bestDist TO tr3Dist.
                    SET bestUT TO cand.
                }
            }
        }
        SET fstep TO fstep / 2.
        WAIT 0.
    }
    // Final Pe polish at the pinned burn time — also covers the
    // minutes-mode and discovery-early-stop paths that skip focus.
    IF peList:LENGTH > 1 {
        LOCAL pf IS _deorbitEvalBestPe(bestUT, peList, targetLat, targetLng,
            bodyR, mu, orbitSma, twoOverOrbitSma, minLead, minDV, maxDV).
        IF pf[0] AND pf[1] < bestDist {
            SET bestDist TO pf[1].
            SET bestPe TO pf[2].
            mLog("Pe polish: entry Pe -> " + ROUND(bestPe / 1000, 1)
                + "km (closest rung at the pinned time).").
        }
    }
    mLog("Polished best: T+" + ROUND(bestUT - nowUt, 0)
        + "s  dist=" + ROUND(bestDist, 0) + "m.").

    // The old iterative impact refinement is RETIRED: it never
    // converged reliably (every recipe set SKIP_REFINE=1) and the
    // post-burn three-leg impact walk does its job better, with
    // measurement instead of prediction. Coarse + pass + walk.

    LOCAL extraDv IS _deorbitVNewFast(entryPe, bodyR, mu, orbitSma,
        twoOverOrbitSma) - _deorbitVNewFast(bestPe, bodyR, mu, orbitSma,
        twoOverOrbitSma).
    mLog("Fine best: T+" + ROUND(bestUT - nowUt,0)
        + "s  Pe=" + ROUND(bestPe/1000,1) + "km"
        + "  Rad=" + ROUND(bestRad,2)
        + "  Nor=" + ROUND(bestNor,2)
        + "  extraDv=" + ROUND(extraDv, 0)
        + "m/s"
        + "  dist=" + ROUND(bestDist/1000,1) + "km").
    LOCAL deorbitStatus IS "ok".
    IF bestDist > tolerance { SET deorbitStatus TO "miss". }
    LOCAL finalEval IS _evalDeorbitNode(bestUT, bestPe, targetLat, targetLng,
        bestRad, bestNor, bodyR, mu, orbitSma, twoOverOrbitSma,
        minLead, minDV, maxDV).
    mLogWarn("STATS deorbit final status=" + deorbitStatus
        + " distKm=" + ROUND(bestDist/1000,1)
        + " toleranceKm=" + ROUND(tolerance/1000,1)
        + " burnT=" + ROUND(bestUT - nowUt,0)
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

    LOCAL realNode IS _planDeorbitNode(bestUT, bestPe, bestRad, bestNor,
        bodyR, mu, orbitSma, twoOverOrbitSma, minDV, maxDV).
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
    PARAMETER minDV.
    PARAMETER maxDV.

    IF burnUT <= TIME:SECONDS + minLead { RETURN -1. }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planDeorbitNode(burnUT, entryPe, radialDv, normalDv,
        bodyR, mu, orbitSma, twoOverOrbitSma, minDV, maxDV).
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


LOCAL FUNCTION _evalDeorbitNode {
    PARAMETER burnUT.
    PARAMETER entryPe.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER radialDv IS 0.
    PARAMETER normalDv IS 0.
    PARAMETER bodyR IS -1.
    PARAMETER mu IS -1.
    PARAMETER orbitSma IS -1.
    PARAMETER twoOverOrbitSma IS -1.
    PARAMETER minLead IS -1.
    PARAMETER minDV IS -1.
    PARAMETER maxDV IS -1.

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

    IF minLead < 0 { SET minLead TO _targetDeorbitMinLead(). }
    IF burnUT <= TIME:SECONDS + minLead { RETURN result. }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planDeorbitNode(burnUT, entryPe, radialDv, normalDv,
        bodyR, mu, orbitSma, twoOverOrbitSma, minDV, maxDV).
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
    PARAMETER bodyR IS -1.
    PARAMETER mu IS -1.
    PARAMETER orbitSma IS -1.
    PARAMETER twoOverOrbitSma IS -1.
    PARAMETER minDV IS -1.
    PARAMETER maxDV IS -1.

    IF bodyR < 0 { SET bodyR TO SHIP:ORBIT:BODY:RADIUS. }
    IF mu < 0 { SET mu TO SHIP:ORBIT:BODY:MU. }
    IF orbitSma < 0 { SET orbitSma TO SHIP:ORBIT:SEMIMAJORAXIS. }
    IF twoOverOrbitSma < 0 { SET twoOverOrbitSma TO 2 / orbitSma. }
    IF minDV < 0 {
        SET minDV TO 0.
        IF DEFINED CFG AND CFG:HASKEY("LANDING_DEORBIT_MIN_DV") {
            SET minDV TO CFG["LANDING_DEORBIT_MIN_DV"].
        }
    }
    IF maxDV < 0 {
        SET maxDV TO 99999.
        IF DEFINED CFG AND CFG:HASKEY("LANDING_DEORBIT_MAX_DV") {
            SET maxDV TO CFG["LANDING_DEORBIT_MAX_DV"].
        }
    }
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS _deorbitVNewFast(entryPe, bodyR, mu, orbitSma,
        twoOverOrbitSma).
    LOCAL dv   IS vNew - vNow.

    // Clamp retrograde dV to configurable min/max bounds.
    // From low orbits the Hohmann dV is tiny; the floor ensures a
    // steep ballistic trajectory that overshoots the target so the
    // suicide burn can steer onto it during descent.
    IF minDV > 0 OR maxDV < 99999 {
        SET dv TO MIN(-minDV, MAX(-maxDV, dv)).
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
