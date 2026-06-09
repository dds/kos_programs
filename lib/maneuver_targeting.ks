// ============================================================
// maneuver_targeting.ks  —  Orbital element targeting, search,
//     and optimization  (0:/lib/maneuver_targeting.ks)
//
// Split from maneuver.ks — contains the targeting/search
// algorithms used by planTransfer, phaseMidCourse, and
// external callers (maneuver_intersystem, maneuver_rendezvous).
//
// Provides:
//   _getTargetPatch          — walk patched conics to find target SOI
//   _findEncounter           — binary time search for encounter
//   _findClosestApproach     — min separation via coarse scan + golden section
//   _scanForLan              — LAN optimization across departure orbits
//   _targetPatchElementsCoupled — coordinate search for PE/INC/LAN/AOP
//   _patchElementsCost       — cost function for element targeting
//   _patchElementsCostFromPatch — cost from an orbit patch directly
//   _elementsConverged       — convergence check
//   newtonTarget             — Newton-Raphson for single orbital param
//   _nodeAxisGet / _nodeAxisSet — node axis read/write by name
// ============================================================

@LAZYGLOBAL OFF.

// ============================================================
// _getTargetPatch — walk patched conics to find the orbit patch
// around the target body.
// ============================================================
GLOBAL FUNCTION _getTargetPatch {
    PARAMETER originTarget.
    PARAMETER targetBody.
    LOCAL p IS originTarget:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        SET p TO p:NEXTPATCH.
        IF p:BODY:NAME = targetBody:NAME { RETURN p. }
    }
    RETURN 0.
}

// ============================================================
// _findEncounter — search for a time that produces an encounter
// with the target body. Expands outward from centerTime.
// ============================================================
GLOBAL FUNCTION _findEncounter {
    PARAMETER testNode.
    PARAMETER targetBody.
    PARAMETER centerTime.
    PARAMETER searchRadius.
    PARAMETER step.

    LOCAL offset IS 0.
    UNTIL offset > searchRadius {
        LOCAL tryTimes IS LIST(centerTime + offset).
        IF offset > 0 { tryTimes:ADD(centerTime - offset). }
        FOR t IN tryTimes {
            IF t > TIME:SECONDS + 30 {
                SET testNode:TIME TO t.
                WAIT 0.02.
                LOCAL patch IS _getTargetPatch(testNode, targetBody).
                IF patch <> 0 AND patch:PERIAPSIS > 0 {
                    RETURN t.
                }
            }
        }
        SET offset TO offset + step.
    }
    RETURN -1.
}

// ============================================================
// _findClosestApproach — find minimum separation between ship
// and a target vessel over a time window.
//
// Uses coarse scan + golden section refinement. POSITIONAT on
// both ship and target reflects any maneuver nodes on the flight
// plan, so this works for evaluating planned burns.
//
// Returns: LEXICON("time", ut, "distance", meters)
// ============================================================
GLOBAL FUNCTION _findClosestApproach {
    PARAMETER tgt, tStart, tEnd, steps.

    // Coarse scan
    LOCAL dt IS (tEnd - tStart) / steps.
    LOCAL bestT IS tStart.
    LOCAL bestD IS 9e15.

    LOCAL t IS tStart.
    UNTIL t > tEnd {
        LOCAL sep IS (POSITIONAT(SHIP, t) - POSITIONAT(tgt, t)):MAG.
        IF sep < bestD {
            SET bestD TO sep.
            SET bestT TO t.
        }
        SET t TO t + dt.
    }

    // Golden section refine around the best point
    LOCAL a IS MAX(tStart, bestT - dt * 2).
    LOCAL b IS MIN(tEnd, bestT + dt * 2).
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL i IS 0. } UNTIL i >= 15 STEP { SET i TO i + 1. } DO {
        LOCAL c IS b - (b - a) / gr.
        LOCAL d IS a + (b - a) / gr.
        LOCAL fc IS (POSITIONAT(SHIP, c) - POSITIONAT(tgt, c)):MAG.
        LOCAL fd IS (POSITIONAT(SHIP, d) - POSITIONAT(tgt, d)):MAG.
        IF fc < fd {
            SET b TO d.
        } ELSE {
            SET a TO c.
        }
    }

    LOCAL midT IS (a + b) / 2.
    LOCAL midD IS (POSITIONAT(SHIP, midT) - POSITIONAT(tgt, midT)):MAG.
    RETURN LEXICON("time", midT, "distance", midD).
}

