// ============================================================
// arrival_bplane.ks  —  B-plane arrival targeting
// (0:/lib/arrival_bplane.ks)
//
// Mid-coast correction that steers the arrival hyperbola at the
// target body to a requested plane (INC, LAN) and periapsis (PE)
// using B-plane coordinates — the standard technique for real
// interplanetary navigation.
//
// Why B-plane instead of iterating on patch elements directly:
// patch INC/LAN/PE jump discontinuously as the encounter geometry
// shifts, which is what made the old 4-axis coordinate-descent
// solver stall. The B-vector (the aim point in the plane
// perpendicular to the incoming asymptote) is a SMOOTH, nearly
// LINEAR function of small correction burns, so a 2x2 Newton
// iteration on (B.T, B.R) converges in a handful of steps.
//
// Geometry used (all derived per-iteration from the live patch):
//   v∞² = -mu/a                 (hyperbolic excess speed)
//   S   = incoming asymptote direction
//   B   = aim vector, |B| = b = h/v∞ (hyperbola semi-minor axis)
//   T   = unit(S x north), R = unit(S x T)   (B-plane axes)
// Target B is built from the requested plane normal n_t:
//   the final orbit plane must CONTAIN S, so n_t is projected
//   perpendicular to S first (logged when the requested plane is
//   infeasible for this arrival — fix it by departing on a
//   different window, or accept the closest achievable plane).
//   B_t = b_t * unit(n_t x S),  b_t from the requested PE.
//
// Robustness notes:
//   - Velocities are sampled by numeric differentiation of
//     POSITIONAT, sidestepping VELOCITYAT frame ambiguities.
//   - The eccentricity vector uses the cross-product-free form
//     e = ((v·v - mu/r) r - (r·v) v) / mu, immune to handedness.
//   - The B-plane handedness is calibrated against the measured
//     patch itself, not assumed from KSP coordinate conventions.
//
// Phase: BPLANE  (PHASE BPLANE = arrival_bplane)
//
// Global config keys:
//   CAPTURE_PE   — required: target periapsis altitude (m)
//   CAPTURE_INC  — optional: target inclination (deg)
//   CAPTURE_LAN  — optional: target LAN (deg)
//   BPLANE_TARGET  — optional body name (default: state "target")
//   BPLANE_DV_CAP  — max correction dV in m/s (default 150)
//   BPLANE_PE_TOL  — PE tolerance in m (default 2000)
//   BPLANE_ANG_TOL — plane tolerance in deg (default 0.5)
//   BPLANE_LEAD    — seconds from now to the burn (default 300)
//   BPLANE_EXISTING_NODE_MIN_ETA — min ETA to reuse a B-plane node
//   BPLANE_OFFPLANE_TOL — max feasible plane/asymptote tilt (default 10)
//   BPLANE_SAFE_HANDOFF_SOI_MULT — Pe/SOI accepted on no-correction handoff
//   REFINE_BPLANE_DV_CAP    — max dV per refinement burn (default 10)
//   REFINE_BPLANE_MAX_BURNS — max refinement burns per phase call (default 6)
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL CAPTURE_PE IS -1.
GLOBAL CAPTURE_INC IS -1.
GLOBAL CAPTURE_LAN IS -1.
GLOBAL CAPTURE_AOP IS -1.
GLOBAL CAPTURE_DIR IS "".
GLOBAL BPLANE_DV_CAP IS 150.
GLOBAL BPLANE_PE_TOL IS 2000.
GLOBAL BPLANE_ANG_TOL IS 0.2.
GLOBAL BPLANE_LEAD IS 300.
GLOBAL BPLANE_EXISTING_NODE_MIN_ETA IS 30.
GLOBAL BPLANE_TARGET IS "".
GLOBAL BPLANE_OFFPLANE_TOL IS 10.
GLOBAL BPLANE_SAFE_HANDOFF_SOI_MULT IS 1.0.
GLOBAL REFINE_BPLANE_DV_CAP IS 10.
GLOBAL REFINE_BPLANE_MAX_BURNS IS 6.
// Optional-correction limits for an EXISTING encounter. A genuinely
// missing patch still uses the recovery cap. Negative = disabled.
GLOBAL BPLANE_TRIM_DV_CAP IS -1.
GLOBAL BPLANE_TRIM_TOTAL_DV_CAP IS -1.
GLOBAL BPLANE_TRIM_RESERVE_DV IS -1.
GLOBAL BPLANE_MAX_ARRIVAL_SHIFT IS -1.
GLOBAL BPLANE_MAX_CAPTURE_DV_INCREASE IS -1.
GLOBAL TARGET_AP IS -1.
// Opt-in capture recovery: solve only Pe, preserving fuel for capture.
GLOBAL BPLANE_PE_ONLY IS 0.
GLOBAL BPLANE_CAPTURE_MARGIN IS -1.


LOCAL DEFAULT_DV_CAP   IS 150.
LOCAL DEFAULT_PE_TOL   IS 2000.
LOCAL DEFAULT_ANG_TOL  IS 0.5.
LOCAL DEFAULT_LEAD     IS 300.
LOCAL MIN_EXEC_DV      IS 0.3.
LOCAL MAX_NEWTON_ITER  IS 8.
LOCAL NEWTON_DAMP      IS 0.7.
LOCAL FD_STEP          IS 0.05.
LOCAL ACQUIRE_INITIAL_STEP IS 2.0.
LOCAL ACQUIRE_MIN_STEP     IS 0.05.
LOCAL ACQUIRE_STEP_GROWTH  IS 1.2.
LOCAL MAX_ACQUIRE_ITER     IS 150.
LOCAL MAX_BURNS        IS 2.

LOCAL FUNCTION _bplaneTrimSpent {
    PARAMETER targetBody.
    LOCAL id IS targetBody:NAME + ":" + stateGetNum("launch_time", 0).
    IF stateGet("bplane_budget_id", "") <> id {
        stateSet("bplane_budget_id", id).
        stateSet("bplane_budget_spent", 0).
    }
    RETURN stateGetNum("bplane_budget_spent", 0).
}

LOCAL FUNCTION _bplaneTrimCap {
    PARAMETER targetBody, phaseCap.
    IF findArrivalPatch(0, targetBody) = 0 { RETURN phaseCap. }
    LOCAL cap IS phaseCap.
    IF BPLANE_TRIM_DV_CAP >= 0 { SET cap TO MIN(cap, BPLANE_TRIM_DV_CAP). }
    IF BPLANE_TRIM_TOTAL_DV_CAP >= 0 {
        SET cap TO MIN(cap, BPLANE_TRIM_TOTAL_DV_CAP - _bplaneTrimSpent(targetBody)).
    }
    IF BPLANE_TRIM_RESERVE_DV >= 0 {
        // Stock vacuum dV is an estimate; zero leaves no optional budget.
        SET cap TO MIN(cap, SHIP:DELTAV:VACUUM - BPLANE_TRIM_RESERVE_DV).
    }
    RETURN MAX(0, cap).
}

LOCAL FUNCTION _bplaneHoldCorrection {
    PARAMETER reason.
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    mLogWarn("STATS bplane decision=hold reason=" + reason
        + " remainingVacDv=" + ROUND(SHIP:DELTAV:VACUUM, 1)
        + " reserveDv=" + BPLANE_TRIM_RESERVE_DV).
    mLogWarn("Arrival correction rejected; original trajectory retained. "
        + "Review the encounter and remaining mission before resuming.").
    yieldToPrompt().
}

LOCAL FUNCTION _bplaneLogBaseline {
    PARAMETER targetBody, phaseCap.
    LOCAL hit IS findArrivalPatch(0, targetBody).
    IF hit = 0 {
        mLog("STATS bplane baseline target=" + targetBody:NAME + " patch=False").
        RETURN.
    }
    LOCAL patch IS hit["patch"].
    mLog("STATS bplane baseline target=" + targetBody:NAME
        + " phase=" + stateGet("phase", "")
        + " patch=True PeKm=" + ROUND(patch:PERIAPSIS / 1000, 2)
        + " inc=" + ROUND(patch:INCLINATION, 2)
        + " entryUt=" + ROUND(hit["entryUt"], 1)
        + " remainingVacDv=" + ROUND(SHIP:DELTAV:VACUUM, 1)
        + " correctionCap=" + ROUND(_bplaneTrimCap(targetBody, phaseCap), 2)).
}

