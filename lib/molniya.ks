// ============================================================
// molniya.ks  —  Molniya orbit planning library  (0:/lib/molniya.ks)
//
// molniyaParams()         — compute orbital elements from config
// printMolniyaSummary()   — config screen summary block
// planMolniyaInsert()     — plan 2-burn insertion maneuver
// phaseMolniyaInsert()    — phase machine entry point
// ============================================================

GLOBAL FUNCTION molniyaParams {
    PARAMETER targetPeriod.
    PARAMETER targetEcc.
    PARAMETER fallbackPeAlt IS -1.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL sma IS 0.
    LOCAL peR IS 0.
    LOCAL apR IS 0.
    LOCAL ecc IS 0.
    LOCAL period IS 0.
    LOCAL mode IS "period".

    IF targetEcc > 0 AND targetPeriod > 0 {
        SET sma TO (mu * (targetPeriod / (2 * CONSTANT:PI))^2)^(1/3).
        SET peR TO sma * (1 - targetEcc).
        SET apR TO 2 * sma - peR.
        SET ecc TO targetEcc.
        SET period TO targetPeriod.
        SET mode TO "period+ecc".
    } ELSE IF targetEcc > 0 {
        LOCAL peAlt IS fallbackPeAlt.
        IF peAlt < 0 { SET peAlt TO SHIP:PERIAPSIS. }
        SET peR TO bodyR + peAlt.
        SET sma TO peR / (1 - targetEcc).
        SET apR TO 2 * sma - peR.
        SET ecc TO targetEcc.
        SET period TO 2 * CONSTANT:PI * SQRT(sma^3 / mu).
        SET mode TO "ecc".
    } ELSE {
        LOCAL peAlt IS fallbackPeAlt.
        IF peAlt < 0 { SET peAlt TO SHIP:PERIAPSIS. }
        SET peR TO bodyR + peAlt.
        SET sma TO (mu * (targetPeriod / (2 * CONSTANT:PI))^2)^(1/3).
        SET apR TO 2 * sma - peR.
        SET ecc TO (apR - peR) / (apR + peR).
        SET period TO targetPeriod.
    }

    RETURN LEXICON(
        "SMA", sma, "PeR", peR, "ApR", apR,
        "ecc", ecc, "period", period, "mode", mode,
        "peAlt", peR - bodyR, "apAlt", apR - bodyR
    ).
}

GLOBAL FUNCTION printMolniyaSummary {
    LOCAL ecc IS -1.
    IF CFG:HASKEY("MOLNIYA_ECC") AND CFG["MOLNIYA_ECC"] > 0 {
        SET ecc TO CFG["MOLNIYA_ECC"].
    }
    LOCAL mp IS molniyaParams(CFG["MOLNIYA_PERIOD"], ecc, CFG["PARKING_ALT"]).
    LOCAL p IS mp["period"].
    LOCAL h IS FLOOR(p / 3600).
    LOCAL m IS FLOOR(MOD(p, 3600) / 60).
    LOCAL s IS ROUND(MOD(p, 60), 0).
    LOCAL dwell IS "North".
    IF CFG["MOLNIYA_AOP"] <= 180 { SET dwell TO "South". }
    PRINT " ".
    PRINT "  -- MOLNIYA (" + mp["mode"] + ") --".
    PRINT "  PERIOD .... " + h + "h" + ("" + m):PADLEFT(2) + "m" + ("" + s):PADLEFT(2) + "s".
    PRINT "  AoP ....... " + CFG["MOLNIYA_AOP"] + " deg  (" + dwell + " dwell)".
    PRINT "  TARGET Pe . " + ROUND(mp["peAlt"]/1000,0) + " km".
    PRINT "  TARGET Ap . " + ROUND(mp["apAlt"]/1000,0) + " km".
    PRINT "  TARGET ecc  " + ROUND(mp["ecc"],4).
}