// ============================================================
// LAN scan — shared by local and interplanetary paths
// Slides departure time across orbits, reads actual LAN from
// KSP's patched conics, picks the orbit with lowest LAN error.
// ============================================================
GLOBAL FUNCTION _scanForLan {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER lanTarget.
    PARAMETER shipPeriod.
    PARAMETER scanPeriod IS targetBody:ORBIT:PERIOD.

    LOCAL nScan IS MAX(6, CEILING(scanPeriod / shipPeriod)).
    LOCAL centerTime IS nd:TIME.
    LOCAL bestLanErr IS 999.
    LOCAL bestTime IS centerTime.
    LOCAL baseDv IS nd:PROGRADE.

    LOCAL lanTol IS 0.5.
    IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO CFG["LAN_ERR_TOL"]. }

    mLog("LAN scan: " + (2 * nScan + 1) + " orbits around departure, target LAN=" + ROUND(lanTarget, 1)).

    FROM { LOCAL oi IS -nScan. } UNTIL oi > nScan STEP { SET oi TO oi + 1. } DO {
        LOCAL tryTime IS centerTime + oi * shipPeriod.
        IF tryTime > TIME:SECONDS + 30 {
            SET nd:TIME TO tryTime.
            SET nd:PROGRADE TO baseDv.
            WAIT 0.02.
            LOCAL patch IS _getTargetPatch(nd, targetBody).
            IF patch <> 0 AND patch:PERIAPSIS > 0 {
                LOCAL lanErr IS ABS(patch:LAN - lanTarget).
                IF lanErr > 180 { SET lanErr TO 360 - lanErr. }
                IF lanErr < bestLanErr {
                    SET bestLanErr TO lanErr.
                    SET bestTime TO tryTime.
                    mLog("LAN[" + oi + "] LAN=" + ROUND(patch:LAN, 1)
                        + " err=" + ROUND(lanErr, 1)
                        + " Pe=" + ROUND(patch:PERIAPSIS/1000, 1) + "km").
                }
            }
        }
    }

    SET nd:TIME TO bestTime.
    SET nd:PROGRADE TO baseDv.
    WAIT 0.1.

    // Verify the chosen orbit still has an encounter
    LOCAL verifyPatch IS _getTargetPatch(nd, targetBody).
    IF verifyPatch = 0 OR verifyPatch:PERIAPSIS < 0 {
        mLogWarn("LAN scan: chosen orbit lost encounter, searching nearby...").
        LOCAL foundTime IS _findEncounter(nd, targetBody, bestTime, shipPeriod / 2, shipPeriod / 16).
        IF foundTime >= 0 {
            SET nd:TIME TO foundTime.
            WAIT 0.1.
        }
    }

    mLog("LAN scan: best err=" + ROUND(bestLanErr, 1) + "°  depart T+" + ROUND(nd:TIME - TIME:SECONDS, 0) + "s").
    mLogWarn("STATS lan-scan target=" + targetBody:NAME
        + " target=" + ROUND(lanTarget,1)
        + " err=" + ROUND(bestLanErr,1)
        + " departT=" + ROUND(nd:TIME - TIME:SECONDS,0)).
    RETURN nd.
}

