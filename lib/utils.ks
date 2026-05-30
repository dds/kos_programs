// ============================================================
// utils.ks  —  General-purpose utilities  (0:/lib/utils.ks)
// ============================================================

GLOBAL FUNCTION fmtDuration {
    PARAMETER secs.
    LOCAL h IS FLOOR(secs / 3600).
    LOCAL m IS FLOOR(MOD(secs, 3600) / 60).
    LOCAL s IS ROUND(MOD(secs, 60), 0).
    RETURN h + "h " + m + "m " + s + "s".
}

GLOBAL FUNCTION printOrbitRef {
    PARAMETER revs.
    PARAMETER currentPeR.
    PARAMETER bodyMu.
    PARAMETER bR.
    LOCAL dayLen IS SHIP:ORBIT:BODY:ROTATIONPERIOD.
    LOCAL period IS dayLen / revs.
    LOCAL sma IS (bodyMu * (period / (2 * CONSTANT:PI))^2)^(1/3).
    LOCAL apR IS 2 * sma - currentPeR.
    LOCAL apAlt IS apR - bR.
    LOCAL ecc IS 1 - currentPeR / sma.
    IF apAlt > 0 AND ecc < 1 AND ecc > 0 {
        PRINT "  " + revs + " rev/day: T=" + ROUND(period,0) + "s  Ap=" + ROUND(apAlt/1000,0) + "km  ecc=" + ROUND(ecc,3).
    }
}
