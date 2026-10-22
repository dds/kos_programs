// ============================================================
// landing_brake_fuel.ks - Local fuel snapshots and geographic range.
// No steering, throttle, staging, file I/O or landing FSM. All fuel is local
// to an engine's serial group; reserved return tanks remain carried mass.
// ============================================================
@LAZYGLOBAL OFF.

LOCAL FUNCTION _landingEngineFuelMass {
    PARAMETER eng.
    LOCAL units IS 1e30.
    LOCAL density IS 0.
    IF eng:CONSUMEDRESOURCES:LENGTH = 0 { RETURN -1. }
    FOR fuel IN eng:CONSUMEDRESOURCES:VALUES {
        IF fuel:RATIO <= 0 OR fuel:DENSITY <= 0 { RETURN -1. }
        LOCAL amount IS 0.
        FOR part IN SHIP:PARTS {
            IF part:DECOUPLEDIN = eng:DECOUPLEDIN {
                FOR held IN part:RESOURCES {
                    IF held:NAME = fuel:NAME AND held:ENABLED {
                        SET amount TO amount+MAX(0,held:AMOUNT).
                    }
                }
            }
        }
        SET units TO MIN(units,amount/fuel:RATIO).
        SET density TO density+fuel:RATIO*fuel:DENSITY.
    }
    RETURN units*density.
}

// Supported: one active throttleable engine and at most one eligible serial
// landing engine. No parallel propulsion, atmospheric model, solids or
// ambiguous mixture. Unsupported flight guidance retains its old safe gate;
// an unflown precision deorbit must hold rather than silently trust a model.
GLOBAL FUNCTION landingBrakeStack {
    LOCAL result IS LEXICON("VALID",FALSE,"REASON","unsupported-stack").
    IF SHIP:BODY:ATM:EXISTS { SET result["REASON"] TO "atmosphere". RETURN result. }
    IF NOT landingRolePolicy["VALID"] { SET result["REASON"] TO "stage-role-policy". RETURN result. }
    IF LANDING_STAGE_DISCARD_HSPEED > 0 { SET result["REASON"] TO "elective-fueled-disposal". RETURN result. }
    LOCAL active IS 0.
    LOCAL nextEngine IS 0.
    LOCAL nextStage IS vesselLandingNextEngineStage().
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:AVAILABLETHRUST > 0 {
            IF active <> 0 OR eng:THROTTLELOCK OR eng:MULTIMODE { RETURN result. }
            SET active TO eng.
        } ELSE IF eng:POSSIBLETHRUST > 0 AND eng:STAGE >= vesselLandingStageFloor() {
            IF nextEngine <> 0 OR eng:STAGE <> nextStage
                    OR eng:THROTTLELOCK OR eng:MULTIMODE { RETURN result. }
            SET nextEngine TO eng.
        }
    }
    IF active = 0 OR active:VISP <= 0 { SET result["REASON"] TO "no-active-vacuum-engine". RETURN result. }
    LOCAL fuelMass IS _landingEngineFuelMass(active).
    IF fuelMass <= 0 OR fuelMass >= SHIP:MASS { SET result["REASON"] TO "current-local-propellant". RETURN result. }
    LOCAL physicalDv IS active:VISP*9.80665*LN(SHIP:MASS/(SHIP:MASS-fuelMass)).
    LOCAL stockDv IS STAGE:DELTAV:VACUUM.
    IF stockDv <= 0 { SET result["REASON"] TO "current-stage-dv-unavailable". RETURN result. }
    SET fuelMass TO MIN(fuelMass,SHIP:MASS*(1-CONSTANT:E^(-stockDv/(active:VISP*9.80665)))).
    LOCAL stages IS LIST(LEXICON("THRUST",active:AVAILABLETHRUST,
        "EXHAUST",active:VISP*9.80665,"FUEL",fuelMass,"DROP",0)).
    LOCAL reserveAcc IS 0.
    IF nextEngine <> 0 {
        IF STAGE:NUMBER <> nextStage+1 OR active:DECOUPLEDIN <> nextStage
                OR nextEngine:DECOUPLEDIN >= nextStage
                OR CORE:PART:DECOUPLEDIN >= nextStage OR nextEngine:VISP <= 0 {
            RETURN result.
        }
        LOCAL retained IS 0.
        LOCAL accounted IS 0.
        FOR part IN SHIP:PARTS {
            SET accounted TO accounted+part:MASS.
            IF part:DECOUPLEDIN < nextStage { SET retained TO retained+part:MASS. }
        }
        SET retained TO retained+MAX(0,SHIP:MASS-accounted).
        LOCAL dropMass IS SHIP:MASS-retained-fuelMass.
        LOCAL nextFuel IS _landingEngineFuelMass(nextEngine).
        LOCAL nextThrust IS nextEngine:POSSIBLETHRUSTAT(0).
        IF dropMass < 0 OR retained <= 0 OR nextFuel <= 0 OR nextFuel >= retained
                OR nextThrust <= 0 { RETURN result. }
        SET stages[0]["DROP"] TO dropMass.
        stages:ADD(LEXICON("THRUST",nextThrust,"EXHAUST",nextEngine:VISP*9.80665,
            "FUEL",nextFuel,"DROP",0)).
        SET reserveAcc TO nextThrust/retained.
    }
    RETURN LEXICON("VALID",TRUE,"REASON","serial-vacuum","MASS",SHIP:MASS,
        "STAGE",STAGE:NUMBER,"STAGES",stages,"RESERVE_ACC",reserveAcc).
}

