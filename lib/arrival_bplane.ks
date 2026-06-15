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
// CFG keys:
//   CAPTURE_PE   — required: target periapsis altitude (m)
//   CAPTURE_INC  — optional: target inclination (deg)
//   CAPTURE_LAN  — optional: target LAN (deg)
//   BPLANE_TARGET  — optional body name (default: state "target")
//   BPLANE_DV_CAP  — max correction dV in m/s (default 50)
//   BPLANE_PE_TOL  — PE tolerance in m (default 2000)
//   BPLANE_ANG_TOL — plane tolerance in deg (default 0.5)
//   BPLANE_LEAD    — seconds from now to the burn (default 300)
// ============================================================

@LAZYGLOBAL OFF.

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

LOCAL FUNCTION _cfgNum {
    PARAMETER key, defaultValue.
    IF DEFINED CFG AND CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _cfgHas {
    PARAMETER key.
    RETURN DEFINED CFG AND CFG:HASKEY(key).
}

LOCAL FUNCTION _allowGravityAssist {
    IF _cfgHas("ALLOW_GRAVITY_ASSIST") {
        RETURN CFG["ALLOW_GRAVITY_ASSIST"] <> 0.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _arrivalTransitAllowed {
    PARAMETER fromBody.
    PARAMETER nextBody.
    PARAMETER targetBody.

    IF nextBody:NAME = targetBody:NAME { RETURN TRUE. }
    IF nextBody = fromBody:BODY AND targetBody:BODY <> fromBody { RETURN TRUE. }
    IF nextBody = targetBody:BODY AND targetBody:BODY <> fromBody { RETURN TRUE. }
    RETURN FALSE.
}

// ============================================================
// Patch discovery — walk the conic chain (after the given node
// if one is supplied, else from the ship's current orbit) and
// return LEX("patch", p, "entryUt", t) for the target body,
// or 0 when there is no direct encounter.
// NEXTPATCHETA is always relative to current universal time, so
// a patch's entry time is the PREVIOUS patch's transition ETA.
// ============================================================
LOCAL FUNCTION _findArrivalPatch {
    PARAMETER fromNode.
    PARAMETER targetBody.

    LOCAL p IS SHIP:ORBIT.
    IF fromNode <> 0 { SET p TO fromNode:ORBIT. }
    LOCAL allowAssist IS _allowGravityAssist().

    UNTIL NOT p:HASNEXTPATCH {
        LOCAL entryUt IS TIME:SECONDS + p:NEXTPATCHETA.
        LOCAL fromBody IS p:BODY.
        SET p TO p:NEXTPATCH.
        IF p:BODY = targetBody {
            RETURN LEX("patch", p, "entryUt", entryUt).
        }
        IF NOT allowAssist AND NOT _arrivalTransitAllowed(fromBody, p:BODY, targetBody) {
            RETURN 0.
        }
    }
    RETURN 0.
}

// ============================================================
// Arrival measurement — sample the hyperbolic patch shortly
// after SOI entry and derive everything the solver needs.
// Returns 0 on a missing encounter, else a LEX with:
//   S (asymptote), B (aim vector), bt/br (B-plane coords),
//   tHat/rHat (B-plane axes), hHat, vinf2, pe/inc/lan (elements)
// ============================================================
LOCAL FUNCTION _measureArrival {
    PARAMETER fromNode.
    PARAMETER targetBody.

    LOCAL hit IS _findArrivalPatch(fromNode, targetBody).
    IF hit = 0 { RETURN 0. }
    LOCAL p IS hit["patch"].
    LOCAL mu IS targetBody:MU.

    // Sample point safely inside the patch.
    LOCAL tEntry IS hit["entryUt"].
    LOCAL sampleDt IS 120.
    IF p:HASNEXTPATCH {
        LOCAL tEnd IS TIME:SECONDS + p:NEXTPATCHETA.
        SET sampleDt TO MIN(sampleDt, MAX(10, (tEnd - tEntry) * 0.25)).
    }
    LOCAL t IS tEntry + sampleDt.

    LOCAL rVec IS POSITIONAT(SHIP, t) - POSITIONAT(targetBody, t).
    // Frame-proof velocity: numeric derivative of relative position.
    LOCAL dt IS 1.
    LOCAL rPlus IS POSITIONAT(SHIP, t + dt) - POSITIONAT(targetBody, t + dt).
    LOCAL rMinus IS POSITIONAT(SHIP, t - dt) - POSITIONAT(targetBody, t - dt).
    LOCAL vVec IS (rPlus - rMinus) / (2 * dt).

    // (named rMag: bare "r" shadows kOS's R() constructor, and "t"
    // is already this scope's sample time)
    LOCAL rMag IS rVec:MAG.
    LOCAL v2 IS vVec:SQRMAGNITUDE.
    LOCAL rHatV IS rVec:NORMALIZED.

    // Orbit constants from the sample (vis-viva, handedness-free e).
    LOCAL sma IS 1 / (2 / rMag - v2 / mu).
    IF sma >= 0 {
        // Not hyperbolic at the sample — bail; element-based phases
        // can handle an (unusual) arriving ellipse.
        RETURN 0.
    }
    LOCAL vinf2 IS -mu / sma.
    LOCAL eVec IS ((v2 - mu / rMag) * rVec - VDOT(rVec, vVec) * vVec) / mu.
    LOCAL ecc IS eVec:MAG.
    LOCAL eHat IS eVec:NORMALIZED.
    LOCAL hHat IS VCRS(rHatV, vVec:NORMALIZED):NORMALIZED.

    // In-plane perpendicular to e, oriented toward increasing true
    // anomaly — derived from the sample itself (no handedness bet):
    // rHat = cos(TA) eHat + sin(TA) qHat, sign(sin TA) = sign(r·v).
    LOCAL cosTa IS MAX(-1, MIN(1, VDOT(rHatV, eHat))).
    LOCAL sinTa IS SQRT(MAX(1e-12, 1 - cosTa ^ 2)).
    IF VDOT(rVec, vVec) < 0 { SET sinTa TO -sinTa. }
    LOCAL qHat IS ((rHatV - cosTa * eHat) / sinTa):NORMALIZED.

    // Incoming asymptote: position direction at TA -> -nu_inf,
    // velocity points inward along it.
    LOCAL cosNuInf IS -1 / ecc.
    LOCAL sinNuInf IS SQRT(MAX(0, 1 - cosNuInf ^ 2)).
    LOCAL sHat IS (-(cosNuInf * eHat - sinNuInf * qHat)):NORMALIZED.

    // B vector: in-plane, perpendicular to S, on the periapsis side.
    LOCAL bHat IS VCRS(sHat, hHat):NORMALIZED.
    IF VDOT(bHat, eHat) < 0 { SET bHat TO -bHat. }
    LOCAL h IS SQRT(rVec:SQRMAGNITUDE * v2 - VDOT(rVec, vVec) ^ 2).
    LOCAL bMag IS h / SQRT(vinf2).

    // B-plane axes from the body's polar axis.
    LOCAL north_ IS targetBody:ANGULARVEL:NORMALIZED.
    LOCAL tHat IS VCRS(sHat, north_).
    IF tHat:MAG < 1e-6 { SET tHat TO VCRS(sHat, V(1, 0, 0)). }
    SET tHat TO tHat:NORMALIZED.
    LOCAL rAxisHat IS VCRS(sHat, tHat):NORMALIZED.

    RETURN LEX(
        "S", sHat, "hHat", hHat, "eHat", eHat,
        "bHat", bHat, "bMag", bMag,
        "bt", bMag * VDOT(bHat, tHat),
        "br", bMag * VDOT(bHat, rAxisHat),
        "tHat", tHat, "rHat", rAxisHat,
        "vinf2", vinf2,
        "pe", p:PERIAPSIS, "inc", p:INCLINATION, "lan", p:LAN).
}

// ============================================================
// Target plane normal around the arrival body, mirror-calibrated
// against the measured patch (whose elements AND normal vector
// we both know), so KSP element conventions are never assumed.
// ============================================================
LOCAL FUNCTION _arrivalPlaneNormal {
    PARAMETER targetBody, inc, lan, meas.
    LOCAL up_ IS targetBody:ANGULARVEL:NORMALIZED.

    LOCAL FUNCTION _candidate {
        PARAMETER i_, l_, sign_.
        LOCAL nodeVec IS (ANGLEAXIS(l_, up_) * SOLARPRIMEVECTOR):NORMALIZED.
        LOCAL w IS VCRS(up_, nodeVec):NORMALIZED.
        RETURN (COS(i_) * up_ + sign_ * SIN(i_) * w):NORMALIZED.
    }

    LOCAL sign IS 1.
    IF meas["inc"] > 0.3 AND meas["inc"] < 179.7 {
        IF VANG(_candidate(meas["inc"], meas["lan"], 1), meas["hHat"]) > 90 {
            SET sign TO -1.
        }
    }
    RETURN _candidate(inc, lan, sign).
}

// ============================================================
// _targetB — desired (B.T, B.R) for the requested capture
// elements, given the current arrival measurement.
// ============================================================
LOCAL FUNCTION _targetB {
    PARAMETER targetBody, meas, wantPe, wantInc, wantLan.

    LOCAL sHat IS meas["S"].
    LOCAL nTgt IS meas["hHat"].
    IF wantInc >= 0 {
        LOCAL lan IS meas["lan"].
        IF wantLan >= 0 { SET lan TO wantLan. }
        SET nTgt TO _arrivalPlaneNormal(targetBody, wantInc, lan, meas).
    }

    // The achievable plane must contain the asymptote. Project the
    // requested normal perpendicular to S and report the compromise.
    LOCAL offPlane IS ABS(90 - VANG(nTgt, sHat)).
    IF offPlane > 0.5 {
        SET nTgt TO (nTgt - VDOT(nTgt, sHat) * sHat):NORMALIZED.
        mLogWarn("BPLANE: requested plane tilted " + ROUND(offPlane, 1)
            + "deg off the arrival asymptote — using closest"
            + " achievable plane. Pick a different departure window"
            + " for an exact match.").
    }

    // Same-handed construction as the measurement: h = unit(S x B)
    // up to calibration, so B_t = unit(n_t x S) with the sign that
    // reproduces the measured geometry.
    LOCAL sH IS 1.
    IF VDOT(VCRS(sHat, meas["bHat"]), meas["hHat"]) < 0 { SET sH TO -1. }
    LOCAL bHatT IS (sH * VCRS(nTgt, sHat)):NORMALIZED.
    IF VDOT(VCRS(sHat, bHatT) * sH, nTgt) < 0 { SET bHatT TO -bHatT. }

    // |B| from requested periapsis: b = h/v∞, h = r_p * v_p.
    LOCAL mu IS targetBody:MU.
    LOCAL rp IS targetBody:RADIUS + wantPe.
    LOCAL vp IS SQRT(meas["vinf2"] + 2 * mu / rp).
    LOCAL bMagT IS rp * vp / SQRT(meas["vinf2"]).

    LOCAL bT IS bMagT * bHatT.
    RETURN LEX(
        "bt", VDOT(bT, meas["tHat"]),
        "br", VDOT(bT, meas["rHat"]),
        "normal", nTgt).
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
        IF _measureArrival(nd, targetBody) <> 0 {
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

        IF _measureArrival(nd, targetBody) <> 0 {
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
    RETURN _measureArrival(nd, targetBody) <> 0.
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

    LOCAL dvCap IS _cfgNum("BPLANE_DV_CAP", DEFAULT_DV_CAP).
    LOCAL peTol IS _cfgNum("BPLANE_PE_TOL", DEFAULT_PE_TOL).
    LOCAL angTol IS _cfgNum("BPLANE_ANG_TOL", DEFAULT_ANG_TOL).
    LOCAL lead IS _cfgNum("BPLANE_LEAD", DEFAULT_LEAD).

    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, 0).
    ADD nd.
    WAIT 0.02.

    LOCAL meas0 IS _measureArrival(nd, targetBody).
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
        SET meas0 TO _measureArrival(nd, targetBody).
        IF meas0 = 0 {
            mLogError("BPLANE: acquisition reported success but no "
                + targetBody:NAME + " patch is measurable.").
            REMOVE nd.
            RETURN 0.
        }
    }

    // Already in the corridor?
    LOCAL tgt0 IS _targetB(targetBody, meas0, wantPe, wantInc, wantLan).
    LOCAL planeErr0 IS VANG(meas0["hHat"], tgt0["normal"]).
    IF ABS(meas0["pe"] - wantPe) <= peTol
            AND (wantInc < 0 OR planeErr0 <= angTol) {
        mLog("BPLANE: arrival already in corridor (PeErr="
            + ROUND((meas0["pe"] - wantPe) / 1000, 1) + "km planeErr="
            + ROUND(planeErr0, 2) + "deg).").
        REMOVE nd.
        RETURN 0.
    }

    mLog("BPLANE: correcting arrival at " + targetBody:NAME
        + "  Pe " + ROUND(meas0["pe"] / 1000, 1) + "->"
        + ROUND(wantPe / 1000, 1) + "km  planeErr="
        + ROUND(planeErr0, 2) + "deg").

    LOCAL converged IS FALSE.
    FROM { LOCAL i IS 0. } UNTIL i >= MAX_NEWTON_ITER STEP { SET i TO i + 1. } DO {
        LOCAL meas IS _measureArrival(nd, targetBody).
        IF meas = 0 {
            mLogWarn("BPLANE[" + i + "]: lost the encounter — backing off.").
            SET nd:PROGRADE TO nd:PROGRADE * 0.5.
            SET nd:RADIALOUT TO nd:RADIALOUT * 0.5.
            SET nd:NORMAL TO nd:NORMAL * 0.5.
            WAIT 0.02.
        } ELSE {
            LOCAL tgt IS _targetB(targetBody, meas, wantPe, wantInc, wantLan).
            LOCAL errT IS tgt["bt"] - meas["bt"].
            LOCAL errR IS tgt["br"] - meas["br"].
            LOCAL planeErr IS VANG(meas["hHat"], tgt["normal"]).
            mLog("  BPLANE[" + i + "] dBT=" + ROUND(errT / 1000, 1)
                + "km dBR=" + ROUND(errR / 1000, 1)
                + "km Pe=" + ROUND(meas["pe"] / 1000, 1)
                + "km planeErr=" + ROUND(planeErr, 2)
                + " dv=" + ROUND(nd:DELTAV:MAG, 2)).

            IF ABS(meas["pe"] - wantPe) <= peTol
                    AND (wantInc < 0 OR planeErr <= angTol) {
                SET converged TO TRUE.
                BREAK.
            }

            // Finite-difference Jacobian: d(B.T,B.R)/d(radial,normal).
            LOCAL r0 IS nd:RADIALOUT.
            LOCAL n0 IS nd:NORMAL.

            SET nd:RADIALOUT TO r0 + FD_STEP. WAIT 0.02.
            LOCAL mRad IS _measureArrival(nd, targetBody).
            SET nd:RADIALOUT TO r0. WAIT 0.02.

            SET nd:NORMAL TO n0 + FD_STEP. WAIT 0.02.
            LOCAL mNrm IS _measureArrival(nd, targetBody).
            SET nd:NORMAL TO n0. WAIT 0.02.

            IF mRad = 0 OR mNrm = 0 {
                mLogWarn("BPLANE[" + i + "]: probe lost encounter — stopping.").
                BREAK.
            }

            LOCAL j11 IS (mRad["bt"] - meas["bt"]) / FD_STEP.
            LOCAL j21 IS (mRad["br"] - meas["br"]) / FD_STEP.
            LOCAL j12 IS (mNrm["bt"] - meas["bt"]) / FD_STEP.
            LOCAL j22 IS (mNrm["br"] - meas["br"]) / FD_STEP.
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
            SET nd:RADIALOUT TO r0 + dRad.
            SET nd:NORMAL TO n0 + dNrm.
            WAIT 0.02.

            IF nd:DELTAV:MAG > dvCap {
                mLogWarn("BPLANE[" + i + "]: dv cap " + dvCap
                    + " m/s exceeded (" + ROUND(nd:DELTAV:MAG, 1)
                    + ") — clamping.").
                LOCAL scale IS dvCap / nd:DELTAV:MAG.
                SET nd:PROGRADE TO nd:PROGRADE * scale.
                SET nd:RADIALOUT TO nd:RADIALOUT * scale.
                SET nd:NORMAL TO nd:NORMAL * scale.
                WAIT 0.02.
            }
        }
    }

    LOCAL measF IS _measureArrival(nd, targetBody).
    LOCAL finalPe IS -1.
    IF measF <> 0 { SET finalPe TO measF["pe"]. }
    mLogWarn("STATS bplane plan target=" + targetBody:NAME
        + " converged=" + converged
        + " dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " PeKm=" + ROUND(finalPe / 1000, 1)
        + " wantPeKm=" + ROUND(wantPe / 1000, 1)).

    IF nd:DELTAV:MAG < MIN_EXEC_DV {
        mLog("BPLANE: correction below " + MIN_EXEC_DV + " m/s — skipping burn.").
        REMOVE nd.
        RETURN 0.
    }
    IF NOT converged AND measF = 0 {
        mLogWarn("BPLANE: solver failed and encounter lost — removing node.").
        REMOVE nd.
        RETURN 0.
    }
    archivePlannedManeuverLog("bplane").
    RETURN nd.
}

// ============================================================
// phaseBplane — phase handler. Resolves the arrival body and
// requested capture elements from CFG/state, then runs up to
// MAX_BURNS correction burns. Advances even when unconverged
// (post-capture SHAPE is the safety net) but logs loudly.
// ============================================================
GLOBAL FUNCTION phaseBplane {
    LOCAL targetName IS "".
    IF _cfgHas("BPLANE_TARGET") { SET targetName TO CFG["BPLANE_TARGET"]. }
    IF targetName = "" { SET targetName TO stateGet("target", ""). }

    LOCAL targetBody IS 0.
    LOCAL allBodies IS LIST().
    LIST BODIES IN allBodies.
    FOR bod IN allBodies {
        IF bod:NAME = targetName { SET targetBody TO bod. }
    }
    IF targetBody = 0 {
        mLogWarn("BPLANE: target '" + targetName
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

    LOCAL wantPe IS _cfgNum("CAPTURE_PE", -1).
    IF wantPe < 0 {
        mLogWarn("BPLANE: CAPTURE_PE not set — skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }
    LOCAL wantInc IS -1.
    IF _cfgHas("CAPTURE_DIR") {
        LOCAL dir IS CFG["CAPTURE_DIR"].
        IF dir = "PROGRADE"   { SET wantInc TO 0. }
        IF dir = "POLAR"      { SET wantInc TO 90. }
        IF dir = "RETROPOLAR" { SET wantInc TO 90. }
        IF dir = "RETROGRADE" { SET wantInc TO 180. }
    }
    IF _cfgHas("CAPTURE_INC") { SET wantInc TO CFG["CAPTURE_INC"]. }

    LOCAL wantLan IS _cfgNum("CAPTURE_LAN", -1).

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

    LOCAL meas IS _measureArrival(0, targetBody).
    IF meas = 0 {
        mLogError("BPLANE: finished with NO encounter — operator attention needed.").
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
