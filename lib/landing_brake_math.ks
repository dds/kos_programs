// Shared powered-descent control law: flight and orbital prediction.
@LAZYGLOBAL OFF.

// A validated powered range is a fixed site's lateral braking deadline,
// independent of the vertical stopping deadline. Legacy/unknown range still
// needs the altitude/V-ETA guard that prevents distant targets causing hover.
GLOBAL FUNCTION lmHorizontalBrakeGateArmed {
    PARAMETER height.
    PARAMETER verticalEta.
    PARAMETER poweredRangeValid.
    RETURN height <= TERRAIN_SAFE_ALT OR verticalEta <= LANDING_BRAKE_ALIGN_LEAD
        OR (poweredRangeValid AND LANDING_POWERED_LEAD > 0
            AND LANDING_ECONOMY_BRAKE > 0 AND LANDING_FLEXIBLE_SITE <= 0).
}

// Spend surplus altitude descending during horizontal arrest, then leave
// enough height to stop the remaining descent on the weaker planned stage.
// Reaction time, full gravity and existing clearance are reserved first.
GLOBAL FUNCTION lmBrakeDescentTarget {
    PARAMETER horizontalSpeed.
    PARAMETER downSpeed.
    PARAMETER height.
    PARAMETER currentAcc.
    PARAMETER planAcc.
    PARAMETER gravAcc.
    PARAMETER delay.
    PARAMETER currentGrav.
    IF planAcc <= gravAcc OR currentAcc <= gravAcc { RETURN 0. }
    LOCAL futureDown IS MAX(0, downSpeed + gravAcc * delay).
    LOCAL availableHeight IS height - downSpeed * delay - gravAcc * delay ^ 2 / 2.
    LOCAL low IS 0.
    // Pure horizontal full thrust is the greatest permitted downward
    // acceleration. This bound prevents an engine-down steering request.
    LOCAL high IS downSpeed + currentGrav * horizontalSpeed / currentAcc.
    LOCAL iteration IS 0.
    UNTIL iteration >= 10 {
        LOCAL terminalDown IS (low + high) / 2.
        LOCAL deltaDown IS futureDown - terminalDown.
        LOCAL speed IS SQRT(horizontalSpeed ^ 2 + deltaDown ^ 2).
        // For any gravity between zero and the surface bound, the exact
        // net limit is concave in g. Its minimum is at an endpoint. This
        // also covers orbital centrifugal support disappearing in the burn.
        LOCAL netAcc IS MIN(planAcc,
            lmBrakeFullNetAcc(horizontalSpeed, deltaDown, planAcc, gravAcc)).
        LOCAL stopTime IS speed / MAX(0.001, netAcc) * MAX(1, BURN_MARGIN).
        // The flare uses the unchanged 80%-net envelope, including residual
        // lateral speed, reaction/staging delay, burn margin and clearance.
        LOCAL flare IS lmBrakeEnvelope(APPROACH_HSPEED, terminalDown,
            planAcc, gravAcc, delay).
        LOCAL usedHeight IS (futureDown + terminalDown) * stopTime / 2
            + flare["V"].
        IF netAcc > 0 AND usedHeight <= availableHeight {
            SET low TO terminalDown.
        } ELSE { SET high TO terminalDown. }
        SET iteration TO iteration + 1.
    }
    RETURN -low.
}

// Full available thrust along the chosen net velocity-change direction.
// Retain the one-second tail taper and never point the engine downward.
GLOBAL FUNCTION lmEconomyBrakeThrust {
    PARAMETER horizontalVel.
    PARAMETER verticalSpeed.
    PARAMETER targetVs.
    PARAMETER upVec.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    LOCAL deltaVel IS -horizontalVel + (targetVs - verticalSpeed) * upVec.
    LOCAL thrustVec IS gravAcc * upVec.
    IF deltaVel:MAG > 0.001 {
        LOCAL netAcc IS MIN(lmBrakeFullNetAcc(horizontalVel:MAG,
            targetVs - verticalSpeed, maxAcc, gravAcc),
            deltaVel:MAG / MAX(0.1, LANDING_BRAKE_RESPONSE_TIME)).
        SET thrustVec TO thrustVec + deltaVel:NORMALIZED * netAcc.
    }
    LOCAL upwardAcc IS VDOT(thrustVec, upVec).
    IF upwardAcc < 0 { SET thrustVec TO thrustVec - upwardAcc * upVec. }
    LOCAL pitchFloor IS MAX(0,MIN(2,LANDING_BRAKE_MIN_PITCH)).
    LOCAL magnitude IS thrustVec:MAG.
    LOCAL horizontalThrust IS VXCL(upVec,thrustVec).
    IF horizontalThrust:MAG > 0.001
            AND VDOT(thrustVec,upVec) < magnitude*SIN(pitchFloor) {
        // Rotate at constant magnitude; never increase requested thrust.
        // The live actual-facing guard still forbids engine-down thrust.
        SET thrustVec TO magnitude*(horizontalThrust:NORMALIZED*COS(pitchFloor)
            + upVec*SIN(pitchFloor)).
    }
    RETURN thrustVec.
}
