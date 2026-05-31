// ============================================================
// lambert.ks  —  Lambert solver  (0:/lib/lambert.ks)
//
// Port of RSVP Lambert solver (maneatingape/rsvp, GPL-3.0)
// Based on ESA PyKep / Dario Izzo "Revisiting Lambert's problem"
// ============================================================

GLOBAL FUNCTION lambertSolve {
    PARAMETER r1, r2, tof, mu, flip.

    LOCAL m1 IS r1:MAG.
    LOCAL m2 IS r2:MAG.
    LOCAL c IS (r1 - r2):MAG.
    LOCAL s IS (m1 + m2 + c) / 2.
    LOCAL lambda IS SQRT(1 - c / s).
    LOCAL t IS tof * SQRT(2 * mu / s ^ 3).

    LOCAL ir1 IS r1:NORMALIZED.
    LOCAL ir2 IS r2:NORMALIZED.
    LOCAL ih IS VCRS(ir1, ir2):NORMALIZED.
    LOCAL it1 IS VCRS(ih, ir1):NORMALIZED.
    LOCAL it2 IS VCRS(ih, ir2):NORMALIZED.

    IF (ih:Y < 0) <> flip {
        SET it1 TO -it1.
        SET it2 TO -it2.
        SET lambda TO -lambda.
    }

    LOCAL x IS _lambertRootFind(lambda, t).

    LOCAL y IS SQRT(1 - lambda ^ 2 * (1 - x ^ 2)).
    LOCAL z IS lambda * y.
    LOCAL rho IS (m1 - m2) / c.
    LOCAL gamma IS SQRT(mu * s / 2).

    LOCAL vr1 IS (z - x) - rho * (x + z).
    LOCAL vr2 IS (x - z) - rho * (x + z).
    LOCAL vt IS SQRT(1 - rho ^ 2) * (y + lambda * x).

    LOCAL v1 IS (gamma / m1) * (vr1 * ir1 + vt * it1).
    LOCAL v2 IS (gamma / m2) * (vr2 * ir2 + vt * it2).

    RETURN LEX("v1", v1, "v2", v2).
}

GLOBAL FUNCTION orbitalStateVectors {
    PARAMETER obt, epochTime.
    RETURN LEX(
        "position", POSITIONAT(obt, epochTime) - BODY:POSITION,
        "velocity", VELOCITYAT(obt, epochTime):ORBIT
    ).
}

LOCAL FUNCTION _lambertRootFind {
    PARAMETER lambda, t.

    LOCAL x IS _lambertInitialGuess(lambda, t).
    LOCAL delta IS 1.
    LOCAL iter IS 0.

    UNTIL ABS(delta) < 0.00001 OR iter = 15 {
        SET delta TO _lambertHouseholder(lambda, t, x).
        SET x TO x - delta.
        SET iter TO iter + 1.
    }

    RETURN x.
}

LOCAL FUNCTION _lambertInitialGuess {
    PARAMETER lambda, t.

    LOCAL t0 IS CONSTANT:DEGTORAD * ARCCOS(lambda)
        + lambda * SQRT(1 - lambda ^ 2).
    LOCAL t1 IS (2 / 3) * (1 - lambda ^ 3).

    IF t >= t0 {
        RETURN (t0 / t) ^ (2 / 3) - 1.
    } ELSE IF t <= t1 {
        RETURN (5 * t1 * (t1 - t)) / (2 * t * (1 - lambda ^ 5)) + 1.
    } ELSE {
        RETURN (t0 / t) ^ (LN(t1 / t0) / LN(2)) - 1.
    }
}

LOCAL FUNCTION _lambertHouseholder {
    PARAMETER lambda, t, x.

    LOCAL a IS 1 - x ^ 2.
    LOCAL y IS SQRT(1 - lambda ^ 2 * a).
    LOCAL tau IS _lambertTOF(lambda, a, x, y).
    LOCAL delta IS tau - t.

    LOCAL dt IS (3 * tau * x - 2 + 2 * (lambda ^ 3) * x / y) / a.
    LOCAL ddt IS (3 * tau + 5 * x * dt
        + 2 * (1 - lambda ^ 2) * (lambda ^ 3) * x / (y ^ 3)) / a.
    LOCAL dddt IS (7 * x * ddt + 8 * dt
        - 6 * (1 - lambda ^ 2) * (lambda ^ 5) * x / (y ^ 5)) / a.

    RETURN delta * (dt ^ 2 - delta * ddt / 2)
        / (dt * (dt ^ 2 - delta * ddt) + (dddt * delta ^ 2) / 6).
}

LOCAL FUNCTION _lambertTOF {
    PARAMETER lambda, a, x, y.

    LOCAL b IS SQRT(ABS(a)).
    LOCAL f IS b * (y - lambda * x).
    LOCAL g IS lambda * a + x * y.

    LOCAL psi IS 0.
    IF a > 0 {
        SET psi TO CONSTANT:DEGTORAD * ARCCOS(g).
    } ELSE {
        SET psi TO LN(MAX(1e-300, f + g)).
    }

    RETURN (psi / b - x + lambda * y) / a.
}
