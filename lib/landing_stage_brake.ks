// ============================================================
// landing_stage_brake.ks - Bounded serial-stage powered-descent budget
// (0:/lib/landing_stage_brake.ks)
// Kept out of the compact deorbit and shared hardware/math bands.
// ============================================================
@LAZYGLOBAL OFF.

// Bound the current-stage dV by its own enabled propellant and mixture,
// never the lander's retained tanks. Stock dV alone may be stale or wrong.
// Opt-in supports a single controllable engine on an adjacent serial stage.
GLOBAL FUNCTION vesselLandingBrakeStageDv {
    IF SHIP:BODY:ATM:EXISTS OR SHIP:MASS <= 0 { RETURN 0. }
    LOCAL engineStage IS vesselLandingNextEngineStage().
    IF engineStage < 0 OR STAGE:NUMBER <> engineStage+1
            OR CORE:PART:DECOUPLEDIN >= engineStage { RETURN 0. }
    LOCAL activeEngine IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:AVAILABLETHRUST > 0 {
            IF eng:DECOUPLEDIN <> engineStage OR eng:THROTTLELOCK
                    OR eng:MULTIMODE OR activeEngine <> 0 { RETURN 0. }
            SET activeEngine TO eng.
        }
        IF eng:POSSIBLETHRUST > 0 AND NOT eng:FLAMEOUT
                AND eng:DECOUPLEDIN < engineStage AND eng:STAGE <> engineStage {
            RETURN 0.
        }
    }
    IF activeEngine = 0 { RETURN 0. }
    LOCAL mixture IS activeEngine:CONSUMEDRESOURCES.
    IF mixture:LENGTH = 0 OR activeEngine:VISP <= 0 { RETURN 0. }
    LOCAL mixtureUnits IS 1e30.
    LOCAL mixtureDensity IS 0.
    FOR fuel IN mixture:VALUES {
        // Massless requirements (for example ion EC) and unusual mixtures
        // have no dependable coasting fuel estimate here; keep the fallback.
        IF fuel:RATIO <= 0 OR fuel:DENSITY <= 0 { RETURN 0. }
        LOCAL units IS 0.
        FOR part IN SHIP:PARTS {
            IF part:DECOUPLEDIN = engineStage {
                FOR held IN part:RESOURCES {
                    IF held:NAME = fuel:NAME AND held:ENABLED {
                        SET units TO units+MAX(0,held:AMOUNT).
                    }
                }
            }
        }
        SET mixtureUnits TO MIN(mixtureUnits,units/fuel:RATIO).
        SET mixtureDensity TO mixtureDensity+fuel:RATIO*fuel:DENSITY.
    }
    LOCAL fuelMass IS mixtureUnits*mixtureDensity.
    IF NOT (fuelMass > 0 AND fuelMass < SHIP:MASS) { RETURN 0. }
    LOCAL physicalDv IS activeEngine:VISP*9.80665*LN(SHIP:MASS/(SHIP:MASS-fuelMass)).
    LOCAL stockDv IS STAGE:DELTAV:VACUUM.
    IF NOT (stockDv > 0 AND stockDv < 1e30) { RETURN 0. }
    RETURN MIN(stockDv,physicalDv).
}

// Exact net-acceleration limit in a chosen velocity-change direction:
// |g*up + aNet*direction| = aMax. The old aMax-g is its conservative
// triangle-inequality bound. Shared by full-vector control and its gate.
GLOBAL FUNCTION lmBrakeFullNetAcc {
    PARAMETER horizontalSpeed.
    PARAMETER deltaDown.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    IF maxAcc <= gravAcc { RETURN 0. }
    LOCAL speed IS SQRT(horizontalSpeed ^ 2 + deltaDown ^ 2).
    IF speed < 0.001 { RETURN 0. }
    LOCAL upFraction IS deltaDown / speed.
    RETURN MAX(0, -gravAcc * upFraction
        + SQRT(MAX(0, maxAcc ^ 2 - gravAcc ^ 2 * (1 - upFraction ^ 2)))).
}

// Full-vector stop with the same acceleration reserve, latency and gravity.
// For u=(horizontal,upward) net braking, |g*up+aNet*u| <= aMax gives
// aNet=-g*uUp+sqrt(aMax^2-g^2*(1-uUp^2)). This avoids charging full g
// against the horizontal component. The weaker aMax-g bound remains fallback.
GLOBAL FUNCTION lmFullBrakeEnvelope {
    PARAMETER horizontalSpeed.
    PARAMETER downSpeed.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    PARAMETER delay.
    LOCAL futureDown IS MAX(0,downSpeed+gravAcc*delay).
    LOCAL speed IS SQRT(horizontalSpeed^2+futureDown^2).
    IF maxAcc <= gravAcc { RETURN lmBrakeEnvelope(horizontalSpeed,downSpeed,maxAcc,gravAcc,delay). }
    LOCAL stopTime IS 0.
    IF speed > 0.001 {
        LOCAL netAcc IS lmBrakeFullNetAcc(horizontalSpeed,futureDown,maxAcc,gravAcc)
            * MAX(0.1,MIN(1,LANDING_BRAKE_ACCEL_FRACTION)).
        SET stopTime TO speed/MAX(0.001,netAcc)*MAX(1,BURN_MARGIN).
    }
    RETURN LEXICON("H",horizontalSpeed*(delay+stopTime/2),
        "V",MAX(0,downSpeed*delay+gravAcc*delay^2/2)
            + futureDown*stopTime/2+MAX(BRAKE_MARGIN,LANDING_BRAKE_CLEARANCE)).
}