GLOBAL FUNCTION planMolniyaInsert {
    PARAMETER targetPeriod.
    PARAMETER targetAoP.
    PARAMETER targetEcc IS -1.

    LOCAL mp IS molniyaParams(targetPeriod, targetEcc).
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL targetSMA IS mp["SMA"].
    LOCAL targetPeR IS mp["PeR"].
    LOCAL targetApR IS mp["ApR"].

    mLog("Molniya target: pe=" + ROUND(mp["peAlt"]/1000,0) + "km  ap=" + ROUND(mp["apAlt"]/1000,0)
        + "km  ecc=" + ROUND(mp["ecc"],4) + "  period=" + ROUND(mp["period"],0) + "s").

    LOCAL burnTA IS targetAoP - SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    UNTIL burnTA >= 0  { SET burnTA TO burnTA + 360. }
    UNTIL burnTA < 360 { SET burnTA TO burnTA - 360. }

    LOCAL burnETA IS etaToTrueAnomaly(burnTA).
    LOCAL burnUT IS TIME:SECONDS + burnETA.
    LOCAL burnR IS POSITIONAT(SHIP, burnUT):MAG.

    mLog("burnR=" + ROUND(burnR/1000,1) + "km  targetPeR=" + ROUND(targetPeR/1000,1) + "km  ETA=" + ROUND(burnETA,0) + "s").

    LOCAL SMA_int IS (burnR + targetApR) / 2.
    LOCAL vNew1 IS SQRT(mu * (2/burnR - 1/SMA_int)).
    LOCAL vNow1 IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL dv1 IS vNew1 - vNow1.
    LOCAL nd1 IS NODE(burnUT, 0, 0, dv1).
    ADD nd1.

    LOCAL period_int IS 2 * CONSTANT:PI * SQRT(SMA_int^3 / mu).
    LOCAL burnUT2 IS burnUT + period_int / 2.
    LOCAL vNow2 IS SQRT(mu * (2/targetApR - 1/SMA_int)).
    LOCAL vNew2 IS SQRT(mu * (2/targetApR - 1/targetSMA)).
    LOCAL dv2 IS vNew2 - vNow2.
    LOCAL nd2 IS NODE(burnUT2, 0, 0, dv2).
    ADD nd2.

    mLog("Molniya 2-burn: dV1=" + ROUND(dv1,1) + "m/s  dV2=" + ROUND(dv2,1)
        + "m/s  coast=" + ROUND(period_int/2,0) + "s").
    RETURN LIST(nd1, nd2).
}

GLOBAL FUNCTION phaseMolniyaInsert {
    LOCAL targetPeriod IS CFG["MOLNIYA_PERIOD"].
    LOCAL targetAoP IS CFG["MOLNIYA_AOP"].
    LOCAL targetEcc IS -1.
    IF CFG:HASKEY("MOLNIYA_ECC") AND CFG["MOLNIYA_ECC"] > 0 {
        SET targetEcc TO CFG["MOLNIYA_ECC"].
        mLog("Molniya mode: period=" + targetPeriod + "s  ecc=" + targetEcc).
    }
    orbitSummary().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planMolniyaInsert(targetPeriod, targetAoP, targetEcc).
        LOCAL allOk IS TRUE.
        UNTIL NOT HASNODE OR NOT allOk {
            IF NOT executeManeuver() { SET allOk TO FALSE. }
        }
        SET success TO allOk.
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Molniya burn missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= 5 {
                mLogError("Molniya insert failed after " + retries + " attempts.").
                RETURN.
            }
            WAIT 10.
        }
    }
    mLog("Molniya result: ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4)
        + "  AoP=" + ROUND(SHIP:ORBIT:ARGUMENTOFPERIAPSIS,1)
        + "  period=" + ROUND(SHIP:ORBIT:PERIOD,0)
        + "s  inc=" + ROUND(SHIP:ORBIT:INCLINATION,2) + "deg").
    orbitSummary().
    nextPhase(xferSeq).
}
