// ============================================================
// lambert.ks  —  Lambert solver  (0:/lib/lambert.ks)
//
// Derived from the RSVP Lambert solver by maneatingape:
//   https://github.com/maneatingape/rsvp/blob/main/src/lambert.ks
// Licensed under GNU GPL 3.0 as a derivative work.
//
// The original RSVP code is itself a KerbalScript port of the
// ESA PyKep project's Lambert solver:
//   https://github.com/esa/pykep
//
// The algorithm is described in detail in the paper:
//   "Revisiting Lambert's problem" — Dario Izzo (ESA/ACT)
//   https://www.esa.int/gsp/ACT/doc/MAD/pub/ACT-RPR-MAD-2014-RevisitingLambertProblem.pdf
//
// Lambert's problem: given two position vectors (r1, r2) and a
// time of flight (tof), find the orbit that connects them.
// The solution gives departure and arrival velocity vectors (v1, v2)
// in the chosen central-body frame. For a parking-orbit departure,
// callers must convert v1 into a planet-relative v-infinity first,
// then build a local escape burn. Directly subtracting the ship's
// parking-orbit velocity mixes frames and greatly overstates dV.
//
// Simplifications vs. the full PyKep implementation:
//   - Multi-revolution transfer orbits are not considered
//   - Time of flight always uses Lancaster's formula
//
// The algorithm reduces the problem to finding a single variable
// "x" (the Lancaster-Blanchard variable) via Householder's method
// (a 3rd-order root-finding method — Newton's method is 1st order,
// Halley's method is 2nd order). The initial guess is so accurate
// that typically only 2-3 iterations are needed to converge.
//
// Hardening over the original port (2026-06 review):
//   - ARCCOS arguments clamped to [-1, 1] — numeric drift in the
//     conic geometry could previously hand ARCCOS a value like
//     1.0000000001 and poison the whole solve with NaN.
//   - chord/semiPerimeter clamped so lambda stays real for
//     degenerate (nearly straight-line) transfer triangles.
//   - Near-180° transfers: r1 x r2 vanishes, so the transfer
//     plane is ambiguous. We now fall back to a reference plane
//     instead of normalizing a zero vector.
//   - Householder denominator guarded against division by zero.
//   - orbitalStateVectors takes an explicit frame center instead
//     of silently using the ship's current body.
// ============================================================

@LAZYGLOBAL OFF.
@CLOBBERBUILTINS ON.

// Clamp helper for trig arguments that must stay in [-1, 1].
LOCAL FUNCTION _clamp1 {
    PARAMETER val.
    RETURN MAX(-1, MIN(1, val)).
}