// ============================================================
// _targetPatchElementsCoupled — coordinate search for PE/INC/LAN/AOP.
//
// Used as a final cleanup for precise capture geometry. It optimizes
// all requested patch elements together so a LAN or AoP correction can't
// quietly destroy periapsis or inclination. The TIME axis is included
// because LAN/AoP are often better changed by moving the correction node
// slightly along the transfer than by spending more normal/radial dV.
// ============================================================
GLOBAL FUNCTION _targetPatchElementsCoupled {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targets.
    PARAMETER opts IS LEXICON().

    LOCAL axes IS LIST("PROGRADE", "NORMAL", "RADIALOUT", "TIME").
    LOCAL signs IS LIST(1, -1).
    LOCAL steps IS LEXICON().
    steps:ADD("PROGRADE", 1.0).
    steps:ADD("NORMAL", 1.0).
    steps:ADD("RADIALOUT", 1.0).
    steps:ADD("TIME", 30.0).

    LOCAL minStep IS 0.02.
    LOCAL maxIter IS 80.
    LOCAL minIter IS 0.
    LOCAL dvCap IS -1.
    LOCAL minTime IS TIME:SECONDS + 30.
    LOCAL aopGuideStallIter IS 0.
    LOCAL aopGuideStallMinImprove IS 1.

    IF opts:HASKEY("STEP_PROGRADE"){ SET steps["PROGRADE"]  TO opts["STEP_PROGRADE"]. }
    IF opts:HASKEY("STEP_NORMAL")  { SET steps["NORMAL"]    TO opts["STEP_NORMAL"]. }
    IF opts:HASKEY("STEP_RADIAL")  { SET steps["RADIALOUT"] TO opts["STEP_RADIAL"]. }
    IF opts:HASKEY("STEP_TIME")    { SET steps["TIME"]      TO opts["STEP_TIME"]. }
    IF opts:HASKEY("MIN_STEP")     { SET minStep            TO opts["MIN_STEP"]. }
    IF opts:HASKEY("MAX_ITER")     { SET maxIter            TO opts["MAX_ITER"]. }
    IF opts:HASKEY("MIN_ITER")     { SET minIter            TO opts["MIN_ITER"]. }
    IF opts:HASKEY("DV_CAP")       { SET dvCap              TO opts["DV_CAP"]. }
    IF opts:HASKEY("MIN_TIME")     { SET minTime            TO opts["MIN_TIME"]. }
    IF opts:HASKEY("AOP_GUIDE_STALL_ITER") { SET aopGuideStallIter TO opts["AOP_GUIDE_STALL_ITER"]. }
    IF opts:HASKEY("AOP_GUIDE_STALL_MIN_IMPROVE") { SET aopGuideStallMinImprove TO opts["AOP_GUIDE_STALL_MIN_IMPROVE"]. }

    LOCAL best IS _patchElementsCost(nd, targetBody, targets).
    LOCAL solved IS FALSE.
    LOCAL aopGuideTol IS 35.
    LOCAL bestAopGuideErr IS 999.
    LOCAL aopGuideStallCount IS 0.
    IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopGuideTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
    IF targets:HASKEY("AOP_GUIDE") { SET bestAopGuideErr TO ABS(best["AOP_ERR"]). }
    mLog("ELEMENTS: coupled target"
        + _elementTargetSummary(targets)
        + " start" + _elementStateSummary(best)).
    mLogWarn("STATS elements setup target=" + targetBody:NAME
        + _elementTargetSummary(targets)
        + " start" + _elementStateSummary(best)
        + " maxIter=" + maxIter
        + " dvCap=" + ROUND(dvCap,1)).

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        IF i >= minIter AND _elementsConverged(best, targets) {
            SET solved TO TRUE.
            mLog("  ELEMENTS[" + i + "] converged" + _elementStateSummary(best)).
            BREAK.
        }

        LOCAL bestAxis IS "".
        LOCAL bestValue IS 0.
        LOCAL bestTrial IS best.

        FOR axis IN axes {
            LOCAL oldVal IS _nodeAxisGet(nd, axis).
            FOR sgn IN signs {
                LOCAL trialVal IS oldVal + sgn * steps[axis].
                LOCAL timeOk IS TRUE.
                IF axis = "TIME" AND trialVal <= minTime { SET timeOk TO FALSE. }
                IF timeOk {
                    _nodeAxisSet(nd, axis, trialVal).
                    WAIT 0.02.

                    IF dvCap < 0 OR nd:DELTAV:MAG <= dvCap {
                        LOCAL trial IS _patchElementsCost(nd, targetBody, targets).
                        IF trial["COST"] < bestTrial["COST"] {
                            SET bestTrial TO trial.
                            SET bestAxis TO axis.
                            SET bestValue TO trialVal.
                        }
                    }
                }
            }
            _nodeAxisSet(nd, axis, oldVal).
            WAIT 0.01.
        }

        IF bestAxis <> "" {
            _nodeAxisSet(nd, bestAxis, bestValue).
            WAIT 0.02.
            SET best TO _patchElementsCost(nd, targetBody, targets).
            mLog("  ELEMENTS[" + i + "] " + bestAxis
                + "=" + ROUND(bestValue, 2)
                + _elementStateSummary(best)
                + " cost=" + ROUND(best["COST"], 2)).
        } ELSE {
            FOR axis IN axes {
                SET steps[axis] TO steps[axis] / 2.
            }
            mLog("  ELEMENTS[" + i + "] refining steps: P="
                + ROUND(steps["PROGRADE"], 2)
                + " N=" + ROUND(steps["NORMAL"], 2)
                + " R=" + ROUND(steps["RADIALOUT"], 2)
                + " T=" + ROUND(steps["TIME"], 1)).

            LOCAL stepsSmall IS FALSE.
            IF steps["PROGRADE"] < minStep AND steps["NORMAL"] < minStep {
                IF steps["RADIALOUT"] < minStep AND steps["TIME"] < 1 {
                    SET stepsSmall TO TRUE.
                }
            }
            IF stepsSmall {
                mLogWarn("  ELEMENTS: stopped" + _elementStateSummary(best)).
                BREAK.
            }
        }

        IF aopGuideStallIter > 0 AND targets:HASKEY("AOP_GUIDE") {
            LOCAL guideErr IS ABS(best["AOP_ERR"]).
            IF guideErr <= aopGuideTol {
                SET aopGuideStallCount TO 0.
                SET bestAopGuideErr TO guideErr.
            } ELSE IF guideErr < bestAopGuideErr - aopGuideStallMinImprove {
                SET bestAopGuideErr TO guideErr.
                SET aopGuideStallCount TO 0.
            } ELSE {
                SET aopGuideStallCount TO aopGuideStallCount + 1.
            }
            IF aopGuideStallCount >= aopGuideStallIter {
                mLogWarn("  ELEMENTS: AoP guide stalled err="
                    + ROUND(guideErr,1)
                    + " best=" + ROUND(bestAopGuideErr,1)
                    + " tol=" + ROUND(aopGuideTol,1)
                    + " count=" + aopGuideStallCount).
                BREAK.
            }
        }
    }

    IF NOT solved {
        SET best TO _patchElementsCost(nd, targetBody, targets).
        mLogWarn("ELEMENTS final error" + _elementErrorSummary(best, targets)).
    }

    SET best TO _patchElementsCost(nd, targetBody, targets).
    best:ADD("SOLVED", solved).
    mLogWarn("STATS elements result target=" + targetBody:NAME
        + " solved=" + solved
        + _elementStateSummary(best)
        + _elementErrorSummary(best, targets)
        + " cost=" + ROUND(best["COST"],2)
        + " dv=" + ROUND(nd:DELTAV:MAG,1)).

    RETURN best.
}