// Independent copy at a new mass/after a planned deorbit impulse. No ship or
// snapshot mutation. Any already consumed current-stage mass is fuel only;
// stage number is checked by callers and a changed stack needs a new snapshot.
GLOBAL FUNCTION landingBrakeStackAt {
    PARAMETER stack.
    PARAMETER massNow.
    PARAMETER burnDv IS 0.
    IF NOT stack["VALID"] { RETURN stack. }
    LOCAL current IS stack["STAGES"][0].
    LOCAL massAfter IS massNow*CONSTANT:E^(-MAX(0,burnDv)/current["EXHAUST"]).
    LOCAL consumed IS stack["MASS"]-massAfter.
    IF consumed < -0.00001 OR consumed >= current["FUEL"] {
        RETURN LEXICON("VALID",FALSE,"REASON","current-fuel-exhausted").
    }
    LOCAL stages IS LIST().
    FOR item IN stack["STAGES"] {
        stages:ADD(LEXICON("THRUST",item["THRUST"],"EXHAUST",item["EXHAUST"],
            "FUEL",item["FUEL"],"DROP",item["DROP"])).
    }
    SET stages[0]["FUEL"] TO MAX(0,current["FUEL"]-consumed).
    RETURN LEXICON("VALID",TRUE,"MASS",massAfter,"STAGE",stack["STAGE"],
        "STAGES",stages,"RESERVE_ACC",stack["RESERVE_ACC"]).
}

// Fast geographic gate only: speed quadrature with evolving mass. Collision
// avoidance still uses the unchanged reserved V envelope. The orbital model
// below integrates the actual descent law rather than assuming steady fall.
GLOBAL FUNCTION lmFuelBrakeRange {
    PARAMETER horizontalSpeed.
    PARAMETER stack.
    PARAMETER gravAcc.
    PARAMETER modelRadius.
    PARAMETER stageDelay.
    LOCAL massNow IS stack["MASS"].
    LOCAL stageIndex IS 0.
    LOCAL item IS stack["STAGES"][0].
    LOCAL fuelLeft IS item["FUEL"].
    LOCAL speed IS horizontalSpeed.
    LOCAL distance IS 0.
    LOCAL interval IS 0.
    LOCAL endSpeed IS MIN(horizontalSpeed,MAX(0,APPROACH_HSPEED)).
    UNTIL interval >= 32 OR speed <= endSpeed {
        LOCAL nextSpeed IS MAX(endSpeed,horizontalSpeed-(horizontalSpeed-endSpeed)*(interval+1)/32).
        LOCAL deltaH IS speed-nextSpeed.
        LOCAL effectiveG IS MAX(0.01,gravAcc-((speed+nextSpeed)/2)^2/MAX(1,modelRadius)).
        LOCAL maxAcc IS item["THRUST"]/massNow.
        IF maxAcc <= effectiveG { RETURN -1. }
        LOCAL hAcc IS SQRT(maxAcc^2-effectiveG^2).
        LOCAL impulse IS deltaH*maxAcc/hAcc.
        LOCAL fuelNeeded IS massNow*(1-CONSTANT:E^(-impulse/item["EXHAUST"])).
        IF fuelNeeded > fuelLeft {
            SET impulse TO item["EXHAUST"]*LN(massNow/MAX(0.00001,massNow-fuelLeft)).
            SET deltaH TO impulse*hAcc/maxAcc.
            SET nextSpeed TO speed-deltaH.
            SET fuelNeeded TO fuelLeft.
        }
        // Midpoint mass accounts for increasing acceleration during each bin.
        SET maxAcc TO item["THRUST"]/(massNow-fuelNeeded/2).
        SET hAcc TO SQRT(MAX(0.000001,maxAcc^2-effectiveG^2)).
        SET distance TO distance+(speed+nextSpeed)*deltaH/(2*hAcc).
        SET speed TO nextSpeed.
        SET massNow TO massNow-fuelNeeded.
        SET fuelLeft TO MAX(0,fuelLeft-fuelNeeded).
        IF fuelLeft <= 0.00000001 AND speed > endSpeed {
            IF stageIndex+1 >= stack["STAGES"]:LENGTH { RETURN -1. }
            SET massNow TO massNow-item["DROP"].
            SET stageIndex TO stageIndex+1.
            SET item TO stack["STAGES"][stageIndex].
            SET fuelLeft TO item["FUEL"].
            SET distance TO distance+speed*stageDelay.
        } ELSE { SET interval TO interval+1. }
    }
    RETURN distance.
}
