GLOBAL FUNCTION planMolniyaInsert {
    PARAMETER targetPeriod.
    PARAMETER targetAoP.
    PARAMETER targetEcc IS -1.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.

    LOCAL targetSMA IS 0.
    LOCAL targetPeR IS 0.
    LOCAL targetApR IS 0.

    IF targetEcc > 0 AND targetPeriod > 0 {
        SET targetSMA TO (mu * (targetPeriod / (2 * CONSTANT:PI))^2)^(1/3).
        SET targetPeR TO targetSMA * (1 - targetEcc).
        SET targetApR TO 2 * targetSMA - targetPeR.
    } ELSE IF targetEcc > 0 {
        SET targetPeR TO bodyR + SHIP:PERIAPSIS.
        SET targetSMA TO targetPeR / (1 - targetEcc).
        SET targetApR TO 2 * targetSMA - targetPeR.
    } ELSE {
        SET targetPeR TO bodyR + SHIP:PERIAPSIS.
        SET targetSMA TO (mu * (targetPeriod / (2 * CONSTANT:PI))^2)^(1/3).
        SET targetApR TO 2 * targetSMA - targetPeR.
    }

    LOCAL ecc IS (targetApR - targetPeR) / (targetApR + targetPeR).
    LOCAL effectivePeriod IS 2 * CONSTANT:PI * SQRT(targetSMA^3 / mu).

    mLog("Molniya target: pe=" + ROUND((targetPeR-bodyR)/1000,0) + "km  ap=" + ROUND((targetApR-bodyR)/1000,0)
        + "km  ecc=" + ROUND(ecc,4) + "  period=" + ROUND(effectivePeriod,0) + "s").

    LOCAL burnTA IS targetAoP - SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    UNTIL burnTA >= 0  { SET burnTA TO burnTA + 360. }
    UNTIL burnTA < 360 { SET burnTA TO burnTA - 360. }

    LOCAL burnETA IS etaToTrueAnomaly(burnTA).
    LOCAL burnUT IS TIME:SECONDS + burnETA.
    LOCAL burnR IS POSITIONAT(SHIP, burnUT):MAG.

    mLog("burnR=" + ROUND(burnR/1000,1) + "km  targetPeR=" + ROUND(targetPeR/1000,1) + "km  ETA=" + ROUND(burnETA,0) + "s").

    IF targetPeR - burnR > 5000 {
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
            + "m/s  coast=" + ROUND(period_int/2,0) + "s between burns").
        RETURN LIST(nd1, nd2).
    } ELSE {
        LOCAL vNew IS SQRT(mu * (2/burnR - 1/targetSMA)).
        LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
        LOCAL dv IS vNew - vNow.
        LOCAL nd IS NODE(burnUT, 0, 0, dv).
        ADD nd.

        mLog("Molniya node: dV=" + ROUND(dv,1) + "m/s  pe=" + ROUND((targetPeR-bodyR)/1000,0)
            + "km  ap=" + ROUND((targetApR-bodyR)/1000,0) + "km  ecc=" + ROUND(ecc,4)
            + "  period=" + ROUND(effectivePeriod,0) + "s").
        RETURN LIST(nd).
    }
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