GLOBAL FUNCTION _patchElementsCost {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targets.

    LOCAL p IS _getTargetPatch(nd, targetBody).
    IF p = 0 {
        LOCAL miss IS LEXICON().
        miss:ADD("PATCH", 0).
        miss:ADD("PE", 0).
        miss:ADD("INC", 0).
        miss:ADD("LAN", 0).
        miss:ADD("AOP", 0).
        miss:ADD("PE_ERR", 9999999).
        miss:ADD("INC_ERR", 999).
        miss:ADD("LAN_ERR", 999).
        miss:ADD("AOP_ERR", 999).
        miss:ADD("COST", 999999999).
        RETURN miss.
    }

    RETURN _patchElementsCostFromPatch(p, targets).
}

GLOBAL FUNCTION _transferSeedScore {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER targetPe.
    PARAMETER captureInc.
    PARAMETER lanTarget.
    PARAMETER aopTarget.
    PARAMETER caDist IS 0.
    PARAMETER dvMag IS 0.

    LOCAL p IS _getTargetPatch(nd, targetBody).
    LOCAL score IS (caDist / 100000)^2 + dvMag * 0.01.
    LOCAL peErr IS 9999999.
    LOCAL incErr IS 999.
    LOCAL lanErr IS 999.
    LOCAL aopErr IS 999.
    LOCAL lanTol IS 5.
    LOCAL aopTol IS 35.
    LOCAL hasPatch IS FALSE.

    IF CFG:HASKEY("LAN_ERR_TOL") { SET lanTol TO MAX(1, CFG["LAN_ERR_TOL"] * 5). }
    IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }

    IF p = 0 {
        SET score TO score + 1000000.
    } ELSE {
        SET hasPatch TO TRUE.
        SET peErr TO p:PERIAPSIS - targetPe.
        SET score TO score + (peErr / 50000)^2.

        IF captureInc >= 0 {
            SET incErr TO _angleError(p:INCLINATION, captureInc).
            SET score TO score + (incErr / 2.0)^2.
        }
        IF lanTarget >= 0 {
            SET lanErr TO _angleError(p:LAN, lanTarget).
            SET score TO score + (lanErr / MAX(lanTol, 1))^2.
            IF ABS(lanErr) > lanTol {
                SET score TO score + ((ABS(lanErr) - lanTol) / 1.0)^2 * 50.
            }
        }
        IF aopTarget >= 0 {
            SET aopErr TO _angleError(p:ARGUMENTOFPERIAPSIS, aopTarget).
            SET score TO score + (aopErr / MAX(aopTol, 1))^2.
            IF ABS(aopErr) > aopTol {
                SET score TO score + ((ABS(aopErr) - aopTol) / 1.0)^2 * 50.
            }
        }
    }

    RETURN LEXICON(
        "SCORE", score,
        "PATCH", hasPatch,
        "CA", caDist,
        "DV", dvMag,
        "PE_ERR", peErr,
        "INC_ERR", incErr,
        "LAN_ERR", lanErr,
        "AOP_ERR", aopErr
    ).
}

