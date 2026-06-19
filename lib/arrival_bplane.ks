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
//   BPLANE_DV_CAP  — max correction dV in m/s (default 50)
//   BPLANE_PE_TOL  — PE tolerance in m (default 2000)
//   BPLANE_ANG_TOL — plane tolerance in deg (default 0.5)
//   BPLANE_LEAD    — seconds from now to the burn (default 300)
//   BPLANE_OFFPLANE_TOL — max feasible plane/asymptote tilt (default 10)
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
GLOBAL BPLANE_DV_CAP IS 60.
GLOBAL BPLANE_PE_TOL IS 2000.
GLOBAL BPLANE_ANG_TOL IS 0.2.
GLOBAL BPLANE_LEAD IS 300.
GLOBAL BPLANE_TARGET IS "".
GLOBAL BPLANE_OFFPLANE_TOL IS 10.
GLOBAL REFINE_BPLANE_DV_CAP IS 10.
GLOBAL REFINE_BPLANE_MAX_BURNS IS 6.


LOCAL DEFAULT_DV_CAP   IS 50.
LOCAL DEFAULT_PE_TOL   IS 2000.
LOCAL DEFAULT_ANG_TOL  IS 0.5.
LOCAL DEFAULT_LEAD     IS 300.
LOCAL MIN_EXEC_DV      IS 0.1.
LOCAL MAX_NEWTON_ITER  IS 8.
LOCAL NEWTON_DAMP      IS 0.7.
LOCAL FD_STEP          IS 0.5.
LOCAL ACQUIRE_STEP     IS 0.5.
LOCAL MAX_ACQUIRE_ITER IS 50.
LOCAL MAX_BURNS        IS 2.

