GLOBAL FUNCTION planMolniyaInsert {
    PARAMETER targetPeriod.
    PARAMETER targetAoP.

    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL targetSMA IS (mu * (targetPeriod / (2 * CONSTANT:PI))^2)^(1/3).
    LOCAL peR IS bodyR + SHIP:PERIAPSIS.
    LOCAL targetApR IS 2 * targetSMA - peR.
    LOCAL targetAp IS targetApR - bodyR.
    LOCAL ecc IS 1 - peR / targetSMA.

    LOCAL burnTA IS targetAoP - SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    UNTIL burnTA >= 0   { SET burnTA TO burnTA + 360. }
    UNTIL burnTA < 360  { SET burnTA TO burnTA - 360. }

    LOCAL burnETA IS etaToTrueAnomaly(burnTA).
    LOCAL burnUT IS TIME:SECONDS + burnETA.
    LOCAL burnR IS bodyR + SHIP:ALTITUDE.
    LOCAL vNew IS SQRT(mu * (2/burnR - 1/targetSMA)).
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL dv IS vNew - vNow.

    LOCAL nd IS NODE(burnUT, 0, 0, dv).
    ADD nd.
    mLog("Molniya node: dV=" + ROUND(dv,1) + "m/s  ETA=" + ROUND(burnETA,0)
        + "s  targetAp=" + ROUND(targetAp/1000,0) + "km  ecc=" + ROUND(ecc,4)
        + "  AoP=" + ROUND(targetAoP,1) + "  period=" + ROUND(targetPeriod,0) + "s").
    RETURN nd.
}

GLOBAL FUNCTION phaseMolniyaInsert {
    LOCAL targetPeriod IS CFG["MOLNIYA_PERIOD"].
    LOCAL targetAoP IS CFG["MOLNIYA_AOP"].
    IF CFG:HASKEY("MOLNIYA_ECC") AND CFG["MOLNIYA_ECC"] > 0 {
        LOCAL mu IS SHIP:ORBIT:BODY:MU.
        LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
        LOCAL peR IS bodyR + SHIP:PERIAPSIS.
        LOCAL sma IS peR / (1 - CFG["MOLNIYA_ECC"]).
        SET targetPeriod TO 2 * CONSTANT:PI * SQRT(sma^3 / mu).
        mLog("MOLNIYA_ECC=" + CFG["MOLNIYA_ECC"] + " -> period=" + ROUND(targetPeriod,0) + "s").
    }
    mLogPhase("MOLNIYA INSERT").
    orbitSummary().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planMolniyaInsert(targetPeriod, targetAoP).
        SET success TO executeManeuver().
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