GLOBAL FUNCTION _patchElementsCostFromPatch {
    PARAMETER p.
    PARAMETER targets.

    LOCAL peErr IS 0.
    LOCAL incErr IS 0.
    LOCAL lanErr IS 0.
    LOCAL aopErr IS 0.
    LOCAL cost IS 0.

    IF targets:HASKEY("PE") {
        SET peErr TO p:PERIAPSIS - targets["PE"].
        SET cost TO cost + (peErr / 2000)^2.
    }
    IF targets:HASKEY("PE_FLOOR") {
        IF p:PERIAPSIS < targets["PE_FLOOR"] {
            SET cost TO cost + ((targets["PE_FLOOR"] - p:PERIAPSIS) / 500)^2.
        }
    }
    IF targets:HASKEY("INC") {
        SET incErr TO _angleError(p:INCLINATION, targets["INC"]).
        SET cost TO cost + (incErr / 0.5)^2.
    }
    IF targets:HASKEY("LAN") {
        SET lanErr TO _angleError(p:LAN, targets["LAN"]).
        SET cost TO cost + (lanErr / 1.0)^2.
    }
    IF targets:HASKEY("AOP") {
        SET aopErr TO _angleError(p:ARGUMENTOFPERIAPSIS, targets["AOP"]).
        SET cost TO cost + (aopErr / 1.0)^2.
    } ELSE IF targets:HASKEY("AOP_GUIDE") {
        LOCAL aopGuideTol IS 35.
        IF CFG:HASKEY("TRANSFER_AOP_ERR_TOL") { SET aopGuideTol TO CFG["TRANSFER_AOP_ERR_TOL"]. }
        LOCAL aopGuideScale IS MAX(5, aopGuideTol / 3).
        SET aopErr TO _angleError(p:ARGUMENTOFPERIAPSIS, targets["AOP_GUIDE"]).
        SET cost TO cost + (aopErr / aopGuideScale)^2.
        IF ABS(aopErr) > aopGuideTol {
            SET cost TO cost + ((ABS(aopErr) - aopGuideTol) / aopGuideScale)^2 * 4.
        }
    }

    LOCAL result IS LEXICON().
    result:ADD("PATCH", 1).
    result:ADD("PE", p:PERIAPSIS).
    result:ADD("INC", p:INCLINATION).
    result:ADD("LAN", p:LAN).
    result:ADD("AOP", p:ARGUMENTOFPERIAPSIS).
    result:ADD("PE_ERR", peErr).
    result:ADD("INC_ERR", incErr).
    result:ADD("LAN_ERR", lanErr).
    result:ADD("AOP_ERR", aopErr).
    result:ADD("COST", cost).
    RETURN result.
}

GLOBAL FUNCTION _elementsConverged {
    PARAMETER eval.
    PARAMETER targets.
    IF eval["PATCH"] = 0 { RETURN FALSE. }
    IF targets:HASKEY("PE") {
        IF ABS(eval["PE_ERR"]) > 500 { RETURN FALSE. }
    }
    IF targets:HASKEY("INC") {
        IF ABS(eval["INC_ERR"]) > 0.5 { RETURN FALSE. }
    }
    IF targets:HASKEY("LAN") {
        IF ABS(eval["LAN_ERR"]) > 1.0 { RETURN FALSE. }
    }
    IF targets:HASKEY("AOP") {
        IF ABS(eval["AOP_ERR"]) > 1.0 { RETURN FALSE. }
    }
    RETURN TRUE.
}

GLOBAL FUNCTION _angleError {
    PARAMETER current.
    PARAMETER target.
    LOCAL err IS current - target.
    IF err >  180 { SET err TO err - 360. }
    IF err < -180 { SET err TO err + 360. }
    RETURN err.
}

GLOBAL FUNCTION _elementTargetSummary {
    PARAMETER targets.
    LOCAL msg IS "".
    IF targets:HASKEY("PE")  { SET msg TO msg + " Pe=" + ROUND(targets["PE"]/1000, 1) + "km". }
    IF targets:HASKEY("INC") { SET msg TO msg + " INC=" + ROUND(targets["INC"], 1) + "°". }
    IF targets:HASKEY("LAN") { SET msg TO msg + " LAN=" + ROUND(targets["LAN"], 1) + "°". }
    IF targets:HASKEY("AOP") { SET msg TO msg + " AoP=" + ROUND(targets["AOP"], 1) + "°". }
    IF targets:HASKEY("AOP_GUIDE") { SET msg TO msg + " guideAoP=" + ROUND(targets["AOP_GUIDE"], 1) + "°". }
    RETURN msg.
}

