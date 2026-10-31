// ============================================================
// lib_bplane_math.ks — shared B-plane measurement/vector math
// (0:/lib/lib_bplane_math.ks)
//
// Pure patched-conic geometry helpers. This file intentionally
// contains no maneuver-node creation, execution, or solver logic.
// ============================================================

@LAZYGLOBAL OFF.

GLOBAL ALLOW_GRAVITY_ASSIST IS 0.
LOCAL _BPLANE_MEASURE_LOGGED IS FALSE.
LOCAL _BPLANE_BAD_MEASURE_LOGGED IS FALSE.
LOCAL _BPLANE_OFFPLANE_WARNED IS FALSE.

GLOBAL FUNCTION bplaneResetWarnings {
    SET _BPLANE_OFFPLANE_WARNED TO FALSE.
}

LOCAL FUNCTION _bplaneAllowGravityAssist {
    RETURN ALLOW_GRAVITY_ASSIST <> 0.
}

LOCAL FUNCTION _bplaneArrivalTransitAllowed {
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
GLOBAL FUNCTION findArrivalPatch {
    PARAMETER fromNode.
    PARAMETER targetBody.

    LOCAL p IS SHIP:ORBIT.
    IF fromNode <> 0 { SET p TO fromNode:ORBIT. }
    LOCAL allowAssist IS _bplaneAllowGravityAssist().

    UNTIL NOT p:HASNEXTPATCH {
        LOCAL entryUt IS TIME:SECONDS + p:NEXTPATCHETA.
        LOCAL fromBody IS p:BODY.
        SET p TO p:NEXTPATCH.
        IF p:BODY = targetBody {
            RETURN LEX("patch", p, "entryUt", entryUt).
        }
        IF NOT allowAssist AND NOT _bplaneArrivalTransitAllowed(fromBody, p:BODY, targetBody) {
            RETURN 0.
        }
    }
    RETURN 0.
}

// ============================================================
// Arrival measurement — read the selected hyperbolic conic's own
// state vectors. Never combine vessel/body future-position wrappers.
// Returns 0 on a missing encounter, else a LEX with:
//   S (asymptote), B (aim vector), bt/br (B-plane coords),
//   tHat/rHat (B-plane axes), hHat, vinf2, pe/inc/lan (elements)
// ============================================================
GLOBAL FUNCTION measureArrival {
    PARAMETER fromNode.
    PARAMETER targetBody.

    LOCAL hit IS findArrivalPatch(fromNode, targetBody).
    IF hit = 0 { RETURN 0. }
    LOCAL p IS hit["patch"].
    LOCAL mu IS targetBody:MU.

    // Orbit:POSITION extrapolates THIS patch at current UT about its
    // body's CURRENT center; Orbit:VELOCITY:ORBIT is relative to that
    // body. Vessel POSITIONAT walks nodes/patches and adds SOI offsets;
    // mixing it with Body POSITIONAT gave Sun-orbit velocities for Duna.
    // Extrapolation outside the patch interval preserves its invariants.
    LOCAL sampleUt IS TIME:SECONDS.
    LOCAL rVec IS p:POSITION - targetBody:POSITION.
    LOCAL vVec IS p:VELOCITY:ORBIT.
    LOCAL rMag IS rVec:MAG.
    LOCAL v2 IS vVec:SQRMAGNITUDE.
    LOCAL sma IS p:SEMIMAJORAXIS.
    LOCAL ecc IS p:ECCENTRICITY.
    IF NOT (rMag > 0 AND rMag < 1e30 AND v2 > 0 AND v2 < 1e30
            AND mu > 0 AND mu < 1e30 AND sma < 0 AND sma > -1e30
            AND ecc > 1 AND ecc < 1e15) { RETURN 0. }
    LOCAL vinf2 IS -mu / sma.
    LOCAL eVec IS ((v2 - mu / rMag) * rVec - VDOT(rVec, vVec) * vVec) / mu.
    LOCAL hVec IS VCRS(rVec,vVec).
    LOCAL h IS SQRT(mu*(-sma)*(ecc^2-1)).
    // Independently prove the RAW vectors belong to these native elements.
    // A frame error must fail measurement, not steer a plausible native Pe
    // with a physically unrelated B-vector. Bounds allow extrapolation's
    // floating-point loss; they do not relax Pe/plane execution admission.
    LOCAL energyError IS ABS(v2-mu*(2/rMag-1/sma))/MAX(1,vinf2).
    LOCAL hError IS ABS(hVec:MAG-h)/MAX(1,h).
    LOCAL eccError IS ABS(eVec:MAG-ecc)/MAX(1,ecc).
    IF NOT (h > 0 AND h < 1e30 AND hVec:MAG > 0 AND eVec:MAG > 0
            AND energyError <= 0.001 AND hError <= 0.001 AND eccError <= 0.001) {
        IF NOT _BPLANE_BAD_MEASURE_LOGGED {
            SET _BPLANE_BAD_MEASURE_LOGGED TO TRUE.
            mLogWarn("STATS bplane-measure rejected=patch-state-inconsistent target=" + targetBody:NAME
                + " energyError=" + energyError + " hError=" + hError + " eccError=" + eccError).
        }
        RETURN 0.
    }
    LOCAL eHat IS eVec:NORMALIZED.
    LOCAL hHat IS hVec:NORMALIZED.
    // Two cross products preserve the transverse direction in either
    // handedness, without subtracting nearly parallel asymptotic vectors.
    LOCAL qHat IS VCRS(hHat,eHat):NORMALIZED.

    // Incoming asymptote: position direction at TA -> -nu_inf,
    // velocity points inward along it.
    LOCAL cosNuInf IS -1 / ecc.
    LOCAL sinNuInf IS SQRT(MAX(0, 1 - cosNuInf ^ 2)).
    LOCAL sHat IS (-(cosNuInf * eHat - sinNuInf * qHat)):NORMALIZED.

    // B vector: in-plane, perpendicular to S, on the periapsis side.
    LOCAL bHat IS VCRS(sHat, hHat):NORMALIZED.
    IF VDOT(bHat, eHat) < 0 { SET bHat TO -bHat. }
    LOCAL bMag IS h / SQRT(vinf2).

    // B-plane axes from the body's polar axis.
    LOCAL north_ IS targetBody:ANGULARVEL:NORMALIZED.
    LOCAL tHat IS VCRS(sHat, north_).
    IF tHat:MAG < 1e-6 { SET tHat TO VCRS(sHat, V(1, 0, 0)). }
    SET tHat TO tHat:NORMALIZED.
    LOCAL rAxisHat IS VCRS(sHat, tHat):NORMALIZED.
    LOCAL bt IS bMag * VDOT(bHat, tHat).
    LOCAL br IS bMag * VDOT(bHat, rAxisHat).

    IF NOT _BPLANE_MEASURE_LOGGED {
        SET _BPLANE_MEASURE_LOGGED TO TRUE.
        mLog("STATS bplane-measure target=" + targetBody:NAME
            + " frame=patch-current sampleUt=" + sampleUt
            + " energyError=" + energyError + " hError=" + hError + " eccError=" + eccError
            + " rKm=" + ROUND(rMag / 1000, 1)
            + " v=" + ROUND(SQRT(v2), 3)
            + " h=" + ROUND(h, 1)
            + " hKm2s=" + ROUND(h / 1000000, 3)
            + " smaKm=" + ROUND(sma / 1000, 1)
            + " vinf2=" + ROUND(vinf2, 3)
            + " vinf=" + ROUND(SQRT(vinf2), 3)
            + " ecc=" + ROUND(ecc, 5)
            + " sDotH=" + ROUND(VDOT(sHat, hHat), 6)
            + " sDotB=" + ROUND(VDOT(sHat, bHat), 6)
            + " hDotB=" + ROUND(VDOT(hHat, bHat), 6)
            + " tDotR=" + ROUND(VDOT(tHat, rAxisHat), 6)
            + " sDotT=" + ROUND(VDOT(sHat, tHat), 6)
            + " sDotR=" + ROUND(VDOT(sHat, rAxisHat), 6)
            + " sMag=" + ROUND(sHat:MAG, 5)
            + " bHatMag=" + ROUND(bHat:MAG, 5)
            + " tHatMag=" + ROUND(tHat:MAG, 5)
            + " rHatMag=" + ROUND(rAxisHat:MAG, 5)
            + " dotBT=" + ROUND(VDOT(bHat, tHat), 6)
            + " dotBR=" + ROUND(VDOT(bHat, rAxisHat), 6)
            + " bMagKm=" + ROUND(bMag / 1000, 1)
            + " btKm=" + ROUND(bt / 1000, 1)
            + " brKm=" + ROUND(br / 1000, 1)
            + " peKm=" + ROUND(p:PERIAPSIS / 1000, 1)).
    }

    RETURN LEX(
        "S", sHat, "hHat", hHat, "eHat", eHat,
        "bHat", bHat, "bMag", bMag,
        "bt", bt,
        "br", br,
        "tHat", tHat, "rHat", rAxisHat,
        "dotBT", VDOT(bHat, tHat),
        "dotBR", VDOT(bHat, rAxisHat),
        "tHatMag", tHat:MAG,
        "rHatMag", rAxisHat:MAG,
        "bHatMag", bHat:MAG,
        "vinf2", vinf2,
        "pe", p:PERIAPSIS, "inc", p:INCLINATION, "lan", p:LAN).
}

// ============================================================
// Target plane normal around the arrival body, mirror-calibrated
// against the measured patch (whose elements AND normal vector
// we both know), so KSP element conventions are never assumed.
// ============================================================
GLOBAL FUNCTION arrivalPlaneNormal {
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
        // Both mirrors lie within 90 degrees on low-inclination
        // orbits. Choose the closer one, not a hemisphere test.
        IF VANG(_candidate(meas["inc"], meas["lan"], -1), meas["hHat"])
                < VANG(_candidate(meas["inc"], meas["lan"], 1), meas["hHat"]) {
            SET sign TO -1.
        }
    }
    RETURN _candidate(inc, lan, sign).
}