// lambertSolve — solve Lambert's problem for a single-revolution transfer.
//
// Parameters:
//   r1   [Vector]  — position of origin body at departure time
//   r2   [Vector]  — position of target body at arrival time
//   tof  [Scalar]  — time of flight in seconds (arrival - departure)
//   mu   [Scalar]  — gravitational parameter of the central body (m^3/s^2)
//   flip [Boolean] — if TRUE, use the retrograde transfer arc instead of prograde
//
// Returns: LEX("v1", v1_vector, "v2", v2_vector)
//   v1 = required velocity at r1 for the transfer orbit
//   v2 = velocity at r2 upon arrival
//
// Usage example (Kerbin → Duna):
//   LOCAL r1 IS POSITIONAT(Kerbin, departTime) - Sun:POSITION.
//   LOCAL r2 IS POSITIONAT(Duna,   arriveTime) - Sun:POSITION.
//   LOCAL result IS lambertSolve(r1, r2, arriveTime - departTime, Sun:MU, FALSE).
//   LOCAL vInf IS result["v1"] - VELOCITYAT(Kerbin, departTime):ORBIT.
//   // Convert vInf to a local Kerbin escape node before executing.
GLOBAL FUNCTION lambertSolve {
    PARAMETER r1, r2, tof, mu, flip.

    // Compute the geometric parameters of the Lambert triangle.
    // m1, m2 = magnitudes of position vectors
    // c = chord length (straight-line distance between the two positions)
    // s = semi-perimeter of the triangle formed by r1, r2, and the chord
    LOCAL m1 IS r1:MAG.
    LOCAL m2 IS r2:MAG.
    LOCAL c IS (r1 - r2):MAG.
    LOCAL sp IS (m1 + m2 + c) / 2.

    // Lambda (λ) is a geometry parameter that encodes the transfer angle.
    // It ranges from -1 to 1; λ=0 means a 180° transfer.
    // See Izzo (2014), equation (1).
    // chord/semiPerimeter is mathematically <= 1 but can drift just past
    // it for degenerate triangles, which would make the SQRT throw.
    LOCAL l IS SQRT(MAX(0, 1 - c / sp)).

    // Normalize the time of flight into the dimensionless form used by
    // the algorithm. This "t" is not seconds — it's scaled by the
    // gravitational parameter and semi-perimeter so the root-finding
    // works in a well-conditioned parameter space.
    // See Izzo (2014), equation (2).
    LOCAL nt IS tof * SQRT(2 * mu / sp ^ 3).

    // Build the reference frame from the two position vectors.
    // ir1, ir2 = unit vectors along each position
    // ih = unit vector normal to the transfer plane (angular momentum direction)
    // it1, it2 = transverse unit vectors (perpendicular to r, in the orbital plane)
    LOCAL i1 IS r1:NORMALIZED.
    LOCAL i2 IS r2:NORMALIZED.
    LOCAL hr IS VCRS(i1, i2).

    // Near-180° transfer: r1 and r2 are (anti)parallel, the cross product
    // vanishes, and the transfer plane is genuinely ambiguous. Pick the
    // plane through r1 closest to the ecliptic (universe Y-up) rather
    // than normalizing a zero vector into NaN. Callers scanning transfer
    // windows will sail through the singular point instead of crashing.
    IF hr:MAG < 1e-6 {
        SET hr TO VCRS(i1, VCRS(V(0, 1, 0), i1)).
        IF hr:MAG < 1e-6 {
            // r1 is itself polar — any perpendicular plane works.
            SET hr TO VCRS(i1, V(1, 0, 0)).
        }
    }
    LOCAL h IS hr:NORMALIZED.
    LOCAL t1 IS VCRS(h, i1):NORMALIZED.
    LOCAL t2 IS VCRS(h, i2):NORMALIZED.

    // Determine prograde vs. retrograde transfer direction.
    // ih:Y < 0 means the angular momentum points "south" (retrograde in KSP's
    // coordinate system where Y is up). XOR with the flip parameter to allow
    // the caller to request the opposite arc.
    IF (h:Y < 0) <> flip {
        SET t1 TO -t1.
        SET t2 TO -t2.
        SET l TO -l.
    }

    // Solve for x, the Lancaster-Blanchard variable, using iterative root-finding.
    // x encodes the shape of the transfer orbit:
    //   x = 1  → minimum-energy (parabolic) transfer
    //   x > 1  → hyperbolic transfer
    //   x < 1  → elliptical transfer
    LOCAL x IS _lambertRootFind(l, nt).

    // Reconstruct velocity vectors from x.
    // y, rho, gamma are intermediate variables from Izzo (2014), section 3.
    // vr1/vr2 = radial velocity components at departure/arrival
    // vt = transverse velocity component (same formula at both ends)
    LOCAL l2 IS l ^ 2.
    LOCAL y IS SQRT(MAX(0, 1 - l2 * (1 - x ^ 2))).
    LOCAL ly IS l * y.
    LOCAL rh IS (m1 - m2) / c.
    LOCAL gm IS SQRT(mu * sp / 2).

    LOCAL u1 IS (ly - x) - rh * (x + ly).
    LOCAL u2 IS (x - ly) - rh * (x + ly).
    LOCAL vt IS SQRT(MAX(0, 1 - rh ^ 2)) * (y + l * x).

    // Combine radial and transverse components into 3D velocity vectors.
    // Each velocity = (gamma / distance) * (radial * r_hat + transverse * t_hat)
    LOCAL v1 IS (gm / m1) * (u1 * i1 + vt * t1).
    LOCAL v2 IS (gm / m2) * (u2 * i2 + vt * t2).

    RETURN LEX("v1", v1, "v2", v2).
}

// orbitalStateVectors — get position and velocity of any orbitable at a given time.
//
// Returns position relative to the given frame center (default: the ship's
// current body — the historical behavior) and orbital velocity.
// Pass the central body explicitly when computing Lambert inputs for a
// transfer that is not centered on the ship's current SOI — e.g. planning
// an interplanetary leg from low Kerbin orbit needs center=Sun.
//
// Parameters:
//   obt       [Orbitable] — any vessel, body, or target with an orbit
//   epochTime [Scalar]    — universal time (seconds) to evaluate at
//   center    [Body]      — frame center for the returned position
//
// Returns: LEX("position", pos_vector, "velocity", vel_vector)
GLOBAL FUNCTION orbitalStateVectors {
    PARAMETER obt_, epochTime.
    PARAMETER center IS BODY.
    LOCAL v IS VELOCITYAT(obt_, epochTime):ORBIT.
    LOCAL b IS obt_:BODY.

    UNTIL b = center OR NOT b:HASOBT {
        SET v TO v + VELOCITYAT(b, epochTime):ORBIT.
        SET b TO b:BODY.
    }

    RETURN LEX(
        "p", POSITIONAT(obt_, epochTime) - center:POSITION,
        "v", v
    ).
}

// _lambertRootFind — iterative root-finding for the Lancaster-Blanchard variable x.
//
// Uses Householder's method (3rd order) with a very good initial guess.
// Convergence tolerance: 1e-5 (dimensionless x units).
// Typically converges in 2-3 iterations; hard limit of 15.
LOCAL FUNCTION _lambertRootFind {
    PARAMETER l, nt.

    LOCAL x IS _lambertInitialGuess(l, nt).
    LOCAL d IS 1.
    LOCAL i IS 0.

    UNTIL ABS(d) < 0.00001 OR i = 15 {
        SET d TO _lambertHouseholder(l, nt, x).
        SET x TO x - d.
        SET i TO i + 1.
    }

    RETURN x.
}

