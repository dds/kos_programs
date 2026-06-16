// ============================================================
// maneuver_targeting.ks  —  Orbital element targeting, search,
//     and optimization  (0:/lib/maneuver_targeting.ks)
//
// Split from maneuver.ks — contains the targeting/search
// algorithms used by transfer, MCC, and
// external callers (maneuver_intersystem, maneuver_rendezvous).
//
// Provides:
//   _getTargetPatch          — walk patched conics to find direct target SOI
//   _findEncounter           — binary time search for encounter
//   _targetPatchElementsCoupled — coordinate search for PE/INC/LAN/AOP
//   _patchElementsCost       — cost function for element targeting
//   _patchElementsCostFromPatch — cost from an orbit patch directly
//   _elementsConverged       — convergence check
//   newtonTarget             — Newton-Raphson for single orbital param
//   _nodeAxisGet / _nodeAxisSet — node axis read/write by name
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL ALLOW_GRAVITY_ASSIST IS 0.
GLOBAL TRANSFER_AOP_ERR_TOL IS 30.
GLOBAL TRANSFER_AOP_SCAN_TOL IS 20.


// ============================================================
// _patchTransitAllowed — direct-transfer patch-chain guard.
//
// Without gravity-assist planning, an encounter with a wrong peer body
// before the target is not a valid "eventual target" solution. We still
// allow ordinary parent-SOI transits:
//   Kerbin -> Sun -> Duna
//   Sun -> Jool -> Laythe
// but reject paths like Kerbin -> Mun -> Minmus unless gravity assists
// are explicitly enabled.
// ============================================================
GLOBAL FUNCTION _patchTransitAllowed {
    PARAMETER fromBody.
    PARAMETER nextBody.
    PARAMETER targetBody.

    IF nextBody:NAME = targetBody:NAME { RETURN TRUE. }
    IF nextBody = fromBody:BODY AND targetBody:BODY <> fromBody { RETURN TRUE. }
    IF nextBody = targetBody:BODY AND targetBody:BODY <> fromBody { RETURN TRUE. }
    RETURN FALSE.
}

GLOBAL FUNCTION _patchAllowGravityAssist {
    IF ALLOW_GRAVITY_ASSIST <> 0 {
        RETURN ALLOW_GRAVITY_ASSIST <> 0.
    }
    RETURN FALSE.
}