// With no requested LAN, choose either intersection of the inclination
// cone with the plane perpendicular to S. Keeping the current LAN can
// falsely make even a polar arrival look infeasible.
LOCAL FUNCTION _arrivalInclinationNormal {
    PARAMETER targetBody, meas, wantInc.
    LOCAL sHat IS meas["S"].
    LOCAL north_ IS targetBody:ANGULARVEL:NORMALIZED.
    // Calibrate the angular-momentum sign against the measured orbit.
    IF VDOT(meas["hHat"], north_) * COS(meas["inc"]) < -1e-8 {
        SET north_ TO -north_.
    }
    LOCAL northInPlane IS north_ - VDOT(north_, sHat) * sHat.
    LOCAL span IS northInPlane:MAG.
    LOCAL wantCos IS COS(wantInc).
    IF span >= 1e-8 AND ABS(wantCos) <= span {
        LOCAL alongNorth IS northInPlane / span.
        LOCAL acrossNorth IS VCRS(sHat, alongNorth):NORMALIZED.
        LOCAL coeff IS MAX(-1, MIN(1, wantCos / span)).
        LOCAL side IS SQRT(MAX(0, 1 - coeff ^ 2)).
        LOCAL candidateA IS coeff * alongNorth + side * acrossNorth.
        LOCAL candidateB IS coeff * alongNorth - side * acrossNorth.
        IF VDOT(candidateB, meas["hHat"]) > VDOT(candidateA, meas["hHat"]) {
            RETURN candidateB:NORMALIZED.
        }
        RETURN candidateA:NORMALIZED.
    }
    // Outside the feasible inclination band, choose the nearest boundary.
    // Return a normal on the REQUESTED cone whose projection reaches that
    // boundary, so offPlane still records the irreducible angular error.
    // A polar asymptote admits any transverse normal; keep the measured one.
    LOCAL closest IS meas["hHat"].
    IF span >= 1e-8 {
        SET closest TO northInPlane/span.
        IF wantCos < 0 { SET closest TO -closest. }
    }
    LOCAL closestInc IS ARCCOS(MAX(-1,MIN(1,VDOT(closest,north_)))).
    LOCAL gap IS ABS(closestInc-wantInc).
    LOCAL towardS IS 1.
    IF VDOT(north_,sHat)*wantCos < 0 { SET towardS TO -1. }
    RETURN (COS(gap)*closest+SIN(gap)*towardS*sHat):NORMALIZED.
}

