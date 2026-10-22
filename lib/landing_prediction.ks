// Bounded vacuum brake/flare forecast using the shared live control law.
@LAZYGLOBAL OFF.

// Calibrate cross-product handedness against increasing native longitude.
// Surface-frame equations then include Coriolis and centrifugal forces.
GLOBAL FUNCTION landingRotationVector {
    LOCAL pole IS (LATLNG(90,0):ALTITUDEPOSITION(0)-SHIP:BODY:POSITION):NORMALIZED.
    LOCAL equator IS LATLNG(0,0):ALTITUDEPOSITION(0)-SHIP:BODY:POSITION.
    LOCAL east IS LATLNG(0,0.01):ALTITUDEPOSITION(0)-SHIP:BODY:POSITION-equator.
    IF VDOT(VCRS(pole,equator),east) < 0 { SET pole TO -pole. }
    IF ABS(SHIP:BODY:ROTATIONPERIOD) < 0.01 { RETURN pole*0. }
    RETURN pole*(2*CONSTANT:PI/SHIP:BODY:ROTATIONPERIOD).
}

LOCAL FUNCTION _landingPredictionCommand {
    PARAMETER pos.
    PARAMETER vel.
    PARAMETER maxAcc.
    PARAMETER planAcc.
    PARAMETER elevation.
    LOCAL upVec IS pos:NORMALIZED.
    LOCAL verticalSpeed IS VDOT(vel,upVec).
    LOCAL hVel IS VXCL(upVec,vel).
    LOCAL height IS pos:MAG-SHIP:BODY:RADIUS-elevation.
    LOCAL surfaceG IS SHIP:BODY:MU/SHIP:BODY:RADIUS^2.
    LOCAL effectiveG IS MAX(0.01,SHIP:BODY:MU/pos:MAG^2-hVel:MAG^2/pos:MAG).
    LOCAL command IS pos*0.
    IF hVel:MAG > APPROACH_HSPEED {
        LOCAL desiredVs IS lmBrakeDescentTarget(hVel:MAG,MAX(0,-verticalSpeed),height,
            maxAcc,planAcc,surfaceG,MAX(0,LANDING_BRAKE_REACTION_TIME),effectiveG).
        SET command TO lmEconomyBrakeThrust(hVel,verticalSpeed,desiredVs,upVec,maxAcc,effectiveG).
    } ELSE {
        LOCAL envelope IS lmBrakeEnvelope(hVel:MAG,MAX(0,-verticalSpeed),planAcc,
            surfaceG,MAX(0,LANDING_BRAKE_REACTION_TIME)).
        IF height > envelope["V"] AND height > TERMINAL_ALT { RETURN pos*0. }
        LOCAL desiredVs IS -lmDescentSpeed(height,TOUCHDOWN_SPEED,UPRIGHT_ALT,HIGH_DESCENT_SPEED).
        SET command TO lmBrakeThrust(hVel,verticalSpeed,desiredVs,upVec,maxAcc,effectiveG).
    }
    // Flight clamps throttle to one even when gravity support alone exceeds
    // available thrust. A forecast may never turn that request into a hover.
    IF command:MAG > maxAcc { RETURN command:NORMALIZED*MAX(0,maxAcc). }
    RETURN command.
}

LOCAL FUNCTION _landingPredictionGravity {
    PARAMETER pos.
    PARAMETER vel.
    PARAMETER omega.
    RETURN -SHIP:BODY:MU*pos/pos:MAG^3
        - 2*VCRS(omega,vel)-VCRS(omega,VCRS(omega,pos)).
}

