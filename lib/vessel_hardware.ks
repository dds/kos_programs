// ============================================================
// vessel_hardware.ks  -  Vessel hardware operations
// (0:/lib/vessel_hardware.ks)
//
// Landing guidance calls these at state transitions or from the tick-level
// global checks. This keeps flight math out of part-module bookkeeping.
// ============================================================

@LAZYGLOBAL OFF.

GLOBAL LANDING_STAGE_LIMIT IS 0.
GLOBAL LANDING_STAGE_MAX_EVENTS IS 4.
GLOBAL LANDING_STAGE_SETTLE IS 0.25.

GLOBAL FUNCTION vesselDeployGear {
    FOR m IN SHIP:MODULESNAMED("ModuleWheelDeployment") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    FOR m IN SHIP:MODULESNAMED("ModuleLandingLeg") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    GEAR ON.
}

GLOBAL FUNCTION vesselDeployAntennas {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableAntenna") {
        IF m:HASEVENT("Extend Antenna") { m:DOEVENT("Extend Antenna"). }
    }
}

GLOBAL FUNCTION vesselDeploySolarPanels {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
        IF m:HASEVENT("Extend Solar Panel") { m:DOEVENT("Extend Solar Panel"). }
    }
}

GLOBAL FUNCTION vesselSetReactionWheelAuthority {
    PARAMETER pct.
    LOCAL clampedPct IS MAX(0, MIN(100, pct)).
    FOR m IN SHIP:MODULESNAMED("ModuleReactionWheel") {
        IF m:HASFIELD("Authority Limiter") {
            m:SETFIELD("Authority Limiter", clampedPct).
        }
    }
}

GLOBAL FUNCTION vesselNeedsStage {
    RETURN vesselLandingThrust() <= 0.001.
}

GLOBAL FUNCTION vesselLandingThrust {
    LOCAL thrustSum IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT {
            SET thrustSum TO thrustSum + eng:AVAILABLETHRUST.
        }
    }
    RETURN thrustSum.
}

GLOBAL FUNCTION vesselLandingNextEngineStage {
    LOCAL engineStage IS -1.
    FOR eng IN SHIP:ENGINES {
        IF NOT eng:IGNITION AND NOT eng:FLAMEOUT
                AND NOT eng:THROTTLELOCK AND eng:POSSIBLETHRUST > 0
                AND eng:STAGE <= STAGE:NUMBER
                AND eng:STAGE >= MAX(0, LANDING_STAGE_LIMIT)
                AND eng:DECOUPLEDIN < eng:STAGE {
            SET engineStage TO MAX(engineStage, eng:STAGE).
        }
    }
    RETURN engineStage.
}

// Conservative next-stage acceleration at its current wet mass. Fuel burn
// can only improve this estimate for a conventional serial landing stack.
GLOBAL FUNCTION vesselLandingReserveAcc {
    LOCAL engineStage IS vesselLandingNextEngineStage().
    IF engineStage < 0 { RETURN 0. }
    LOCAL thrustSum IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:STAGE = engineStage AND eng:DECOUPLEDIN < engineStage
                AND NOT eng:THROTTLELOCK AND NOT eng:FLAMEOUT {
            SET thrustSum TO thrustSum + eng:POSSIBLETHRUST.
        }
    }
    LOCAL wetMass IS 0.
    LOCAL accountedMass IS 0.
    FOR part IN SHIP:PARTS {
        SET accountedMass TO accountedMass + part:MASS.
        IF part:DECOUPLEDIN < engineStage {
            SET wetMass TO wetMass + part:MASS.
        }
    }
    // kOS reports zero MASS for physicsless parts. Keep any discrepancy
    // with vessel mass on the lander rather than overestimating its TWR.
    SET wetMass TO wetMass + MAX(0, SHIP:MASS - accountedMass).
    RETURN thrustSum / MAX(0.01, wetMass).
}