// ============================================================
// targetBplaneVector — desired (B.T, B.R) for the requested
// capture elements, given the current arrival measurement.
// ============================================================
GLOBAL FUNCTION targetBplaneVector {
    PARAMETER targetBody, meas, wantPe, wantInc, wantLan.
    PARAMETER quiet IS FALSE.

    LOCAL sHat IS meas["S"].
    LOCAL nTgt IS meas["hHat"].
    IF wantInc >= 0 {
        IF wantLan >= 0 {
            SET nTgt TO arrivalPlaneNormal(targetBody, wantInc, wantLan, meas).
        } ELSE {
            SET nTgt TO _arrivalInclinationNormal(targetBody, meas, wantInc).
        }
    }

    // The achievable plane must contain the asymptote. Project the
    // requested normal perpendicular to S and report the compromise.
    LOCAL offPlane IS ABS(90 - VANG(nTgt, sHat)).
    IF offPlane > 1e-8 {
        LOCAL projected IS nTgt - VDOT(nTgt,sHat)*sHat.
        IF projected:MAG > 1e-8 { SET nTgt TO projected:NORMALIZED. }
        ELSE { SET nTgt TO meas["hHat"]. }
        IF offPlane > 0.5 AND NOT quiet AND NOT _BPLANE_OFFPLANE_WARNED {
            SET _BPLANE_OFFPLANE_WARNED TO TRUE.
            mLogWarn("BPLANE: requested plane tilted " + ROUND(offPlane, 1)
                + "deg off the arrival asymptote — using closest"
                + " achievable plane. Pick a different departure window"
                + " for an exact match.").
        }
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
    LOCAL measAng IS VANG(bHatT, meas["bHat"]).
    RETURN LEX(
        "bt", VDOT(bT, meas["tHat"]),
        "br", VDOT(bT, meas["rHat"]),
        "normal", nTgt,
        "offPlane", offPlane,
        "bMag", bMagT,
        "bHatMag", bHatT:MAG,
        "bHatAngle", measAng,
        "sDotBH", VDOT(sHat, bHatT),
        "hDotBH", VDOT(meas["hHat"], bHatT),
        "dotBT", VDOT(bHatT, meas["tHat"]),
        "dotBR", VDOT(bHatT, meas["rHat"])).
}
