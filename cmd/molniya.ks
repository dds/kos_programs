// ============================================================
// molniya.ks  —  Molniya orbit calculator  (0:/cmd/molniya.ks)
//
// Usage from kOS terminal:
//   RUNPATH("1:/cmd/molniya.ks").              // current body, current Pe
//   RUNPATH("1:/cmd/molniya.ks", 21600).       // specific period (s)
//   RUNPATH("1:/cmd/molniya.ks", 0, 2863334).  // specific Pe, Ap (m)
// ============================================================

PARAMETER inputPeriod IS 0.
PARAMETER inputAp IS 0.

LOCAL FUNCTION _fmtTime {
    PARAMETER secs.
    LOCAL h IS FLOOR(secs / 3600).
    LOCAL m IS FLOOR(MOD(secs, 3600) / 60).
    LOCAL s IS ROUND(MOD(secs, 60), 0).
    RETURN h + "h " + m + "m " + s + "s".
}

LOCAL FUNCTION _printRef {
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

LOCAL mu IS SHIP:ORBIT:BODY:MU.
LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
LOCAL bodyName IS SHIP:ORBIT:BODY:NAME.
LOCAL peAlt IS SHIP:PERIAPSIS.
LOCAL peR IS bodyR + peAlt.

PRINT " ".
PRINT "  ========================================".
PRINT "    MOLNIYA ORBIT CALCULATOR".
PRINT "    Body: " + bodyName.
PRINT "  ========================================".
PRINT " ".

IF inputPeriod > 0 AND inputAp = 0 {
    LOCAL sma IS (mu * (inputPeriod / (2 * CONSTANT:PI))^2)^(1/3).
    LOCAL apR IS 2 * sma - peR.
    LOCAL apAlt IS apR - bodyR.
    LOCAL ecc IS 1 - peR / sma.
    PRINT "  FROM PERIOD:".
    PRINT "  Period ..... " + ROUND(inputPeriod,0) + "s  (" + _fmtTime(inputPeriod) + ")".
    PRINT "  Pe ......... " + ROUND(peAlt/1000,1) + " km  (current)".
    PRINT "  Ap ......... " + ROUND(apAlt/1000,1) + " km".
    PRINT "  SMA ........ " + ROUND(sma/1000,1) + " km".
    PRINT "  Ecc ........ " + ROUND(ecc,4).
} ELSE IF inputAp > 0 {
    LOCAL apAlt IS inputAp.
    IF inputPeriod > 0 { SET peAlt TO inputPeriod. SET peR TO bodyR + peAlt. }
    LOCAL apR IS bodyR + apAlt.
    LOCAL sma IS (peR + apR) / 2.
    LOCAL period IS 2 * CONSTANT:PI * SQRT(sma^3 / mu).
    LOCAL ecc IS 1 - peR / sma.
    PRINT "  FROM ALTITUDES:".
    PRINT "  Pe ......... " + ROUND(peAlt/1000,1) + " km".
    PRINT "  Ap ......... " + ROUND(apAlt/1000,1) + " km".
    PRINT "  Period ..... " + ROUND(period,0) + "s  (" + _fmtTime(period) + ")".
    PRINT "  SMA ........ " + ROUND(sma/1000,1) + " km".
    PRINT "  Ecc ........ " + ROUND(ecc,4).
    PRINT " ".
    PRINT "  CFG value:   SET CFG[" + CHAR(34) + "MOLNIYA_PERIOD" + CHAR(34) + "] TO " + ROUND(period,0) + ".".
} ELSE {
    PRINT "  CURRENT ORBIT:".
    PRINT "  Pe ......... " + ROUND(peAlt/1000,1) + " km".
    PRINT "  Ap ......... " + ROUND(SHIP:APOAPSIS/1000,1) + " km".
    PRINT "  Period ..... " + ROUND(SHIP:ORBIT:PERIOD,0) + "s  (" + _fmtTime(SHIP:ORBIT:PERIOD) + ")".
    PRINT "  SMA ........ " + ROUND(SHIP:ORBIT:SEMIMAJORAXIS/1000,1) + " km".
    PRINT "  Ecc ........ " + ROUND(SHIP:ORBIT:ECCENTRICITY,4).
    PRINT "  Inc ........ " + ROUND(SHIP:ORBIT:INCLINATION,2) + " deg".
    PRINT "  AoP ........ " + ROUND(SHIP:ORBIT:ARGUMENTOFPERIAPSIS,1) + " deg".
    PRINT " ".
    PRINT "  REFERENCE ORBITS (" + bodyName + "):".
    _printRef(2, peR, mu, bodyR).
    _printRef(3, peR, mu, bodyR).
    _printRef(4, peR, mu, bodyR).
    _printRef(6, peR, mu, bodyR).
    _printRef(8, peR, mu, bodyR).
    _printRef(12, peR, mu, bodyR).
}

PRINT " ".
PRINT "  ========================================".