LOCAL FUNCTION _bplaneCorridorError {
    PARAMETER targetBody, meas, wantPe, wantInc, wantLan.

    LOCAL tgt IS targetBplaneVector(targetBody, meas, wantPe, wantInc, wantLan).
    LOCAL planeErr IS 0.
    IF wantInc >= 0 { SET planeErr TO VANG(meas["hHat"], tgt["normal"]). }
    RETURN LEX("peErr", meas["pe"] - wantPe,
        "planeErr", planeErr,
        "target", tgt).
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

    LOCAL score IS ABS(err["peErr"]).
    IF wantInc >= 0 AND _bplanePlaneFeasible(err) {
        SET score TO score + err["planeErr"] * targetBody:SOIRADIUS / 90.
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
    LOCAL steps IS LIST(10.0, 5.0, 2.0, 1.0, 0.5).

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

// ============================================================
// _acquireEncounter — if the raw flight plan is just outside the
// target SOI, hill-climb a tiny MCC node until KSP generates the
// target patch. Precision still belongs to the Newton B-plane
// solver below; this phase only reacquires the encounter.
// ============================================================
LOCAL FUNCTION _acquireEncounter {
    PARAMETER nd.
    PARAMETER targetBody.

    LOCAL searchStart IS nd:TIME.
    LOCAL searchEnd IS nd:TIME + targetBody:ORBIT:PERIOD.
    LOCAL bestCA IS _findClosestApproach(targetBody, searchStart, searchEnd, 60).
    LOCAL bestD IS bestCA["distance"].

    mLogWarn("BPLANE: encounter lost; acquiring nearest "
        + targetBody:NAME + " approach at T+"
        + ROUND(bestCA["time"] - TIME:SECONDS, 0)
        + "s CA=" + ROUND(bestD / 1000, 1) + "km.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= MAX_ACQUIRE_ITER STEP { SET iter TO iter + 1. } DO {
        IF measureArrival(nd, targetBody) <> 0 {
            mLog("BPLANE acquire: patch acquired in " + iter
                + " iter(s), dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " m/s.").
            RETURN TRUE.
        }

        LOCAL improved IS FALSE.

        LOCAL p0 IS nd:PROGRADE.
        SET nd:PROGRADE TO p0 + ACQUIRE_STEP. WAIT 0.02.
        LOCAL caPlus IS _findClosestApproach(targetBody, searchStart, searchEnd, 60).
        SET nd:PROGRADE TO p0 - ACQUIRE_STEP. WAIT 0.02.
        LOCAL caMinus IS _findClosestApproach(targetBody, searchStart, searchEnd, 60).
        IF caPlus["distance"] < bestD AND caPlus["distance"] <= caMinus["distance"] {
            SET nd:PROGRADE TO p0 + ACQUIRE_STEP.
            SET bestCA TO caPlus.
            SET bestD TO caPlus["distance"].
            SET improved TO TRUE.
        } ELSE IF caMinus["distance"] < bestD {
            SET nd:PROGRADE TO p0 - ACQUIRE_STEP.
            SET bestCA TO caMinus.
            SET bestD TO caMinus["distance"].
            SET improved TO TRUE.
        } ELSE {
            SET nd:PROGRADE TO p0.
        }
        WAIT 0.02.

        LOCAL r0 IS nd:RADIALOUT.
        SET nd:RADIALOUT TO r0 + ACQUIRE_STEP. WAIT 0.02.
        SET caPlus TO _findClosestApproach(targetBody, searchStart, searchEnd, 60).
        SET nd:RADIALOUT TO r0 - ACQUIRE_STEP. WAIT 0.02.
        SET caMinus TO _findClosestApproach(targetBody, searchStart, searchEnd, 60).
        IF caPlus["distance"] < bestD AND caPlus["distance"] <= caMinus["distance"] {
            SET nd:RADIALOUT TO r0 + ACQUIRE_STEP.
            SET bestCA TO caPlus.
            SET bestD TO caPlus["distance"].
            SET improved TO TRUE.
        } ELSE IF caMinus["distance"] < bestD {
            SET nd:RADIALOUT TO r0 - ACQUIRE_STEP.
            SET bestCA TO caMinus.
            SET bestD TO caMinus["distance"].
            SET improved TO TRUE.
        } ELSE {
            SET nd:RADIALOUT TO r0.
        }
        WAIT 0.02.

        LOCAL n0 IS nd:NORMAL.
        SET nd:NORMAL TO n0 + ACQUIRE_STEP. WAIT 0.02.
        SET caPlus TO _findClosestApproach(targetBody, searchStart, searchEnd, 60).
        SET nd:NORMAL TO n0 - ACQUIRE_STEP. WAIT 0.02.
        SET caMinus TO _findClosestApproach(targetBody, searchStart, searchEnd, 60).
        IF caPlus["distance"] < bestD AND caPlus["distance"] <= caMinus["distance"] {
            SET nd:NORMAL TO n0 + ACQUIRE_STEP.
            SET bestCA TO caPlus.
            SET bestD TO caPlus["distance"].
            SET improved TO TRUE.
        } ELSE IF caMinus["distance"] < bestD {
            SET nd:NORMAL TO n0 - ACQUIRE_STEP.
            SET bestCA TO caMinus.
            SET bestD TO caMinus["distance"].
            SET improved TO TRUE.
        } ELSE {
            SET nd:NORMAL TO n0.
        }
        WAIT 0.02.

        IF measureArrival(nd, targetBody) <> 0 {
            mLog("BPLANE acquire: patch acquired in " + (iter + 1)
                + " iter(s), dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " m/s.").
            RETURN TRUE.
        }

        IF NOT improved {
            mLogWarn("BPLANE acquire: no improving 0.5 m/s nudge found; "
                + "best CA=" + ROUND(bestD / 1000, 1) + "km.").
            RETURN FALSE.
        }
    }

    mLogWarn("BPLANE acquire: hit iteration cap; best CA="
        + ROUND(bestD / 1000, 1) + "km dv="
        + ROUND(nd:DELTAV:MAG, 2) + " m/s.").
    RETURN measureArrival(nd, targetBody) <> 0.
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

    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, 0).
    ADD nd.
    bplaneResetWarnings().
    WAIT 0.02.

    LOCAL meas0 IS measureArrival(nd, targetBody).
    IF meas0 = 0 {
        mLogWarn("BPLANE: no hyperbolic encounter with "
            + targetBody:NAME + " on the current correction node; "
            + "starting acquisition.").
        IF NOT _acquireEncounter(nd, targetBody) {
            mLogError("BPLANE: acquisition failed for "
                + targetBody:NAME + " — removing correction node.").
            REMOVE nd.
            RETURN 0.
        }
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
    LOCAL planeErr0 IS VANG(meas0["hHat"], tgt0["normal"]).
    LOCAL planeMode IS "target-plane".
    IF wantInc >= 0 AND NOT _bplanePlaneFeasible(err0) {
        SET planeMode TO "pe-only".
        mLogWarn("BPLANE: requested capture plane is "
            + ROUND(tgt0["offPlane"], 1)
            + "deg off the arrival asymptote; switching to Pe-only targeting.").
    }

    // Already in the corridor?
    IF _bplaneCorridorOk(err0, wantInc, peTol, angTol) {
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
            LOCAL planeErr IS VANG(meas["hHat"], tgt["normal"]).
            LOCAL corrErr IS _bplaneCorridorError(
                targetBody, meas, wantPe, wantInc, wantLan).
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
                mLogWarn("STATS bplane-bvec target=" + targetBody:NAME
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

    mLogWarn("STATS bplane plan target=" + targetBody:NAME
        + " mode=" + planeMode
        + " converged=" + converged
        + " dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " PeKm=" + ROUND(finalPe / 1000, 1)
        + " planeErr=" + ROUND(finalPlaneErr, 2)
        + " offPlane=" + ROUND(finalOffPlane, 2)
        + " bestPeKm=" + ROUND(bestPe / 1000, 1)
        + " bestPlaneErr=" + ROUND(bestPlaneErr, 2)
        + " wantPeKm=" + ROUND(wantPe / 1000, 1)).

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

    LOCAL wantPe IS CAPTURE_PE.
    IF wantPe < 0 {
        mLogWarn("BPLANE: CAPTURE_PE not set — skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }
    LOCAL wantInc IS _bplaneWantInc().

    LOCAL wantLan IS CAPTURE_LAN.
    LOCAL wakeMeas IS measureArrival(0, targetBody).
    IF wakeMeas <> 0 {
        LOCAL wakeErr IS _bplaneCorridorError(targetBody, wakeMeas, wantPe, wantInc, wantLan).
        mLog("BPLANE wake: initial arrival Pe="
            + ROUND(wakeMeas["pe"] / 1000, 1)
            + "km planeErr=" + ROUND(wakeErr["planeErr"], 2)
            + "deg inc=" + ROUND(wakeMeas["inc"], 2)
            + " lan=" + ROUND(wakeMeas["lan"], 2) + ".").
    } ELSE {
        mLog("BPLANE wake: no measurable arrival patch yet; planner will acquire if possible.").
    }

    LOCAL burns IS 0.
    UNTIL burns >= MAX_BURNS {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planBplaneCorrection(targetBody, wantPe, wantInc, wantLan).
        IF nd = 0 { BREAK. }
        SET burns TO burns + 1.
        IF NOT executeManeuver() {
            mLogWarn("BPLANE: burn execution failed — replanning once.").
        }
        WAIT 2.
    }

    LOCAL meas IS measureArrival(0, targetBody).
    IF meas = 0 {
        mLogError("BPLANE: finished with NO encounter — operator attention needed.").
        WAIT 30.
        RETURN.
    }
    LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
    IF NOT _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
        mLogError("BPLANE: failed to reach arrival corridor; holding phase. "
            + "Pe=" + ROUND(meas["pe"] / 1000, 1)
            + "km want=" + ROUND(wantPe / 1000, 1)
            + "km planeErr=" + ROUND(err["planeErr"], 2)
            + "deg. Replan XING or raise BPLANE_DV_CAP.").
        mLogWarn("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
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
    mLogWarn("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
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

    LOCAL dvCap IS MAX(MIN_EXEC_DV, REFINE_BPLANE_DV_CAP).
    LOCAL maxBurns IS MAX(1, REFINE_BPLANE_MAX_BURNS).
    LOCAL burns IS 0.
    UNTIL burns >= maxBurns {
        LOCAL measLoop IS measureArrival(0, targetBody).
        IF measLoop = 0 { BREAK. }
        LOCAL errLoop IS _bplaneCorridorError(targetBody, measLoop, wantPe, wantInc, wantLan).
        IF _bplaneCorridorOk(errLoop, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) { BREAK. }

        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        mLog("REFINE_BPLANE: refining arrival with dV cap "
            + dvCap + " m/s.").
        LOCAL nd IS planBplaneCorrection(
            targetBody,
            wantPe,
            wantInc,
            wantLan,
            dvCap,
            "Trajectory pristine, skipping refinement burn.").

        IF nd = 0 { BREAK. }
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

    LOCAL meas IS measureArrival(0, targetBody).
    IF meas <> 0 {
        LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
        IF NOT _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
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