GLOBAL FUNCTION _elementStateSummary {
    PARAMETER eval.
    IF eval["PATCH"] = 0 { RETURN " no-patch". }
    RETURN " Pe=" + ROUND(eval["PE"]/1000, 1)
        + "km INC=" + ROUND(eval["INC"], 1)
        + "° LAN=" + ROUND(eval["LAN"], 1)
        + "° AoP=" + ROUND(eval["AOP"], 1) + "°".
}

GLOBAL FUNCTION _elementErrorSummary {
    PARAMETER eval.
    PARAMETER targets.
    LOCAL msg IS "".
    IF targets:HASKEY("PE")  { SET msg TO msg + " PeErr=" + ROUND(eval["PE_ERR"]/1000, 1) + "km". }
    IF targets:HASKEY("INC") { SET msg TO msg + " IncErr=" + ROUND(eval["INC_ERR"], 2) + "°". }
    IF targets:HASKEY("LAN") { SET msg TO msg + " LanErr=" + ROUND(eval["LAN_ERR"], 2) + "°". }
    IF targets:HASKEY("AOP") { SET msg TO msg + " AopErr=" + ROUND(eval["AOP_ERR"], 2) + "°". }
    IF targets:HASKEY("AOP_GUIDE") { SET msg TO msg + " GuideAopErr=" + ROUND(eval["AOP_ERR"], 2) + "°". }
    RETURN msg.
}

GLOBAL FUNCTION _nodeAxisGet {
    PARAMETER nd.
    PARAMETER axis.
    IF axis = "PROGRADE"  { RETURN nd:PROGRADE. }
    IF axis = "NORMAL"    { RETURN nd:NORMAL. }
    IF axis = "RADIALOUT" { RETURN nd:RADIALOUT. }
    IF axis = "TIME"      { RETURN nd:TIME. }
    RETURN 0.
}

GLOBAL FUNCTION _nodeAxisSet {
    PARAMETER nd.
    PARAMETER axis.
    PARAMETER value.
    IF axis = "PROGRADE"  { SET nd:PROGRADE  TO value. }
    IF axis = "NORMAL"    { SET nd:NORMAL    TO value. }
    IF axis = "RADIALOUT" { SET nd:RADIALOUT TO value. }
    IF axis = "TIME"      { SET nd:TIME      TO value. }
}