// Serial high-thrust stage followed by the weaker lander. Credit only
// measured current-stage fuel, converted to net impulse with the same 80%
// reserve and burn margin. Both coast/ignition intervals retain full gravity.
GLOBAL FUNCTION lmStagedBrakeEnvelope {
    PARAMETER horizontalSpeed.
    PARAMETER downSpeed.
    PARAMETER activeAcc.
    PARAMETER planAcc.
    PARAMETER stageDv.
    PARAMETER gravAcc.
    PARAMETER delay.
    PARAMETER fullVector IS FALSE.
    LOCAL fallback IS 0.
    IF fullVector {
        SET fallback TO lmFullBrakeEnvelope(horizontalSpeed,downSpeed,planAcc,gravAcc,delay).
    } ELSE { SET fallback TO lmBrakeEnvelope(horizontalSpeed,downSpeed,planAcc,gravAcc,delay). }
    IF stageDv <= 0 OR activeAcc <= planAcc OR planAcc <= gravAcc { RETURN fallback. }
    LOCAL futureDown IS MAX(0,downSpeed+gravAcc*delay).
    LOCAL speed IS SQRT(horizontalSpeed^2+futureDown^2).
    IF speed <= 0.001 { RETURN fallback. }
    LOCAL activeNet IS 0.
    IF fullVector {
        SET activeNet TO lmBrakeFullNetAcc(horizontalSpeed,futureDown,activeAcc,gravAcc)
            * MAX(0.1,MIN(1,LANDING_BRAKE_ACCEL_FRACTION)).
    } ELSE { SET activeNet TO lmBrakeNetAcc(activeAcc,gravAcc). }
    IF activeNet <= 0 { RETURN fallback. }
    LOCAL credit IS MIN(speed,stageDv*activeNet/activeAcc/MAX(1,BURN_MARGIN)).
    LOCAL activeTime IS credit/activeNet*MAX(1,BURN_MARGIN).
    LOCAL remaining IS MAX(0,1-credit/speed).
    LOCAL remainingH IS horizontalSpeed*remaining.
    LOCAL remainingDown IS futureDown*remaining.
    // Reserve an additional separation/ignition pause after spending the
    // credited impulse. The weaker stage still owns all residual velocity.
    LOCAL tail IS 0.
    IF fullVector {
        SET tail TO lmFullBrakeEnvelope(remainingH,remainingDown,planAcc,gravAcc,delay).
    } ELSE { SET tail TO lmBrakeEnvelope(remainingH,remainingDown,planAcc,gravAcc,delay). }
    LOCAL horizontalDist IS horizontalSpeed*delay
        + (horizontalSpeed+remainingH)*activeTime/2+tail["H"].
    LOCAL verticalDist IS MAX(0,downSpeed*delay+gravAcc*delay^2/2)
        + (futureDown+remainingDown)*activeTime/2+tail["V"].
    // Use a single envelope for both components. If the extra staging pause
    // costs more than the tiny fuel credit saves, keep the old early gate.
    IF horizontalDist >= fallback["H"] OR verticalDist >= fallback["V"] { RETURN fallback. }
    RETURN LEXICON("H",horizontalDist,"V",verticalDist).
}

GLOBAL FUNCTION _landingStopEnvelope {
    PARAMETER ctx.
    PARAMETER horizontalSpeed.
    PARAMETER downSpeed.
    LOCAL delay IS MAX(0,LANDING_BRAKE_REACTION_TIME).
    IF LANDING_STAGE_BRAKE_CREDIT > 0 {
        // Include both staging settle intervals and bounded control latency.
        SET delay TO MAX(delay,1+2*MAX(0.05,LANDING_STAGE_SETTLE)).
        RETURN lmStagedBrakeEnvelope(horizontalSpeed,downSpeed,ctx["MAX_ACC"],
            ctx["PLAN_ACC"],ctx["BRAKE_STAGE_DV"],ctx["BRAKE_GRAV"],delay,LANDING_ECONOMY_BRAKE > 0).
    }
    RETURN lmBrakeEnvelope(horizontalSpeed,downSpeed,ctx["PLAN_ACC"],ctx["BRAKE_GRAV"],delay).
}