LOCAL FUNCTION _bplaneCaptureCost {
    PARAMETER patch, targetBody.
    LOCAL rp IS targetBody:RADIUS + patch:PERIAPSIS.
    IF rp <= 0 { RETURN 1.0e9. }
    LOCAL apAlt IS MAX(35000, patch:PERIAPSIS).
    IF TARGET_AP >= 0 { SET apAlt TO MAX(TARGET_AP, patch:PERIAPSIS). }
    LOCAL ra IS targetBody:RADIUS + apAlt.
    LOCAL incoming IS SQRT(targetBody:MU * (1 + patch:ECCENTRICITY) / rp).
    LOCAL captured IS SQRT(targetBody:MU * (2 / rp - 2 / (rp + ra))).
    RETURN MAX(0, incoming - captured).
}

// Read raw patches: POSITIONAT would include the pending correction and
// contaminate the comparison against the unburned encounter.
LOCAL FUNCTION _bplaneCorrectionAllowed {
    PARAMETER nd, targetBody, phaseCap.
    LOCAL cap IS _bplaneTrimCap(targetBody, phaseCap).
    LOCAL original IS findArrivalPatch(0, targetBody).
    LOCAL planned IS findArrivalPatch(nd, targetBody).
    mLog("STATS bplane budget dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " cap=" + ROUND(cap, 2)
        + " remainingVacDv=" + ROUND(SHIP:DELTAV:VACUUM, 1)
        + " spent=" + ROUND(_bplaneTrimSpent(targetBody), 2)
        + " originalPatch=" + (original <> 0)
        + " plannedPatch=" + (planned <> 0)).
    IF planned = 0 {
        _bplaneHoldCorrection("planned-encounter-missing"). RETURN FALSE.
    }
    LOCAL shift IS 0.
    LOCAL beforeCost IS 0.
    LOCAL afterCost IS 0.
    IF original <> 0 {
        SET shift TO ABS(planned["entryUt"] - original["entryUt"]).
        SET beforeCost TO _bplaneCaptureCost(original["patch"], targetBody).
        SET afterCost TO _bplaneCaptureCost(planned["patch"], targetBody).
        mLog("STATS bplane comparison originalPeKm=" + ROUND(original["patch"]:PERIAPSIS / 1000, 2)
            + " originalInc=" + ROUND(original["patch"]:INCLINATION, 2)
            + " originalEntryUt=" + ROUND(original["entryUt"], 1)
            + " plannedPeKm=" + ROUND(planned["patch"]:PERIAPSIS / 1000, 2)
            + " plannedInc=" + ROUND(planned["patch"]:INCLINATION, 2)
            + " plannedEntryUt=" + ROUND(planned["entryUt"], 1)
            + " shiftSeconds=" + ROUND(shift, 1)
            + " captureBeforeDv=" + ROUND(beforeCost, 2)
            + " captureAfterDv=" + ROUND(afterCost, 2)).
    }
    IF nd:DELTAV:MAG > cap + 0.001 {
        _bplaneHoldCorrection("correction-budget"). RETURN FALSE.
    }
    IF BPLANE_CAPTURE_MARGIN >= 0 {
        LOCAL needed IS nd:DELTAV:MAG
            + _bplaneCaptureCost(planned["patch"], targetBody) + BPLANE_CAPTURE_MARGIN.
        mLog("STATS bplane capture-budget neededDv=" + ROUND(needed, 2)
            + " marginDv=" + BPLANE_CAPTURE_MARGIN
            + " availableDv=" + ROUND(SHIP:DELTAV:VACUUM, 2)).
        IF needed > SHIP:DELTAV:VACUUM {
            _bplaneHoldCorrection("correction-plus-capture-budget"). RETURN FALSE.
        }
    }
    IF original = 0 { RETURN TRUE. }
    IF BPLANE_MAX_ARRIVAL_SHIFT >= 0 AND shift > BPLANE_MAX_ARRIVAL_SHIFT {
        _bplaneHoldCorrection("arrival-time-shift"). RETURN FALSE.
    }
    IF BPLANE_MAX_CAPTURE_DV_INCREASE >= 0
            AND afterCost - beforeCost > BPLANE_MAX_CAPTURE_DV_INCREASE {
        _bplaneHoldCorrection("capture-cost-increase"). RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneReserveCorrection {
    PARAMETER nd, targetBody.
    IF findArrivalPatch(0, targetBody) = 0 { RETURN. }
    // Reserve planned cost before ignition; a power cut / partial burn
    // must not reset the allowance on the next boot.
    stateSet("bplane_budget_spent", _bplaneTrimSpent(targetBody) + nd:DELTAV:MAG).
}

LOCAL FUNCTION _bplaneSafeEncounter {
    PARAMETER targetBody.
    PARAMETER meas.

    IF meas = 0 { RETURN FALSE. }
    RETURN meas["pe"] <= targetBody:SOIRADIUS * BPLANE_SAFE_HANDOFF_SOI_MULT.
}

LOCAL FUNCTION _bplaneNeedsDepartureSoiCoast {
    PARAMETER targetBody.

    IF SHIP:BODY = targetBody { RETURN FALSE. }
    IF NOT SHIP:BODY:HASBODY { RETURN FALSE. }
    IF NOT targetBody:HASBODY { RETURN FALSE. }
    RETURN SHIP:BODY:BODY = targetBody:BODY AND SHIP:BODY <> targetBody:BODY.
}

LOCAL FUNCTION _bplaneCoastOutOfDepartureSoi {
    PARAMETER targetBody.

    IF NOT _bplaneNeedsDepartureSoiCoast(targetBody) { RETURN TRUE. }
    LOCAL departureBody IS SHIP:BODY.
    LOCAL transferCenter IS departureBody:BODY.
    IF NOT SHIP:ORBIT:HASNEXTPATCH {
        mLogError("BPLANE: still inside " + departureBody:NAME
            + " SOI and no escape patch is available; holding before "
            + "arrival targeting.").
        WAIT 30.
        RETURN FALSE.
    }
    mLogWarn("BPLANE: still inside " + departureBody:NAME
        + " SOI; coasting to " + transferCenter:NAME
        + " before arrival B-plane correction.").
    waitForSOI(transferCenter, 10).
    orbitSummary().
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneCorridorError {
    PARAMETER targetBody, meas, wantPe, wantInc, wantLan.

    LOCAL tgt IS targetBplaneVector(targetBody, meas, wantPe, wantInc, wantLan).
    LOCAL planeErr IS _bplaneElementPlaneError(
        meas["inc"], meas["lan"], wantInc, wantLan).
    // Keep the closest-achievable-plane policy for a tilted asymptote,
    // but never reject elements that already satisfy the actual request.
    IF wantInc >= 0 AND wantLan >= 0 AND tgt["offPlane"] > 0.5 {
        SET planeErr TO MIN(planeErr, VANG(meas["hHat"], tgt["normal"])).
    }
    RETURN LEX("peErr", meas["pe"] - wantPe,
        "planeErr", planeErr,
        "target", tgt).
}

LOCAL FUNCTION _bplaneElementPlaneError {
    PARAMETER inc, lan, wantInc, wantLan.
    IF wantInc < 0 { RETURN 0. }
    IF wantLan < 0 { RETURN ABS(inc - wantInc). }
    // Compare requested elements, independently of the reconstructed
    // B-plane basis. LAN has no weight at an equatorial target.
    LOCAL cosPlane IS COS(inc) * COS(wantInc)
        + SIN(inc) * SIN(wantInc) * COS(lan - wantLan).
    RETURN ARCCOS(MAX(-1, MIN(1, cosPlane))).
}

LOCAL FUNCTION _bplaneCurrentCorridorOk {
    PARAMETER targetBody, wantPe, wantInc, wantLan.
    // Check the unburned patch before creating/reusing a node.
    // POSITIONAT(SHIP, ...) includes pending maneuvers, so it must
    // not supply the geometry for this no-burn acceptance decision.
    LOCAL hit IS findArrivalPatch(0, targetBody).
    IF hit = 0 { RETURN FALSE. }
    LOCAL patch IS hit["patch"].
    LOCAL peErr IS ABS(patch:PERIAPSIS - wantPe).
    LOCAL planeErr IS _bplaneElementPlaneError(
        patch:INCLINATION, patch:LAN, wantInc, wantLan).
    IF peErr > BPLANE_PE_TOL OR planeErr > BPLANE_ANG_TOL { RETURN FALSE. }
    mLog("BPLANE: current trajectory already in corridor; no correction. "
        + "PeErrKm=" + ROUND(peErr / 1000, 2)
        + " planeErr=" + ROUND(planeErr, 3)).
    RETURN TRUE.
}

LOCAL FUNCTION _bplanePlaneFeasible {
    PARAMETER err.
    RETURN err["target"]["offPlane"] <= BPLANE_OFFPLANE_TOL.
}

LOCAL FUNCTION _bplaneCorridorOk {
    PARAMETER err.
    PARAMETER wantInc.
    PARAMETER peTol.
    PARAMETER angTol.

    IF ABS(err["peErr"]) > peTol { RETURN FALSE. }
    IF wantInc < 0 { RETURN TRUE. }
    IF NOT _bplanePlaneFeasible(err) { RETURN TRUE. }
    RETURN err["planeErr"] <= angTol.
}

LOCAL FUNCTION _bplanePlanScore {
    PARAMETER err.
    PARAMETER targetBody.
    PARAMETER wantInc.

    // Error inside the corridor costs nothing. Otherwise the search
    // can prefer an exact Pe with a bad plane over an acceptable orbit.
    LOCAL score IS MAX(0, ABS(err["peErr"]) - BPLANE_PE_TOL).
    IF wantInc >= 0 AND _bplanePlaneFeasible(err) {
        SET score TO score + MAX(0, err["planeErr"] - BPLANE_ANG_TOL)
            * targetBody:SOIRADIUS / 90.
    }
    RETURN score.
}

LOCAL FUNCTION _bplaneNodeAxisGet {
    PARAMETER nd.
    PARAMETER axis.

    IF axis = "PROGRADE" { RETURN nd:PROGRADE. }
    IF axis = "RADIALOUT" { RETURN nd:RADIALOUT. }
    IF axis = "NORMAL" { RETURN nd:NORMAL. }
    RETURN 0.
}

LOCAL FUNCTION _bplaneNodeAxisSet {
    PARAMETER nd.
    PARAMETER axis.
    PARAMETER val.

    IF axis = "PROGRADE" { SET nd:PROGRADE TO val. }
    IF axis = "RADIALOUT" { SET nd:RADIALOUT TO val. }
    IF axis = "NORMAL" { SET nd:NORMAL TO val. }
}

LOCAL FUNCTION _bplaneFallbackSearch {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    PARAMETER dvCap.
    PARAMETER currentScore.
    PARAMETER iter.
    PARAMETER peOnly IS FALSE.

    LOCAL axes IS LIST("PROGRADE", "RADIALOUT", "NORMAL").
    IF peOnly { SET axes TO LIST("PROGRADE", "RADIALOUT"). }
    LOCAL signs IS LIST(1, -1).
    LOCAL steps IS LIST(10.0, 5.0, 2.0, 1.0, 0.5, 0.1, 0.05, 0.01).

    LOCAL p0 IS nd:PROGRADE.
    LOCAL r0 IS nd:RADIALOUT.
    LOCAL n0 IS nd:NORMAL.
    LOCAL bestAxis IS "".
    LOCAL bestVal IS 0.
    LOCAL bestScore IS currentScore.
    LOCAL bestMeas IS 0.
    LOCAL bestErr IS 0.

    FOR step IN steps {
        FOR axis IN axes {
            LOCAL oldVal IS _bplaneNodeAxisGet(nd, axis).
            FOR sgn IN signs {
                SET nd:PROGRADE TO p0.
                SET nd:RADIALOUT TO r0.
                SET nd:NORMAL TO n0.
                LOCAL trialVal IS oldVal + sgn * step.
                _bplaneNodeAxisSet(nd, axis, trialVal).
                WAIT 0.02.
                IF nd:DELTAV:MAG <= dvCap {
                    LOCAL trial IS measureArrival(nd, targetBody).
                    IF trial <> 0 {
                        LOCAL trialErr IS _bplaneCorridorError(
                            targetBody, trial, wantPe, wantInc, wantLan).
                        LOCAL trialScore IS _bplanePlanScore(
                            trialErr, targetBody, wantInc).
                        IF _bplaneCorridorOk(trialErr, wantInc,
                                BPLANE_PE_TOL, BPLANE_ANG_TOL) {
                            mLog("  BPLANE[" + iter
                                + "] fallback reached corridor; stopping search.").
                            RETURN TRUE.
                        }
                        IF trialScore < bestScore {
                            SET bestScore TO trialScore.
                            SET bestAxis TO axis.
                            SET bestVal TO trialVal.
                            SET bestMeas TO trial.
                            SET bestErr TO trialErr.
                        }
                    }
                }
            }
        }
    }

    SET nd:PROGRADE TO p0.
    SET nd:RADIALOUT TO r0.
    SET nd:NORMAL TO n0.
    WAIT 0.02.

    IF bestAxis = "" { RETURN FALSE. }

    _bplaneNodeAxisSet(nd, bestAxis, bestVal).
    WAIT 0.02.
    mLog("  BPLANE[" + iter + "] fallback "
        + bestAxis + "=" + ROUND(bestVal,2)
        + " PeKm=" + ROUND(bestMeas["pe"] / 1000,1)
        + " planeErr=" + ROUND(bestErr["planeErr"],2)
        + " scoreKm=" + ROUND(bestScore / 1000,1)
        + " dv=" + ROUND(nd:DELTAV:MAG,2)).
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneAcquireAxis {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER axis.
    PARAMETER stepSize.
    PARAMETER searchStart.
    PARAMETER searchEnd.
    PARAMETER bestD.
    PARAMETER dvCap.

    LOCAL oldVal IS _bplaneNodeAxisGet(nd, axis).
    LOCAL bestVal IS oldVal.
    LOCAL bestCA IS 0.
    LOCAL trialBestD IS bestD.
    LOCAL improved IS FALSE.
    LOCAL budgetBlocked IS FALSE.

    FOR sgn IN LIST(1, -1) {
        _bplaneNodeAxisSet(nd, axis, oldVal + sgn * stepSize).
        WAIT 0.02.
        IF dvCap < 0 OR nd:DELTAV:MAG <= dvCap {
            LOCAL ca IS _findClosestApproach(targetBody, searchStart, searchEnd, 60).
            IF ca["distance"] < trialBestD {
                SET trialBestD TO ca["distance"].
                SET bestCA TO ca.
                SET bestVal TO oldVal + sgn * stepSize.
                SET improved TO TRUE.
            }
        } ELSE {
            SET budgetBlocked TO TRUE.
        }
    }

    _bplaneNodeAxisSet(nd, axis, oldVal).
    WAIT 0.02.
    RETURN LEXICON(
        "improved", improved,
        "budgetBlocked", budgetBlocked,
        "value", bestVal,
        "ca", bestCA,
        "distance", trialBestD).
}

// ============================================================
// _acquireEncounter — if the raw flight plan is just outside the
// target SOI, hill-climb a tiny MCC node until KSP generates the
// target patch. Precision still belongs to the Newton B-plane
// solver below; this phase only reacquires the encounter.
// ============================================================
LOCAL FUNCTION _acquireEncounter {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER dvCap.

    LOCAL searchStart IS nd:TIME.
    LOCAL searchEnd IS nd:TIME + targetBody:ORBIT:PERIOD.
    LOCAL bestCA IS _findClosestApproach(targetBody, searchStart, searchEnd, 60).
    LOCAL bestD IS bestCA["distance"].
    LOCAL stepSize IS ACQUIRE_INITIAL_STEP.
    LOCAL axes IS LIST("PROGRADE", "RADIALOUT", "NORMAL").

    mLogWarn("BPLANE: encounter lost; acquiring nearest "
        + targetBody:NAME + " approach at T+"
        + ROUND(bestCA["time"] - TIME:SECONDS, 0)
        + "s CA=" + ROUND(bestD / 1000, 1) + "km"
        + " cap=" + ROUND(dvCap, 1) + "m/s.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= MAX_ACQUIRE_ITER STEP { SET iter TO iter + 1. } DO {
        IF measureArrival(nd, targetBody) <> 0 {
            mLog("BPLANE acquire: patch acquired in " + iter
                + " iter(s), dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " m/s.").
            RETURN TRUE.
        }
        IF dvCap >= 0 AND nd:DELTAV:MAG > dvCap {
            mLogWarn("BPLANE acquire: dV budget exceeded while searching (dv="
                + ROUND(nd:DELTAV:MAG, 2) + " cap="
                + ROUND(dvCap, 2) + " m/s); best CA="
                + ROUND(bestD / 1000, 1) + "km.").
            RETURN FALSE.
        }

        LOCAL improved IS FALSE.
        LOCAL budgetBlocked IS FALSE.
        LOCAL startD IS bestD.

        FOR axis IN axes {
            LOCAL trial IS _bplaneAcquireAxis(
                nd, targetBody, axis, stepSize, searchStart, searchEnd, bestD, dvCap).
            IF trial["budgetBlocked"] {
                SET budgetBlocked TO TRUE.
            }
            IF trial["improved"] {
                _bplaneNodeAxisSet(nd, axis, trial["value"]).
                WAIT 0.02.
                SET bestCA TO trial["ca"].
                SET bestD TO trial["distance"].
                SET improved TO TRUE.
            }
        }

        IF measureArrival(nd, targetBody) <> 0 {
            mLog("BPLANE acquire: patch acquired in " + (iter + 1)
                + " iter(s), dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " m/s.").
            RETURN TRUE.
        }
        IF dvCap >= 0 AND nd:DELTAV:MAG > dvCap {
            mLogWarn("BPLANE acquire: dV budget exceeded after improvement (dv="
                + ROUND(nd:DELTAV:MAG, 2) + " cap="
                + ROUND(dvCap, 2) + " m/s); best CA="
                + ROUND(bestD / 1000, 1) + "km.").
            RETURN FALSE.
        }

        IF improved {
            SET stepSize TO stepSize * ACQUIRE_STEP_GROWTH.
            mLog("  BPLANE acquire[" + iter + "] CA "
                + ROUND(startD / 1000, 1) + "->"
                + ROUND(bestD / 1000, 1) + "km step="
                + ROUND(stepSize, 2) + " dv="
                + ROUND(nd:DELTAV:MAG, 2)).
        } ELSE {
            SET stepSize TO stepSize * 0.5.
            IF budgetBlocked {
                mLogWarn("  BPLANE acquire[" + iter
                    + "] no in-budget improvement; step="
                    + ROUND(stepSize, 2) + " best CA="
                    + ROUND(bestD / 1000, 1) + "km dv="
                    + ROUND(nd:DELTAV:MAG, 2) + " cap="
                    + ROUND(dvCap, 2) + "m/s.").
            } ELSE {
                mLogWarn("  BPLANE acquire[" + iter + "] no improvement; step="
                    + ROUND(stepSize, 2) + " best CA="
                    + ROUND(bestD / 1000, 1) + "km.").
            }
            IF stepSize < ACQUIRE_MIN_STEP {
                IF budgetBlocked {
                    mLogWarn("BPLANE acquire: no improving step fits the dV budget "
                        + "(cap=" + ROUND(dvCap, 2) + "m/s); best CA="
                        + ROUND(bestD / 1000, 1) + "km dv="
                        + ROUND(nd:DELTAV:MAG, 2) + " m/s.").
                } ELSE {
                    mLogWarn("BPLANE acquire: step fell below "
                        + ACQUIRE_MIN_STEP + " m/s; best CA="
                        + ROUND(bestD / 1000, 1) + "km dv="
                        + ROUND(nd:DELTAV:MAG, 2) + " m/s.").
                }
                RETURN FALSE.
            }
        }
    }

    mLogWarn("BPLANE acquire: hit iteration cap; best CA="
        + ROUND(bestD / 1000, 1) + "km dv="
        + ROUND(nd:DELTAV:MAG, 2) + " m/s.").
    RETURN measureArrival(nd, targetBody) <> 0.
}

// A single Pe constraint needs a scalar solve, not the plane solver's
// two B-vector constraints. Differentiate KSP's actual patch elements;
// a minimum-length step in prograde/radial controls spends no normal dV.
LOCAL FUNCTION _bplanePlanPeOnly {
    PARAMETER targetBody, wantPe, dvCap.
    IF findArrivalPatch(0, targetBody) = 0 {
        _bplaneHoldCorrection("pe-recovery-encounter-missing"). RETURN 0.
    }
    LOCAL nd IS NODE(TIME:SECONDS + BPLANE_LEAD, 0, 0, 0).
    ADD nd.
    WAIT 0.1.
    LOCAL iteration IS 0.
    UNTIL iteration >= 16 {
        SET iteration TO iteration + 1.
        LOCAL hit IS findArrivalPatch(nd, targetBody).
        IF hit = 0 { BREAK. }
        LOCAL peNow IS hit["patch"]:PERIAPSIS.
        LOCAL peError IS wantPe - peNow.
        IF ABS(peError) <= BPLANE_PE_TOL {
            mLog("STATS bplane pe-only converged=True PeKm=" + ROUND(peNow / 1000, 3)
                + " dv=" + ROUND(nd:DELTAV:MAG, 3) + " iterations=" + iteration).
            // Even a sub-0.3 m/s correction can matter far from the Mun.
            // Do not throw away a needed correction as 'already there'.
            RETURN nd.
        }
        LOCAL basePro IS nd:PROGRADE.
        LOCAL baseRad IS nd:RADIALOUT.
        LOCAL gradients IS LIST().
        FOR axis IN LIST("PROGRADE", "RADIALOUT") {
            LOCAL slope IS 0.
            // Try both signs if the first probe loses the encounter.
            FOR probe IN LIST(FD_STEP, -FD_STEP) {
                _bplaneNodeAxisSet(nd, axis, _bplaneNodeAxisGet(nd, axis) + probe).
                WAIT 0.1.
                LOCAL sample IS findArrivalPatch(nd, targetBody).
                IF sample <> 0 {
                    SET slope TO (sample["patch"]:PERIAPSIS - peNow) / probe.
                }
                SET nd:PROGRADE TO basePro.
                SET nd:RADIALOUT TO baseRad.
                WAIT 0.1.
                IF sample <> 0 { BREAK. }
            }
            gradients:ADD(slope).
        }
        LOCAL grad2 IS gradients[0]^2 + gradients[1]^2.
        IF grad2 < 0.000001 { BREAK. }
        LOCAL stepPro IS peError * gradients[0] / grad2.
        LOCAL stepRad IS peError * gradients[1] / grad2.
        LOCAL stepSize IS SQRT(stepPro^2 + stepRad^2).
        LOCAL scale IS MIN(1, dvCap / MAX(0.000001, stepSize)).
        LOCAL improved IS FALSE.
        FOR fraction IN LIST(1, 0.5, 0.25, 0.125, 0.0625, 0.03125) {
            SET nd:PROGRADE TO basePro + stepPro * scale * fraction.
            SET nd:RADIALOUT TO baseRad + stepRad * scale * fraction.
            WAIT 0.1.
            IF nd:DELTAV:MAG <= dvCap + 0.001 {
                LOCAL trial IS findArrivalPatch(nd, targetBody).
                IF trial <> 0 {
                    IF ABS(trial["patch"]:PERIAPSIS - wantPe) < ABS(peError) {
                        SET improved TO TRUE. BREAK.
                    }
                }
            }
        }
        IF NOT improved { BREAK. }
    }
    LOCAL finalHit IS findArrivalPatch(nd, targetBody).
    IF finalHit <> 0 {
        mLog("STATS bplane pe-only converged=False PeKm="
            + ROUND(finalHit["patch"]:PERIAPSIS / 1000, 3)
            + " dv=" + ROUND(nd:DELTAV:MAG, 3) + " cap=" + dvCap).
    }
    _bplaneHoldCorrection("pe-recovery-not-converged-within-budget").
    RETURN 0.
}

LOCAL FUNCTION _bplaneFinishPeRecovery {
    PARAMETER targetBody, wantPe.
    // Raw patch check also works when vector reconstruction cannot.
    IF _bplaneCurrentCorridorOk(targetBody, wantPe, -1, -1) {
        mLog("STATS bplane pe-only result=inside-corridor").
        nextPhase(xferSeq).
    } ELSE {
        _bplaneHoldCorrection("pe-recovery-outside-corridor").
    }
}

LOCAL FUNCTION _bplaneClearCoastTimes {
    stateSet("xing_arrival_ut", 0).
    stateSet("midcourse_refine_ut", 0).
    stateSet("midcourse_refine_arrival_ut", 0).
}

// ============================================================
// planBplaneCorrection — build and converge a correction node.
// Newton iteration: controls (radialout, normal) -> targets
// (B.T, B.R), Jacobian by finite differences against KSP's own
// patched-conic propagation. Returns the node (already converged
// and ready to execute), or 0 when no correction is needed or
// possible. The node is REMOVEd internally on failure.
// ============================================================
GLOBAL FUNCTION planBplaneCorrection {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc IS -1.
    PARAMETER wantLan IS -1.
    PARAMETER dvCapOverride IS -1.
    PARAMETER pristineLog IS "".

    LOCAL dvCap IS BPLANE_DV_CAP.
    IF dvCapOverride >= 0 { SET dvCap TO dvCapOverride. }
    LOCAL peTol IS BPLANE_PE_TOL.
    LOCAL angTol IS BPLANE_ANG_TOL.
    LOCAL lead IS BPLANE_LEAD.

    IF _bplaneCurrentCorridorOk(targetBody, wantPe, wantInc, wantLan) {
        RETURN 0.
    }

    SET dvCap TO _bplaneTrimCap(targetBody, dvCap).
    IF dvCap < MIN_EXEC_DV {
        _bplaneHoldCorrection("no-optional-budget").
        RETURN 0.
    }

    IF BPLANE_PE_ONLY <> 0 {
        RETURN _bplanePlanPeOnly(targetBody, wantPe, dvCap).
    }

    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, 0).
    ADD nd.
    bplaneResetWarnings().
    WAIT 0.02.

    LOCAL acquired IS FALSE.
    LOCAL meas0 IS measureArrival(nd, targetBody).
    IF meas0 = 0 {
        // A failed vector measurement is not a lost encounter. Do not
        // replace a real map patch with a different closest approach.
        IF findArrivalPatch(0, targetBody) <> 0 {
            _bplaneHoldCorrection("existing-patch-unmeasurable").
            RETURN 0.
        }
        mLogWarn("BPLANE: no hyperbolic encounter with "
            + targetBody:NAME + " on the current correction node; "
            + "starting acquisition.").
        IF NOT _acquireEncounter(nd, targetBody, dvCap) {
            mLogError("BPLANE: acquisition failed for "
                + targetBody:NAME + " — removing correction node.").
            REMOVE nd.
            RETURN 0.
        }
        SET acquired TO TRUE.
        SET meas0 TO measureArrival(nd, targetBody).
        IF meas0 = 0 {
            mLogError("BPLANE: acquisition reported success but no "
                + targetBody:NAME + " patch is measurable.").
            REMOVE nd.
            RETURN 0.
        }
    }

    LOCAL err0 IS _bplaneCorridorError(targetBody, meas0, wantPe, wantInc, wantLan).
    LOCAL tgt0 IS err0["target"].
    LOCAL planeErr0 IS err0["planeErr"].
    LOCAL planeMode IS "target-plane".
    IF wantInc >= 0 AND NOT _bplanePlaneFeasible(err0) {
        SET planeMode TO "pe-only".
        mLogWarn("BPLANE: requested capture plane is "
            + ROUND(tgt0["offPlane"], 1)
            + "deg off the arrival asymptote; switching to Pe-only targeting.").
    }

    // Already in the corridor?
    IF _bplaneCorridorOk(err0, wantInc, peTol, angTol) {
        // Acquisition changed the node: this arrival still requires
        // its burn. Removing it would discard the encounter just found.
        IF acquired AND nd:DELTAV:MAG >= MIN_EXEC_DV {
            mLog("BPLANE: acquisition reached corridor; keeping correction node.").
            RETURN nd.
        }
        IF pristineLog <> "" {
            mLog(pristineLog).
        } ELSE {
            mLog("BPLANE: arrival already in corridor (PeErr="
                + ROUND((meas0["pe"] - wantPe) / 1000, 1) + "km planeErr="
                + ROUND(planeErr0, 2) + "deg).").
        }
        REMOVE nd.
        RETURN 0.
    }

    mLog("BPLANE: correcting arrival at " + targetBody:NAME
        + "  Pe " + ROUND(meas0["pe"] / 1000, 1) + "->"
        + ROUND(wantPe / 1000, 1) + "km  planeErr="
        + ROUND(planeErr0, 2) + "deg").

    LOCAL converged IS FALSE.
    LOCAL bestPro IS nd:PROGRADE.
    LOCAL bestRad IS nd:RADIALOUT.
    LOCAL bestNrm IS nd:NORMAL.
    LOCAL bestScore IS _bplanePlanScore(err0, targetBody, wantInc).
    LOCAL bestPe IS meas0["pe"].
    LOCAL bestPlaneErr IS planeErr0.
    LOCAL entryPeErr IS ABS(meas0["pe"] - wantPe).
    LOCAL entryPlaneErr IS planeErr0.

    FROM { LOCAL i IS 0. } UNTIL i >= MAX_NEWTON_ITER STEP { SET i TO i + 1. } DO {
        LOCAL meas IS measureArrival(nd, targetBody).
        IF meas = 0 {
            mLogWarn("BPLANE[" + i + "]: lost the encounter — backing off.").
            SET nd:PROGRADE TO nd:PROGRADE * 0.5.
            SET nd:RADIALOUT TO nd:RADIALOUT * 0.5.
            SET nd:NORMAL TO nd:NORMAL * 0.5.
            WAIT 0.02.
        } ELSE {
            LOCAL tgt IS targetBplaneVector(targetBody, meas, wantPe, wantInc, wantLan).
            LOCAL errT IS tgt["bt"] - meas["bt"].
            LOCAL errR IS tgt["br"] - meas["br"].
            LOCAL qT IS meas["bt"] - tgt["bt"].
            LOCAL qR IS meas["br"] - tgt["br"].
            LOCAL corrErr IS _bplaneCorridorError(
                targetBody, meas, wantPe, wantInc, wantLan).
            LOCAL planeErr IS corrErr["planeErr"].
            LOCAL score IS _bplanePlanScore(corrErr, targetBody, wantInc).
            IF score < bestScore {
                SET bestScore TO score.
                SET bestPe TO meas["pe"].
                SET bestPlaneErr TO planeErr.
                SET bestPro TO nd:PROGRADE.
                SET bestRad TO nd:RADIALOUT.
                SET bestNrm TO nd:NORMAL.
            }
            mLog("  BPLANE[" + i + "] dBT=" + ROUND(errT / 1000, 1)
                + "km dBR=" + ROUND(errR / 1000, 1)
                + "km Pe=" + ROUND(meas["pe"] / 1000, 1)
                + "km planeErr=" + ROUND(planeErr, 2)
                + " scoreKm=" + ROUND(score / 1000, 1)
                + " mode=" + planeMode
                + " dv=" + ROUND(nd:DELTAV:MAG, 2)).
            IF i = 0 {
                mLog("STATS bplane-bvec target=" + targetBody:NAME
                    + " measBtKm=" + ROUND(meas["bt"] / 1000,1)
                    + " tgtBtKm=" + ROUND(tgt["bt"] / 1000,1)
                    + " measBrKm=" + ROUND(meas["br"] / 1000,1)
                    + " tgtBrKm=" + ROUND(tgt["br"] / 1000,1)
                    + " measBMagKm=" + ROUND(meas["bMag"] / 1000,1)
                    + " tgtBMagKm=" + ROUND(tgt["bMag"] / 1000,1)
                    + " measDotBT=" + ROUND(meas["dotBT"],6)
                    + " tgtDotBT=" + ROUND(tgt["dotBT"],6)
                    + " measDotBR=" + ROUND(meas["dotBR"],6)
                    + " tgtDotBR=" + ROUND(tgt["dotBR"],6)
                    + " tgtVsMeasBAng=" + ROUND(tgt["bHatAngle"],2)
                    + " tgtSDotB=" + ROUND(tgt["sDotBH"],6)
                    + " tgtHDotB=" + ROUND(tgt["hDotBH"],6)
                    + " measBHatMag=" + ROUND(meas["bHatMag"],5)
                    + " tgtBHatMag=" + ROUND(tgt["bHatMag"],5)
                    + " tHatMag=" + ROUND(meas["tHatMag"],5)
                    + " rHatMag=" + ROUND(meas["rHatMag"],5)).
            }

            IF _bplaneCorridorOk(corrErr, wantInc, peTol, angTol) {
                SET converged TO TRUE.
                BREAK.
            }

            LOCAL p0 IS nd:PROGRADE.
            LOCAL r0 IS nd:RADIALOUT.
            LOCAL n0 IS nd:NORMAL.

            IF planeMode = "pe-only" {
                IF NOT _bplaneFallbackSearch(nd, targetBody,
                        wantPe, wantInc, wantLan, dvCap, score, i, TRUE) {
                    mLogWarn("BPLANE[" + i
                        + "]: no Pe-only fallback step improved arrival; stopping.").
                    BREAK.
                }
                LOCAL poMeas IS measureArrival(nd, targetBody).
                IF poMeas <> 0 {
                    LOCAL poErr IS _bplaneCorridorError(
                        targetBody, poMeas, wantPe, wantInc, wantLan).
                    LOCAL poScore IS _bplanePlanScore(
                        poErr, targetBody, wantInc).
                    IF poScore < bestScore {
                        SET bestScore TO poScore.
                        SET bestPe TO poMeas["pe"].
                        SET bestPlaneErr TO poErr["planeErr"].
                        SET bestPro TO nd:PROGRADE.
                        SET bestRad TO nd:RADIALOUT.
                        SET bestNrm TO nd:NORMAL.
                    }
                    IF _bplaneCorridorOk(poErr, wantInc, peTol, angTol) {
                        SET converged TO TRUE.
                        BREAK.
                    }
                }
            } ELSE {

            // Finite-difference Jacobian: d(B.T,B.R)/d(radial,normal).

            SET nd:RADIALOUT TO r0 + FD_STEP. WAIT 0.02.
            LOCAL mRad IS measureArrival(nd, targetBody).
            SET nd:RADIALOUT TO r0. WAIT 0.02.

            SET nd:NORMAL TO n0 + FD_STEP. WAIT 0.02.
            LOCAL mNrm IS measureArrival(nd, targetBody).
            SET nd:NORMAL TO n0. WAIT 0.02.

            IF mRad = 0 OR mNrm = 0 {
                mLogWarn("BPLANE[" + i + "]: probe lost encounter — stopping.").
                BREAK.
            }

            LOCAL tRad IS targetBplaneVector(targetBody, mRad, wantPe, wantInc, wantLan, TRUE).
            LOCAL tNrm IS targetBplaneVector(targetBody, mNrm, wantPe, wantInc, wantLan, TRUE).
            LOCAL j11 IS ((mRad["bt"] - tRad["bt"]) - qT) / FD_STEP.
            LOCAL j21 IS ((mRad["br"] - tRad["br"]) - qR) / FD_STEP.
            LOCAL j12 IS ((mNrm["bt"] - tNrm["bt"]) - qT) / FD_STEP.
            LOCAL j22 IS ((mNrm["br"] - tNrm["br"]) - qR) / FD_STEP.
            LOCAL det IS j11 * j22 - j12 * j21.
            IF ABS(det) < 1e-3 {
                mLogWarn("BPLANE[" + i + "]: singular Jacobian (det="
                    + ROUND(det, 5) + ") — stopping.").
                BREAK.
            }

            LOCAL dRad IS NEWTON_DAMP * ( j22 * errT - j12 * errR) / det.
            LOCAL dNrm IS NEWTON_DAMP * (-j21 * errT + j11 * errR) / det.

            // Per-step and total caps keep a bad Jacobian from
            // flinging the node into a different patch topology.
            LOCAL stepMag IS SQRT(dRad ^ 2 + dNrm ^ 2).
            LOCAL stepCap IS MAX(1, dvCap * 0.5).
            IF stepMag > stepCap {
                SET dRad TO dRad * stepCap / stepMag.
                SET dNrm TO dNrm * stepCap / stepMag.
            }
            LOCAL accepted IS FALSE.
            LOCAL bestTrialScore IS score.
            FOR frac IN LIST(1.0, 0.5, 0.25, 0.125) {
                SET nd:PROGRADE TO p0.
                SET nd:RADIALOUT TO r0 + dRad * frac.
                SET nd:NORMAL TO n0 + dNrm * frac.
                WAIT 0.02.

                IF nd:DELTAV:MAG > dvCap {
                    LOCAL scale IS dvCap / nd:DELTAV:MAG.
                    SET nd:PROGRADE TO nd:PROGRADE * scale.
                    SET nd:RADIALOUT TO nd:RADIALOUT * scale.
                    SET nd:NORMAL TO nd:NORMAL * scale.
                    WAIT 0.02.
                }

                LOCAL trial IS measureArrival(nd, targetBody).
                IF trial <> 0 {
                    LOCAL trialErr IS _bplaneCorridorError(
                        targetBody, trial, wantPe, wantInc, wantLan).
                    LOCAL trialScore IS _bplanePlanScore(trialErr, targetBody, wantInc).
                    IF trialScore < bestTrialScore {
                        SET accepted TO TRUE.
                        SET bestTrialScore TO trialScore.
                        IF trialScore < bestScore {
                            SET bestScore TO trialScore.
                            SET bestPe TO trial["pe"].
                            SET bestPlaneErr TO trialErr["planeErr"].
                            SET bestPro TO nd:PROGRADE.
                            SET bestRad TO nd:RADIALOUT.
                            SET bestNrm TO nd:NORMAL.
                        }
                        mLog("  BPLANE[" + i + "] accepted frac="
                            + ROUND(frac,3)
                            + " PeKm=" + ROUND(trial["pe"] / 1000,1)
                            + " planeErr=" + ROUND(trialErr["planeErr"],2)
                            + " scoreKm=" + ROUND(trialScore / 1000,1)
                            + " dv=" + ROUND(nd:DELTAV:MAG,2)).
                        BREAK.
                    }
                }
            }

            IF NOT accepted {
                SET nd:PROGRADE TO p0.
                SET nd:RADIALOUT TO r0.
                SET nd:NORMAL TO n0.
                WAIT 0.02.
                IF NOT _bplaneFallbackSearch(nd, targetBody,
                        wantPe, wantInc, wantLan, dvCap, score, i, FALSE) {
                    mLogWarn("BPLANE[" + i
                        + "]: no damped B-plane or fallback step improved Pe/plane score; stopping.").
                    BREAK.
                } ELSE {
                    LOCAL fbMeas IS measureArrival(nd, targetBody).
                    IF fbMeas <> 0 {
                        LOCAL fbErr IS _bplaneCorridorError(
                            targetBody, fbMeas, wantPe, wantInc, wantLan).
                        LOCAL fbScore IS _bplanePlanScore(
                            fbErr, targetBody, wantInc).
                        IF fbScore < bestScore {
                            SET bestScore TO fbScore.
                            SET bestPe TO fbMeas["pe"].
                            SET bestPlaneErr TO fbErr["planeErr"].
                            SET bestPro TO nd:PROGRADE.
                            SET bestRad TO nd:RADIALOUT.
                            SET bestNrm TO nd:NORMAL.
                        }
                        IF _bplaneCorridorOk(fbErr, wantInc, peTol, angTol) {
                            SET converged TO TRUE.
                            BREAK.
                        }
                    }
                }
            }
            }
        }
    }

    SET nd:PROGRADE TO bestPro.
    SET nd:RADIALOUT TO bestRad.
    SET nd:NORMAL TO bestNrm.
    WAIT 0.02.

    LOCAL measF IS measureArrival(nd, targetBody).
    LOCAL finalPe IS -1.
    LOCAL finalPlaneErr IS -1.
    LOCAL finalOffPlane IS -1.
    IF measF <> 0 {
        SET finalPe TO measF["pe"].
        LOCAL errF IS _bplaneCorridorError(
            targetBody, measF, wantPe, wantInc, wantLan).
        SET finalPlaneErr TO errF["planeErr"].
        SET finalOffPlane TO errF["target"]["offPlane"].
        IF _bplaneCorridorOk(errF, wantInc, peTol, angTol) {
            SET converged TO TRUE.
        }
    }

    IF measF <> 0 AND wantInc >= 0
            AND ABS(finalPe - wantPe) > entryPeErr
            AND finalPlaneErr > entryPlaneErr {
        mLogWarn("BPLANE: planned correction worsened both Pe and plane "
            + "relative to entry; removing node.").
        REMOVE nd.
        RETURN 0.
    }

    mLog("STATS bplane plan target=" + targetBody:NAME
        + " mode=" + planeMode
        + " converged=" + converged
        + " dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " PeKm=" + ROUND(finalPe / 1000, 1)
        + " planeErr=" + ROUND(finalPlaneErr, 2)
        + " offPlane=" + ROUND(finalOffPlane, 2)
        + " bestPeKm=" + ROUND(bestPe / 1000, 1)
        + " bestPlaneErr=" + ROUND(bestPlaneErr, 2)
        + " wantPeKm=" + ROUND(wantPe / 1000, 1)).

    IF NOT converged AND NOT acquired {
        _bplaneHoldCorrection("unconverged-optional-correction").
        RETURN 0.
    }

    LOCAL liveMeas IS measureArrival(0, targetBody).
    IF pristineLog = "" AND liveMeas <> 0
            AND _bplaneSafeEncounter(targetBody, liveMeas)
            AND nd:DELTAV:MAG < 0.2 {
        mLog("BPLANE: safe encounter; correction <0.2 m/s, handing off.").
        REMOVE nd.
        RETURN 0.
    }
    IF nd:DELTAV:MAG < MIN_EXEC_DV {
        IF pristineLog <> "" {
            mLog(pristineLog).
        } ELSE {
            mLog("BPLANE: correction below " + MIN_EXEC_DV + " m/s — skipping burn.").
        }
        REMOVE nd.
        RETURN 0.
    }
    IF NOT converged AND measF = 0 {
        mLogWarn("BPLANE: solver failed and encounter lost — removing node.").
        REMOVE nd.
        RETURN 0.
    }
    maneuverUiArchiveLog("bplane").
    RETURN nd.
}

LOCAL FUNCTION _bplaneTargetBody {
    LOCAL targetName IS "".
    IF BPLANE_TARGET <> "" { SET targetName TO BPLANE_TARGET. }
    IF targetName = "" { SET targetName TO getTarget(""). }

    LOCAL targetBody IS 0.
    LOCAL allBodies IS LIST().
    LIST BODIES IN allBodies.
    FOR bod IN allBodies {
        IF bod:NAME = targetName { SET targetBody TO bod. }
    }
    RETURN targetBody.
}

LOCAL FUNCTION _bplaneWantInc {
    IF BPLANE_PE_ONLY <> 0 { RETURN -1. }
    LOCAL wantInc IS -1.
    IF CAPTURE_DIR <> "" {
        LOCAL dir IS CAPTURE_DIR.
        IF dir = "PROGRADE"   { SET wantInc TO 0. }
        IF dir = "POLAR"      { SET wantInc TO 90. }
        IF dir = "RETROPOLAR" { SET wantInc TO 90. }
        IF dir = "RETROGRADE" { SET wantInc TO 180. }
    }
    IF CAPTURE_INC >= 0 { SET wantInc TO CAPTURE_INC. }
    RETURN wantInc.
}

LOCAL FUNCTION _bplaneExistingNodeAcceptable {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    PARAMETER phaseCap.

    IF NOT HASNODE { RETURN FALSE. }

    IF BPLANE_PE_ONLY <> 0 {
        // Replan a saved node under the new Pe-only recovery objective.
        RETURN FALSE.
    }

    LOCAL nd IS NEXTNODE.
    mLog("STATS bplane resume existing-node dv="
        + ROUND(nd:DELTAV:MAG, 2)
        + " eta=" + ROUND(nd:ETA, 1)
        + " body=" + SHIP:BODY:NAME).

    IF nd:ETA < BPLANE_EXISTING_NODE_MIN_ETA {
        mLogWarn("BPLANE: existing node is too close for automatic reuse (ETA="
            + ROUND(nd:ETA, 1) + "s; min="
            + ROUND(BPLANE_EXISTING_NODE_MIN_ETA, 1) + "s).").
        RETURN FALSE.
    }

    IF nd:DELTAV:MAG < MIN_EXEC_DV {
        mLogWarn("BPLANE: existing node dV is below execution threshold; replanning.").
        RETURN FALSE.
    }

    IF NOT _bplaneCorrectionAllowed(nd, targetBody, phaseCap) { RETURN FALSE. }

    bplaneResetWarnings().
    LOCAL meas IS measureArrival(nd, targetBody).
    IF meas = 0 {
        mLogWarn("BPLANE: existing node does not produce a measurable "
            + targetBody:NAME + " arrival; replanning.").
        RETURN FALSE.
    }

    LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
    mLog("STATS bplane existing-node target=" + targetBody:NAME
        + " dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " eta=" + ROUND(nd:ETA, 1)
        + " PeKm=" + ROUND(meas["pe"] / 1000, 1)
        + " planeErr=" + ROUND(err["planeErr"], 2)
        + " wantPeKm=" + ROUND(wantPe / 1000, 1)).

    IF _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
        mLog("BPLANE: reusing existing correction node; arrival is already "
            + "inside corridor.").
        RETURN TRUE.
    }

    mLogWarn("BPLANE: existing correction node misses requested corridor; replanning.").
    RETURN FALSE.
}

// ============================================================
// phaseBplane — phase handler. Resolves the arrival body and
// requested capture elements from globals/state, then runs up to
// MAX_BURNS correction burns. It holds the phase if the arrival
// is still outside the corridor; CAPTURE cannot fix a bad Pe/plane.
// ============================================================
GLOBAL FUNCTION phaseBplane {
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 {
        mLogWarn("BPLANE: target '" + getTarget("")
            + "' is not a body — nothing to do.").
        nextPhase(xferSeq).
        RETURN.
    }

    // Resume safety: a reboot can land us here after the SOI
    // transition already happened. Nothing left to correct.
    IF SHIP:BODY = targetBody {
        mLog("BPLANE: already inside " + targetBody:NAME + " SOI — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }
    IF NOT _bplaneCoastOutOfDepartureSoi(targetBody) { RETURN. }
    IF SHIP:BODY = targetBody {
        mLog("BPLANE: entered " + targetBody:NAME
            + " SOI during departure coast — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL wantPe IS CAPTURE_PE.
    IF wantPe < 0 {
        mLogWarn("BPLANE: CAPTURE_PE not set — skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }
    LOCAL wantInc IS _bplaneWantInc().

    LOCAL wantLan IS CAPTURE_LAN.
    IF BPLANE_PE_ONLY <> 0 { SET wantLan TO -1. }
    bplaneResetWarnings().
    _bplaneLogBaseline(targetBody, BPLANE_DV_CAP).

    LOCAL burns IS 0.
    UNTIL burns >= MAX_BURNS {
        IF _bplaneCurrentCorridorOk(targetBody, wantPe, wantInc, wantLan) {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            mLog("STATS bplane result status=already-in-corridor burns=" + burns).
            nextPhase(xferSeq).
            RETURN.
        }
        IF burns = 0 AND NOT HASNODE {
            LOCAL wakeMeas IS measureArrival(0, targetBody).
            IF wakeMeas <> 0 {
                LOCAL wakeErr IS _bplaneCorridorError(targetBody, wakeMeas, wantPe, wantInc, wantLan).
                mLog("STATS bplane wake initialPeKm="
                    + ROUND(wakeMeas["pe"] / 1000, 1)
                    + "km planeErr=" + ROUND(wakeErr["planeErr"], 2)
                    + "deg inc=" + ROUND(wakeMeas["inc"], 2)
                    + " lan=" + ROUND(wakeMeas["lan"], 2) + ".").
            } ELSE {
                mLog("BPLANE wake: no measurable arrival patch yet; planner will acquire if possible.").
            }
        }
        LOCAL nd IS 0.
        IF _bplaneExistingNodeAcceptable(targetBody, wantPe, wantInc, wantLan, BPLANE_DV_CAP) {
            SET nd TO NEXTNODE.
        } ELSE {
            IF phaseShouldYield { RETURN. }
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            SET nd TO planBplaneCorrection(targetBody, wantPe, wantInc, wantLan).
        }
        IF phaseShouldYield { RETURN. }
        IF nd = 0 { BREAK. }
        IF NOT _bplaneCorrectionAllowed(nd, targetBody, BPLANE_DV_CAP) { RETURN. }
        _bplaneReserveCorrection(nd, targetBody).
        _bplaneClearCoastTimes().
        SET burns TO burns + 1.
        IF NOT executeManeuver() {
            mLogWarn("BPLANE: burn execution failed — replanning once.").
        }
        WAIT 2.
    }

    IF BPLANE_PE_ONLY <> 0 {
        _bplaneFinishPeRecovery(targetBody, wantPe). RETURN.
    }
    LOCAL meas IS measureArrival(0, targetBody).
    IF meas = 0 {
        mLogError("BPLANE: finished with NO encounter — operator attention needed.").
        WAIT 30.
        RETURN.
    }
    LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
    IF NOT _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
        IF _bplaneSafeEncounter(targetBody, meas) {
            mLogWarn("BPLANE: arrival outside requested corridor but inside "
                + targetBody:NAME + " SOI; handing off to refinement/capture. "
                + "Pe=" + ROUND(meas["pe"] / 1000, 1)
                + "km planeErr=" + ROUND(err["planeErr"], 2) + "deg.").
            mLog("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
                + " inc=" + ROUND(meas["inc"], 2)
                + " lan=" + ROUND(meas["lan"], 2)
                + " planeErr=" + ROUND(err["planeErr"], 2)
                + " burns=" + burns
                + " status=safe-handoff").
            nextPhase(xferSeq).
            RETURN.
        }
        mLogError("BPLANE: failed to reach arrival corridor; holding phase. "
            + "Pe=" + ROUND(meas["pe"] / 1000, 1)
            + "km want=" + ROUND(wantPe / 1000, 1)
            + "km planeErr=" + ROUND(err["planeErr"], 2)
            + "deg. Replan XING or raise BPLANE_DV_CAP.").
        mLog("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
            + " inc=" + ROUND(meas["inc"], 2)
            + " lan=" + ROUND(meas["lan"], 2)
            + " planeErr=" + ROUND(err["planeErr"], 2)
            + " burns=" + burns
            + " status=failed-corridor").
        WAIT 30.
        RETURN.
    }
    mLog("BPLANE done: Pe=" + ROUND(meas["pe"] / 1000, 1)
        + "km inc=" + ROUND(meas["inc"], 2)
        + " lan=" + ROUND(meas["lan"], 2)
        + " after " + burns + " burn(s).").
    mLog("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
        + " inc=" + ROUND(meas["inc"], 2)
        + " lan=" + ROUND(meas["lan"], 2)
        + " burns=" + burns).
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseRefineBplane {
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 {
        mLogWarn("REFINE_BPLANE: target '" + getTarget("")
            + "' is not a body — nothing to do.").
        nextPhase(xferSeq).
        RETURN.
    }

    IF SHIP:BODY = targetBody {
        mLog("REFINE_BPLANE: already inside " + targetBody:NAME + " SOI; skipping.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL wantPe IS CAPTURE_PE.
    IF wantPe < 0 {
        mLogWarn("REFINE_BPLANE: CAPTURE_PE not set — skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }
    LOCAL wantInc IS _bplaneWantInc().
    LOCAL wantLan IS CAPTURE_LAN.
    IF BPLANE_PE_ONLY <> 0 { SET wantLan TO -1. }

    LOCAL dvCap IS MAX(MIN_EXEC_DV, REFINE_BPLANE_DV_CAP).
    _bplaneLogBaseline(targetBody, dvCap).
    LOCAL maxBurns IS MAX(1, REFINE_BPLANE_MAX_BURNS).
    LOCAL burns IS 0.
    UNTIL burns >= maxBurns {
        IF _bplaneCurrentCorridorOk(targetBody, wantPe, wantInc, wantLan) {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            mLog("STATS refine-bplane result status=already-in-corridor burns=" + burns).
            nextPhase(xferSeq).
            RETURN.
        }
        IF NOT HASNODE AND BPLANE_PE_ONLY = 0 {
            LOCAL measLoop IS measureArrival(0, targetBody).
            IF measLoop = 0 { BREAK. }
            LOCAL errLoop IS _bplaneCorridorError(targetBody, measLoop, wantPe, wantInc, wantLan).
            IF _bplaneCorridorOk(errLoop, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) { BREAK. }
        }

        LOCAL nd IS 0.
        IF _bplaneExistingNodeAcceptable(targetBody, wantPe, wantInc, wantLan, dvCap) {
            SET nd TO NEXTNODE.
        } ELSE {
            IF phaseShouldYield { RETURN. }
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            mLog("REFINE_BPLANE: refining arrival with dV cap "
                + dvCap + " m/s.").
            SET nd TO planBplaneCorrection(
                targetBody,
                wantPe,
                wantInc,
                wantLan,
                dvCap,
                "Trajectory pristine, skipping refinement burn.").
        }

        IF phaseShouldYield { RETURN. }
        IF nd = 0 { BREAK. }
        IF NOT _bplaneCorrectionAllowed(nd, targetBody, dvCap) { RETURN. }
        _bplaneReserveCorrection(nd, targetBody).
        _bplaneClearCoastTimes().
        SET burns TO burns + 1.
        IF NOT executeManeuver() {
            mLogWarn("REFINE_BPLANE: burn execution failed; holding before capture.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            WAIT 2.
            BREAK.
        }
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        WAIT 2.
    }

    IF BPLANE_PE_ONLY <> 0 {
        _bplaneFinishPeRecovery(targetBody, wantPe). RETURN.
    }
    LOCAL meas IS measureArrival(0, targetBody).
    IF meas <> 0 {
        LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
        IF NOT _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
            IF _bplaneSafeEncounter(targetBody, meas) {
                mLogWarn("REFINE_BPLANE: arrival outside requested corridor "
                    + "but inside " + targetBody:NAME
                    + " SOI; handing off. Pe="
                    + ROUND(meas["pe"] / 1000, 1)
                    + "km planeErr=" + ROUND(err["planeErr"], 2)
                    + "deg burns=" + burns + "/" + maxBurns + ".").
                mLog("STATS refine-bplane result PeKm="
                    + ROUND(meas["pe"] / 1000, 1)
                    + " inc=" + ROUND(meas["inc"], 2)
                    + " lan=" + ROUND(meas["lan"], 2)
                    + " planeErr=" + ROUND(err["planeErr"], 2)
                    + " burns=" + burns
                    + " status=safe-handoff").
                nextPhase(xferSeq).
                RETURN.
            }
            mLogError("REFINE_BPLANE: arrival still outside corridor; holding before capture. "
                + "Pe=" + ROUND(meas["pe"] / 1000, 1)
                + "km want=" + ROUND(wantPe / 1000, 1)
                + "km planeErr=" + ROUND(err["planeErr"], 2)
                + "deg burns=" + burns + "/" + maxBurns + ".").
            WAIT 30.
            RETURN.
        }
        mLog("REFINE_BPLANE done: Pe=" + ROUND(meas["pe"] / 1000, 1)
            + "km inc=" + ROUND(meas["inc"], 2)
            + " lan=" + ROUND(meas["lan"], 2)
            + " after " + burns + " burn(s).").
    } ELSE {
        mLogWarn("REFINE_BPLANE: no encounter measurement after refinement.").
        WAIT 30.
        RETURN.
    }
    nextPhase(xferSeq).
}