// ============================================================
// newtonTarget — unified Newton-Raphson for any orbital param.
//
// param: "PE" (prograde), "INC" (normal), "LAN" (normal), "AOP" (radial)
// opts (optional LEXICON):
//   BIAS    — seed value for the axis when it's zero (e.g. ±5 for polar)
//   DV_CAP  — max total node dV; aborts if exceeded (used by MCC)
//   TOL     — convergence tolerance (default: 500m for PE, 0.5° for angles)
//   DAMP    — damping factor (default: 0.5 for PE, 0.7 for angles)
//   HOLD    — LEXICON("PARAM", name, "VALUE", target) — after each
//             primary correction, apply a compensating single Newton
//             step on the held axis to maintain its target. Used to
//             keep INC locked while converging PE.
//
// Accepts negative PE encounters (trajectory below surface). The
// closest-approach optimizer may produce a dead-center trajectory
// with PE deep below the surface — the orbital elements are still
// well-defined and Newton can raise PE from there. Only a truly
// missing encounter (no patch) triggers backtracking.
// ============================================================
GLOBAL FUNCTION newtonTarget {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER param.
    PARAMETER targetVal.
    PARAMETER opts IS LEXICON().

    LOCAL isAngle IS (param <> "PE").
    LOCAL eps     IS CHOOSE 0.5 IF isAngle ELSE 0.1.
    LOCAL damp    IS CHOOSE 0.7 IF isAngle ELSE 0.5.
    LOCAL tol     IS CHOOSE 0.5 IF isAngle ELSE 500.
    LOCAL maxIter IS 35.
    LOCAL dvCap   IS -1.
    LOCAL bias    IS 0.

    IF opts:HASKEY("DAMP")     { SET damp    TO opts["DAMP"]. }
    IF opts:HASKEY("TOL")      { SET tol     TO opts["TOL"]. }
    IF opts:HASKEY("MAX_ITER") { SET maxIter TO opts["MAX_ITER"]. }
    IF opts:HASKEY("DV_CAP")   { SET dvCap   TO opts["DV_CAP"]. }
    IF opts:HASKEY("BIAS")     { SET bias    TO opts["BIAS"]. }

    // HOLD constraint: after each primary correction, compensate drift
    // on a secondary axis with a single Newton step.
    LOCAL holdParam IS "".
    LOCAL holdValue IS 0.
    IF opts:HASKEY("HOLD") {
        SET holdParam TO opts["HOLD"]["PARAM"].
        SET holdValue TO opts["HOLD"]["VALUE"].
    }

    // Seed bias (e.g. ±5 m/s normal for polar vs retropolar)
    IF bias <> 0 AND _ntGetAxis(nd, param) = 0 {
        _ntSetAxis(nd, param, bias).
        WAIT 0.02.
    }

    LOCAL label IS param.
    LOCAL fmtVal IS ROUND(targetVal, CHOOSE 1 IF isAngle ELSE 0).
    IF bias <> 0 {
        mLog(label + ": targeting " + fmtVal + " (bias=" + bias + ")").
    } ELSE {
        mLog(label + ": targeting " + fmtVal).
    }

    LOCAL lastGood  IS _ntGetAxis(nd, param).
    LOCAL stepScale IS 1.0.

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        LOCAL p IS _getTargetPatch(nd, targetBody).
        IF p = 0 {
            // No encounter patch at all — backtrack toward last good value
            LOCAL midVal IS (_ntGetAxis(nd, param) + lastGood) / 2.
            _ntSetAxis(nd, param, midVal).
            WAIT 0.02.
            LOCAL pMid IS _getTargetPatch(nd, targetBody).
            IF pMid <> 0 {
                SET lastGood TO midVal.
                SET stepScale TO stepScale * 0.5.
                mLog("  " + label + "[" + i + "]: backtracked.").
            } ELSE {
                _ntSetAxis(nd, param, lastGood).
                SET stepScale TO stepScale * 0.5.
                IF stepScale < 0.05 {
                    mLog("  " + label + "[" + i + "]: step too small, stopping.").
                    BREAK.
                }
                mLog("  " + label + "[" + i + "]: reverted.").
            }
        } ELSE {
            SET lastGood TO _ntGetAxis(nd, param).
            LOCAL current IS _ntReadParam(p, param).
            LOCAL err IS targetVal - current.
            IF isAngle {
                IF err >  180 { SET err TO err - 360. }
                IF err < -180 { SET err TO err + 360. }
            }

            IF ABS(err) < tol {
                mLog("  " + label + "[" + i + "] converged: " + ROUND(current, 1)).
                BREAK.
            }

            // Finite difference for sensitivity — try +eps, fall back to -eps
            LOCAL oldVal IS _ntGetAxis(nd, param).
            _ntSetAxis(nd, param, oldVal + eps).
            WAIT 0.02.
            LOCAL p2 IS _getTargetPatch(nd, targetBody).
            LOCAL probeSign IS 1.
            IF p2 = 0 {
                // +eps lost encounter, try -eps
                _ntSetAxis(nd, param, oldVal - eps).
                WAIT 0.02.
                SET p2 TO _getTargetPatch(nd, targetBody).
                SET probeSign TO -1.
                IF p2 = 0 {
                    _ntSetAxis(nd, param, oldVal).
                    mLog("  " + label + "[" + i + "]: probe lost encounter both dirs.").
                    BREAK.
                }
            }
            _ntSetAxis(nd, param, oldVal).

            LOCAL current2 IS _ntReadParam(p2, param).
            LOCAL delta IS current2 - current.
            IF isAngle {
                IF delta >  180 { SET delta TO delta - 360. }
                IF delta < -180 { SET delta TO delta + 360. }
            }

            LOCAL sens IS delta / (eps * probeSign).
            IF ABS(sens) < 0.001 {
                mLog("  " + label + "[" + i + "]: low sensitivity, skipping.").
            } ELSE {
                LOCAL correction IS (err / sens) * damp.
                LOCAL maxStep IS CHOOSE MAX(5.0, ABS(err) / 3) IF isAngle ELSE MIN(20, MAX(3.0, ABS(err) / 10000)).
                SET maxStep TO maxStep * stepScale.
                IF correction >  maxStep { SET correction TO  maxStep. }
                IF correction < -maxStep { SET correction TO -maxStep. }

                _ntSetAxis(nd, param, oldVal + correction).
                WAIT 0.02.

                // dV cap check (MCC) — per-axis so INC (normal) and PE
                // (prograde) don't compete for the same budget.
                IF dvCap >= 0 AND ABS(_ntGetAxis(nd, param)) > dvCap {
                    _ntSetAxis(nd, param, lastGood).
                    mLog("  " + label + "[" + i + "]: dV cap (" + dvCap + " m/s) reached.").
                    BREAK.
                }

                // Verify encounter survives the correction
                LOCAL pCheck IS _getTargetPatch(nd, targetBody).
                IF pCheck = 0 {
                    _ntSetAxis(nd, param, oldVal + correction / 2).
                    WAIT 0.02.
                    LOCAL pHalf IS _getTargetPatch(nd, targetBody).
                    IF pHalf = 0 {
                        _ntSetAxis(nd, param, lastGood).
                        SET stepScale TO stepScale * 0.5.
                        mLog("  " + label + "[" + i + "]: correction lost encounter, reverted.").
                    }
                }

                mLog("  " + label + "[" + i + "] " + ROUND(current, 1) + " corr=" + ROUND(correction, 2) + " m/s").

                // --- HOLD compensation ---
                // After each primary correction, apply a single Newton step
                // on the held axis to compensate for coupling drift.
                IF holdParam <> "" {
                    LOCAL hp IS _getTargetPatch(nd, targetBody).
                    IF hp <> 0 {
                        LOCAL hIsAngle IS (holdParam <> "PE").
                        LOCAL hCurrent IS _ntReadParam(hp, holdParam).
                        LOCAL hErr IS holdValue - hCurrent.
                        IF hIsAngle {
                            IF hErr >  180 { SET hErr TO hErr - 360. }
                            IF hErr < -180 { SET hErr TO hErr + 360. }
                        }
                        LOCAL hTol IS CHOOSE 0.5 IF hIsAngle ELSE 500.
                        IF ABS(hErr) > hTol {
                            LOCAL hOld IS _ntGetAxis(nd, holdParam).
                            LOCAL hEps IS CHOOSE 0.5 IF hIsAngle ELSE 0.1.
                            _ntSetAxis(nd, holdParam, hOld + hEps).
                            WAIT 0.02.
                            LOCAL hp2 IS _getTargetPatch(nd, targetBody).
                            IF hp2 <> 0 {
                                LOCAL hCurrent2 IS _ntReadParam(hp2, holdParam).
                                LOCAL hDelta IS hCurrent2 - hCurrent.
                                IF hIsAngle {
                                    IF hDelta >  180 { SET hDelta TO hDelta - 360. }
                                    IF hDelta < -180 { SET hDelta TO hDelta + 360. }
                                }
                                LOCAL hSens IS hDelta / hEps.
                                IF ABS(hSens) > 0.001 {
                                    LOCAL hCorr IS (hErr / hSens) * 0.7.
                                    _ntSetAxis(nd, holdParam, hOld + hCorr).
                                    WAIT 0.02.
                                    // Verify encounter survived
                                    IF _getTargetPatch(nd, targetBody) = 0 {
                                        _ntSetAxis(nd, holdParam, hOld).
                                    }
                                } ELSE {
                                    _ntSetAxis(nd, holdParam, hOld).
                                }
                            } ELSE {
                                _ntSetAxis(nd, holdParam, hOld).
                            }
                        }
                    }
                }
            }
        }
    }
}