// ============================================================
// _getTargetPatch — walk patched conics to find the orbit patch
// around the target body. By default this only accepts a direct
// transfer chain; set ALLOW_GRAVITY_ASSIST=1 to permit
// wrong-body intermediate encounters.
// ============================================================
GLOBAL FUNCTION _getTargetPatch {
    PARAMETER originTarget.
    PARAMETER targetBody.
    PARAMETER allowGravityAssist IS _patchAllowGravityAssist().

    LOCAL p IS originTarget:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        LOCAL fromBody IS p:BODY.
        SET p TO p:NEXTPATCH.
        IF p:BODY:NAME = targetBody:NAME { RETURN p. }
        IF NOT allowGravityAssist AND NOT _patchTransitAllowed(fromBody, p:BODY, targetBody) {
            RETURN 0.
        }
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
    LOCAL quiet IS FALSE.

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
    IF opts:HASKEY("QUIET")        { SET quiet              TO opts["QUIET"]. }

    LOCAL best IS _patchElementsCost(nd, targetBody, targets).
    LOCAL solved IS FALSE.
    LOCAL aopGuideTol IS 35.
    LOCAL bestAopGuideErr IS 999.
    LOCAL aopGuideStallCount IS 0.
    SET aopGuideTol TO TRANSFER_AOP_ERR_TOL.
    SET aopGuideTol TO MAX(5, aopGuideTol * 0.67).
    SET aopGuideTol TO TRANSFER_AOP_SCAN_TOL.
    IF targets:HASKEY("AOP_GUIDE") { SET bestAopGuideErr TO ABS(best["AOP_ERR"]). }
    IF NOT quiet {
        mLog("ELEMENTS: coupled target"
            + _elementTargetSummary(targets)
            + " start" + _elementStateSummary(best)).
        mLogWarn("STATS elements setup target=" + targetBody:NAME
            + _elementTargetSummary(targets)
            + " start" + _elementStateSummary(best)
            + " maxIter=" + maxIter
            + " dvCap=" + ROUND(dvCap,1)).
    }

    FROM { LOCAL i IS 0. } UNTIL i >= maxIter STEP { SET i TO i + 1. } DO {
        IF i >= minIter AND _elementsConverged(best, targets) {
            SET solved TO TRUE.
            IF NOT quiet { mLog("  ELEMENTS[" + i + "] converged" + _elementStateSummary(best)). }
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
            IF NOT quiet {
                mLog("  ELEMENTS[" + i + "] " + bestAxis
                    + "=" + ROUND(bestValue, 2)
                    + _elementStateSummary(best)
                    + " cost=" + ROUND(best["COST"], 2)).
            }
        } ELSE {
            FOR axis IN axes {
                SET steps[axis] TO steps[axis] / 2.
            }
            IF NOT quiet {
                mLog("  ELEMENTS[" + i + "] refining steps: P="
                    + ROUND(steps["PROGRADE"], 2)
                    + " N=" + ROUND(steps["NORMAL"], 2)
                    + " R=" + ROUND(steps["RADIALOUT"], 2)
                    + " T=" + ROUND(steps["TIME"], 1)).
            }

            LOCAL stepsSmall IS FALSE.
            IF steps["PROGRADE"] < minStep AND steps["NORMAL"] < minStep {
                IF steps["RADIALOUT"] < minStep AND steps["TIME"] < 1 {
                    SET stepsSmall TO TRUE.
                }
            }
            IF stepsSmall {
                IF NOT quiet { mLogWarn("  ELEMENTS: stopped" + _elementStateSummary(best)). }
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
            IF i >= minIter AND aopGuideStallCount >= aopGuideStallIter {
                IF NOT quiet {
                    mLogWarn("  ELEMENTS: AoP guide stalled err="
                        + ROUND(guideErr,1)
                        + " best=" + ROUND(bestAopGuideErr,1)
                        + " tol=" + ROUND(aopGuideTol,1)
                        + " count=" + aopGuideStallCount).
                }
                BREAK.
            }
        }
    }

    IF NOT solved {
        SET best TO _patchElementsCost(nd, targetBody, targets).
        IF NOT quiet { mLogWarn("ELEMENTS final error" + _elementErrorSummary(best, targets)). }
    }

    SET best TO _patchElementsCost(nd, targetBody, targets).
    best:ADD("SOLVED", solved).
    IF NOT quiet {
        mLogWarn("STATS elements result target=" + targetBody:NAME
            + " solved=" + solved
            + _elementStateSummary(best)
            + _elementErrorSummary(best, targets)
            + " cost=" + ROUND(best["COST"],2)
            + " dv=" + ROUND(nd:DELTAV:MAG,1)).
    }

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
    LOCAL hasPatch IS FALSE.

    IF p = 0 {
        SET score TO score + 1000000.
    } ELSE {
        SET hasPatch TO TRUE.
    }

    RETURN LEXICON(
        "SCORE", score,
        "PATCH", hasPatch,
        "CA", caDist,
        "DV", dvMag
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
        SET aopGuideTol TO TRANSFER_AOP_ERR_TOL.
        SET aopGuideTol TO MAX(5, aopGuideTol * 0.67).
        SET aopGuideTol TO TRANSFER_AOP_SCAN_TOL.
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
    LOCAL prevCorr IS 0.
    LOCAL oscCount IS 0.

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

                // Detect alternating-sign oscillation (limit cycle)
                IF prevCorr <> 0 AND correction * prevCorr < 0 {
                    SET oscCount TO oscCount + 1.
                } ELSE {
                    SET oscCount TO 0.
                }
                SET prevCorr TO correction.
                IF oscCount >= 3 {
                    SET stepScale TO stepScale * 0.5.
                    SET oscCount TO 0.
                    mLog("  " + label + "[" + i + "]: oscillation detected, halving step.").
                }

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