// Shared separation event. The caller owns the decision to discard a stage;
// even an authorized fueled-stage handoff must verify physical cutoff first.
GLOBAL FUNCTION vesselLandingStageEvent {
    PARAMETER ctx.
    PARAMETER engineStage.
    SET ctx["TARGET_THROTTLE"] TO 0.
    SET SHIP:CONTROL:MAINTHROTTLE TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    IF ABORT OR NOT (SHIP:THRUST <= 0.001) OR NOT STAGE:READY
            OR STAGE:NUMBER <= engineStage OR engineStage < MAX(0, LANDING_STAGE_LIMIT)
            OR ctx["STAGE_EVENTS"] >= LANDING_STAGE_MAX_EVENTS { RETURN FALSE. }
    STAGE.
    SET ctx["STAGE_EVENTS"] TO ctx["STAGE_EVENTS"] + 1.
    SET ctx["STAGE_UNTIL"] TO TIME:SECONDS + MAX(0.05, LANDING_STAGE_SETTLE).
    mLog("STATS landing-stage event stage=" + STAGE:NUMBER
        + " engineStage=" + engineStage + " radar=" + ROUND(ALT:RADAR,0)).
    RETURN TRUE.
}

GLOBAL FUNCTION vesselStageForLanding {
    PARAMETER ctx.
    PARAMETER paused IS FALSE.
    IF ABORT {
        SET ctx["TARGET_THROTTLE"] TO 0.
        RETURN.
    }
    IF paused { RETURN. }
    // Tick-driven: steering/control continue between separation and ignition.
    IF TIME:SECONDS < ctx["STAGE_UNTIL"] { RETURN. }
    IF NOT vesselNeedsStage() {
        IF ctx["STAGE_ENGINE"] >= 0 {
            mLog("STATS landing-stage resumed stage=" + STAGE:NUMBER
                + " acc=" + ROUND(vesselLandingThrust() / MAX(0.01, SHIP:MASS),2)
                + " radar=" + ROUND(ALT:RADAR,0)).
        }
        SET ctx["STAGE_ENGINE"] TO -1.
        SET ctx["STAGE_EVENTS"] TO 0.
        SET ctx["STAGE_ACTIVATED"] TO FALSE.
        SET ctx["STAGE_WARNED"] TO FALSE.
        RETURN.
    }
    IF ctx["STAGE_ENGINE"] < 0 {
        SET ctx["STAGE_ENGINE"] TO vesselLandingNextEngineStage().
    }
    LOCAL engineStage IS ctx["STAGE_ENGINE"].
    IF engineStage < 0 OR (ctx["STAGE_EVENTS"] >= LANDING_STAGE_MAX_EVENTS
            AND STAGE:NUMBER > engineStage) {
        IF NOT ctx["STAGE_WARNED"] {
            mLogWarn("Landing thrust unavailable; inspect engine/staging. Guidance remains active.").
            SET ctx["STAGE_WARNED"] TO TRUE.
        }
        RETURN.
    }
    // Never advance past the selected engine into return/payload/chute slots.
    IF STAGE:NUMBER > engineStage AND STAGE:READY {
        vesselLandingStageEvent(ctx, engineStage).
    } ELSE IF STAGE:NUMBER = engineStage AND NOT ctx["STAGE_ACTIVATED"] {
        SET ctx["STAGE_ACTIVATED"] TO TRUE.
        FOR eng IN SHIP:ENGINES {
            IF eng:STAGE = engineStage AND NOT eng:IGNITION
                    AND eng:DECOUPLEDIN < engineStage {
                eng:ACTIVATE.
            }
        }
        SET ctx["STAGE_UNTIL"] TO TIME:SECONDS + MAX(0.05, LANDING_STAGE_SETTLE).
    }
}

GLOBAL FUNCTION vesselLandingCleanup {
    LOCAL stopped IS thrustCutoffOk().
    UNLOCK STEERING.
    SET SAS TO TRUE.
    RETURN stopped.
}