// Helpers for newtonTarget — map param name to patch field and node axis.
// PE → PROGRADE, INC → NORMAL, LAN → NORMAL, AOP → RADIALOUT
LOCAL FUNCTION _ntReadParam {
    PARAMETER p, param.
    IF param = "PE"  { RETURN p:PERIAPSIS. }
    IF param = "INC" { RETURN p:INCLINATION. }
    IF param = "LAN" { RETURN p:LAN. }
    IF param = "AOP" { RETURN p:ARGUMENTOFPERIAPSIS. }
    RETURN 0.
}

LOCAL FUNCTION _ntGetAxis {
    PARAMETER nd, param.
    IF param = "PE"  { RETURN nd:PROGRADE. }
    IF param = "INC" { RETURN nd:NORMAL. }
    IF param = "LAN" { RETURN nd:NORMAL. }
    IF param = "AOP" { RETURN nd:RADIALOUT. }
    RETURN 0.
}

LOCAL FUNCTION _ntSetAxis {
    PARAMETER nd, param, val.
    IF param = "PE"  { SET nd:PROGRADE   TO val. }
    IF param = "INC" { SET nd:NORMAL     TO val. }
    IF param = "LAN" { SET nd:NORMAL     TO val. }
    IF param = "AOP" { SET nd:RADIALOUT  TO val. }
}