// Midpoint integration to braking/flare capture, not an assertion of safe
// touchdown on unknown terrain. Attitude is ideal; the live 15-degree and
// engine-up guards are never bypassed. No expensive simulation in a lock or
// powered guidance tick. Bound both integration steps and execution time.
GLOBAL FUNCTION landingPredictBrake {
    PARAMETER pos.
    PARAMETER vel.
    PARAMETER stack.
    PARAMETER elevation.
    PARAMETER stepSeconds IS 1.
    LOCAL failure IS LEXICON("VALID",FALSE,"REASON","prediction-budget").
    IF NOT stack["VALID"] { RETURN stack. }
    LOCAL omega IS landingRotationVector().
    LOCAL massNow IS stack["MASS"].
    LOCAL stageIndex IS 0.
    LOCAL item IS stack["STAGES"][0].
    LOCAL fuelLeft IS item["FUEL"].
    LOCAL elapsed IS 0.
    LOCAL impulse IS 0.
    LOCAL pauseLeft IS 0.
    LOCAL iteration IS 0.
    LOCAL started IS TIME:SECONDS.
    UNTIL iteration >= 1024 OR elapsed >= 900 OR ABORT {
        LOCAL upVec IS pos:NORMALIZED.
        LOCAL height IS pos:MAG-SHIP:BODY:RADIUS-elevation.
        LOCAL hs IS VXCL(upVec,vel):MAG.
        LOCAL vs IS VDOT(vel,upVec).
        LOCAL desiredVs IS -lmDescentSpeed(height,TOUCHDOWN_SPEED,UPRIGHT_ALT,HIGH_DESCENT_SPEED).
        IF height <= TERMINAL_ALT AND hs <= TERMINAL_HSPEED AND ABS(vs-desiredVs) <= 5 {
            RETURN LEXICON("VALID",TRUE,"REASON","brake-capture","POSITION",pos,
                "VELOCITY",vel,"SECONDS",elapsed,"IMPULSE",impulse,"MASS",massNow,
                "HEIGHT",height,"HS",hs,"VS",vs,"STEPS",iteration,"STAGES_USED",stageIndex+1).
        }
        IF height <= MAX(1,UPRIGHT_ALT) { SET failure["REASON"] TO "uncaptured-at-surface". RETURN failure. }
        LOCAL maxAcc IS item["THRUST"]/massNow.
        LOCAL planAcc IS maxAcc.
        IF stageIndex = 0 AND stack["RESERVE_ACC"] > 0 {
            SET planAcc TO MIN(maxAcc,stack["RESERVE_ACC"]).
        }
        LOCAL step IS MAX(0.05,MIN(2,stepSeconds)).
        IF hs < APPROACH_HSPEED*2 { SET step TO MIN(step,0.25). }
        LOCAL command IS _landingPredictionCommand(pos,vel,maxAcc,planAcc,elevation).
        LOCAL flow IS command:MAG*massNow/item["EXHAUST"].
        IF pauseLeft > 0 { SET command TO pos*0. SET flow TO 0. SET step TO MIN(step,pauseLeft). }
        IF flow > 0 { SET step TO MIN(step,fuelLeft/flow). }
        LOCAL midpointMass IS massNow-flow*step/2.
        LOCAL accel IS command+_landingPredictionGravity(pos,vel,omega).
        LOCAL midpointPos IS pos+vel*step/2.
        LOCAL midpointVel IS vel+accel*step/2.
        LOCAL midpointAcc IS item["THRUST"]/midpointMass.
        LOCAL midpointPlan IS midpointAcc.
        IF stageIndex = 0 AND stack["RESERVE_ACC"] > 0 {
            SET midpointPlan TO MIN(midpointAcc,stack["RESERVE_ACC"]).
        }
        SET command TO _landingPredictionCommand(midpointPos,midpointVel,midpointAcc,midpointPlan,elevation).
        IF pauseLeft > 0 { SET command TO pos*0. }
        // Bound midpoint fuel use at the exact depletion event.
        LOCAL used IS MIN(fuelLeft,command:MAG*midpointMass/item["EXHAUST"]*step).
        IF step > 0 { SET command TO command*MIN(1,used/MAX(0.000000001,command:MAG*midpointMass/item["EXHAUST"]*step)). }
        SET pos TO pos+midpointVel*step.
        SET vel TO vel+(command+_landingPredictionGravity(midpointPos,midpointVel,omega))*step.
        SET impulse TO impulse+command:MAG*step.
        SET massNow TO massNow-used.
        SET fuelLeft TO MAX(0,fuelLeft-used).
        SET elapsed TO elapsed+step.
        SET pauseLeft TO MAX(0,pauseLeft-step).
        IF fuelLeft <= 0.00000001 {
            IF stageIndex+1 >= stack["STAGES"]:LENGTH {
                SET failure["REASON"] TO "landing-fuel-exhausted". RETURN failure.
            }
            SET massNow TO massNow-item["DROP"].
            SET stageIndex TO stageIndex+1.
            SET item TO stack["STAGES"][stageIndex].
            SET fuelLeft TO item["FUEL"].
            SET pauseLeft TO 2*MAX(0.05,LANDING_STAGE_SETTLE).
        }
        SET iteration TO iteration+1.
        IF TIME:SECONDS-started > 20 { RETURN failure. }
    }
    IF ABORT { SET failure["REASON"] TO "abort". }
    RETURN failure.
}
