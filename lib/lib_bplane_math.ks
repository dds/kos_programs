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
// Arrival measurement — sample the hyperbolic patch shortly
// after SOI entry and derive everything the solver needs.
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
        // Not hyperbolic at the sample — element-based phases can
        // handle an (unusual) arriving ellipse.
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
    LOCAL bt IS bMag * VDOT(bHat, tHat).
    LOCAL br IS bMag * VDOT(bHat, rAxisHat).

    IF NOT _BPLANE_MEASURE_LOGGED {
        SET _BPLANE_MEASURE_LOGGED TO TRUE.
        mLog("STATS bplane-measure target=" + targetBody:NAME
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
        IF VANG(_candidate(meas["inc"], meas["lan"], 1), meas["hHat"]) > 90 {
            SET sign TO -1.
        }
    }
    RETURN _candidate(inc, lan, sign).
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
        LOCAL lan IS meas["lan"].
        IF wantLan >= 0 { SET lan TO wantLan. }
        SET nTgt TO arrivalPlaneNormal(targetBody, wantInc, lan, meas).
    }

    // The achievable plane must contain the asymptote. Project the
    // requested normal perpendicular to S and report the compromise.
    LOCAL offPlane IS ABS(90 - VANG(nTgt, sHat)).
    IF offPlane > 0.5 {
        SET nTgt TO (nTgt - VDOT(nTgt, sHat) * sHat):NORMALIZED.
        IF NOT quiet AND NOT _BPLANE_OFFPLANE_WARNED {
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