// _lambertInitialGuess — compute a starting value for x.
//
// The guess is piecewise over three regimes based on the normalized TOF:
//   t >= t0 (long transfers):  power-law fit
//   t <= t1 (short transfers): rational approximation
//   t1 < t < t0 (middle):      log-interpolation between the two
//
// These formulas come from Izzo (2014), section 4. They are accurate enough
// that only 2-3 Householder iterations are needed afterward.
LOCAL FUNCTION _lambertInitialGuess {
    PARAMETER l, nt.

    // t0 = normalized TOF for the minimum-energy (parabolic) transfer
    // t1 = normalized TOF for the minimum-x boundary
    LOCAL l2 IS l ^ 2.
    LOCAL l3 IS l2 * l.
    LOCAL l5 IS l3 * l2.
    LOCAL t0 IS CONSTANT:DEGTORAD * ARCCOS(_clamp1(l))
        + l * SQRT(MAX(0, 1 - l2)).
    LOCAL t1 IS (2 / 3) * (1 - l3).

    IF nt >= t0 {
        // Long TOF regime: elliptical orbit, x < 1
        RETURN (t0 / nt) ^ (2 / 3) - 1.
    } ELSE IF nt <= t1 {
        // Short TOF regime: hyperbolic orbit, x > 1
        RETURN (5 * t1 * (t1 - nt))
            / (2 * nt * (1 - l5)) + 1.
    } ELSE {
        // Intermediate regime: log-interpolation
        RETURN (t0 / nt) ^ (LN(t1 / t0) / LN(2)) - 1.
    }
}

// _lambertHouseholder — one step of 3rd-order Householder's method.
//
// Householder's method generalizes Newton's method to use higher derivatives
// for faster convergence. The update formula is:
//   delta = f * (f'^2 - f*f''/2) / (f' * (f'^2 - f*f'') + f''*f^2/6)
//
// where f = tau - t (error in time of flight for current x),
// and f', f'', f''' are the 1st, 2nd, 3rd derivatives of the TOF w.r.t. x.
//
// See Izzo (2014), section 5 for the derivative formulas.
LOCAL FUNCTION _lambertHouseholder {
    PARAMETER l, nt, x.

    LOCAL l2 IS l ^ 2.
    LOCAL l3 IS l2 * l.
    LOCAL l5 IS l3 * l2.
    LOCAL x2 IS x ^ 2.
    LOCAL a IS 1 - x2.
    LOCAL y IS SQRT(MAX(0, 1 - l2 * a)).
    LOCAL y3 IS y ^ 3.
    LOCAL y5 IS y3 * y ^ 2.
    LOCAL ta IS _lambertTOF(l, a, x, y).
    LOCAL d IS ta - nt.

    // First derivative of TOF w.r.t. x
    LOCAL dt IS (3 * ta * x - 2 + 2 * l3 * x / y) / a.
    // Second derivative
    LOCAL ddt IS (3 * ta + 5 * x * dt
        + 2 * (1 - l2) * l3 / y3) / a.
    // Third derivative
    LOCAL dddt IS (7 * x * ddt + 8 * dt
        - 6 * (1 - l2) * l5 * x / y5) / a.

    // Householder update step (returns the correction to subtract from x).
    // Guard the denominator: at pathological points (e.g. x crossing 1.0
    // exactly) it can vanish; fall back to a plain Newton step.
    LOCAL d2 IS d ^ 2.
    LOCAL dt2 IS dt ^ 2.
    LOCAL de IS dt * (dt2 - d * ddt) + (dddt * d2) / 6.
    IF ABS(de) < 1e-12 {
        IF ABS(dt) < 1e-12 { RETURN 0. }
        RETURN d / dt.
    }
    RETURN d * (dt2 - d * ddt / 2) / de.
}

// _lambertTOF — compute the normalized time of flight using Lancaster's formula.
//
// This evaluates how long a transfer with the current x would take.
// The root-finder adjusts x until this matches the desired TOF.
//
// For elliptical orbits (a > 0): uses arccos (bounded, well-behaved)
// For hyperbolic orbits (a < 0): uses natural log
//
// See Izzo (2014), equation (9) for Lancaster's TOF formula.
LOCAL FUNCTION _lambertTOF {
    PARAMETER l, a, x, y.

    LOCAL b IS SQRT(ABS(a)).
    LOCAL f IS b * (y - l * x).
    LOCAL g IS l * a + x * y.

    // psi is the "universal anomaly" — arccos for elliptic, log for hyperbolic
    LOCAL psi IS 0.
    IF a > 0 {
        // Elliptical case — clamp against numeric drift past ±1
        SET psi TO CONSTANT:DEGTORAD * ARCCOS(_clamp1(g)).
    } ELSE {
        // Hyperbolic case — guard against negative argument from numeric noise
        SET psi TO LN(MAX(1e-300, f + g)).
    }

    RETURN (psi / b - x + l * y) / a.
}
