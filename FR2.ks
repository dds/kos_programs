// FR2 rockets are capable of delivering 500kg+ payloads to Kerbin system.
// Mission sortie:
//  1. Mun flyby
//  2. Kerbin CommNet
//  3. Beyond

@LAZYGLOBAL OFF.

DECLARE GLOBAL desiredAltitude TO 100000.
DECLARE GLOBAL desiredInclination TO 0.
DECLARE GLOBAL desiredHeading TO 90.

// Open and configure term
CORE:DOACTION("Open Terminal", TRUE).
SET TERMINAL:HEIGHT to 40.
SET TERMINAL:WIDTH to 80.

DECLARE GLOBAL FUNCTION main {
    init().
    PRINT " ".
    PRINT "Welcome to FR2.".

    WAIT 2. // 2 seconds for everything to settle.

    // waitForLaunch().
    countdown(5).
    startLaunch().
    ascend().
    circularizeKerbin().
    endLaunch().

    LOCAL munTransfer TO hohmannTransfer(Mun, 10000).
    ADD munTransfer.
    HUDTEXT("Mun Transfer Node Created", 1, 2, 15, WHITE, FALSE).

    // Generate the capture node using the transfer node's flight path.
    WAIT 0.1.
    IF munTransfer:Orbit:hasNextPatch {
        LOCAL encounterOrbit TO munTransfer:Orbit:NextPatch.
        // Time of Mun periapsis. 
        LOCAL captureUt TO munTransfer:TIME + munTransfer:Orbit:NextPatchETA + encounterOrbit:Periapsis:ETA.
        // Velocity difference at periapsis.
        LOCAL mu TO Mun:Mu.
        LOCAL rAtPe TO encounterOrbit:PeriApsis + Mun:Radius.
        LOCAL vAtPe TO SQRT(mu * ((2 / rAtPe) - (1 / encounterOrbit:SemiMajorAxis))).
        LOCAL vCirc TO SQRT(mu / rAtPe).
        LOCAL captDV TO vCirc - vAtPe.

        LOCAL munCapture TO NODE(captureUt, 0, 0, captDV).
        ADD munCapture.
        HUDTEXT("Mun Capture Node Created", 1, 2, 15, WHITE, FALSE).
    }

    executeManeuver(munTransfer).
    warpToMunSOI().
    executeManeuver(munCapture).

    exit().
}

DECLARE LOCAL FUNCTION init {
    CLEARSCREEN.
    PRINT "INITFR".
    PRINT " ".

    // Load dependencies.

    // MechJeb2
    LOCAL mj IS ADDONS:MJ.
    LOCAL mjCore IS mj:CORE. 
    if mj:AVAILABLE {
        PRINT "MechJeb is available.".
        LOCAL mjRunning IS "NOT running.".
        if mjCore:RUNNING {
            SET mjRunning TO "running.".
        }
        PRINT "MechJeb core is " + mjRunning.
        LOCAL planner TO ADDONS:MJ:PLANNER.
        IF DEFINED(planner) {
            PRINT "MechJeb Maneuver Planner is available.".
        } else {
            PRINT "MechJeb Maneuver Planner is NOT available.".
        }

        // See https://github.com/belpyro/kOS.MechJeb2.Addon/blob/main/Tests/AscentWrapperTest.ks
        LOCAL Asc IS ADDONS:MJ:ASCENT.
        SET Asc:Enabled TO TRUE.
        SET Asc:DesiredAltitude TO desiredAltitude.
        SET Asc:DesiredInclination TO desiredInclination.
        SET Asc:AutoStage TO TRUE.
        SET Asc:AutoStageLimit TO 2. // CHECK YO STAGING
        SET Asc:AutoDeployAntennas TO TRUE.
        SET Asc:AutoDeploySolarPanels TO TRUE.
        SET Asc:AutoWarp TO FALSE.
        SET Asc:SkipCircularization TO FALSE.
    } else {
        PRINT "WARNING: MechJeb reported as NOT AVAILABLE.".
    }

    LOCAL libs IS LIST("lib/files.ks", "lib/countdown.ks").
    FOR lib IN libs {
        LOCAL archivePath IS "0:/{0}":FORMAT(lib).
        LOCAL localPath IS "1:/{0}":FORMAT(lib).
        COPYPATH("0:/{0}":FORMAT(lib), "1:/{0}":FORMAT(lib)).
        PRINT "Copied {0} to {1}":FORMAT(archivePath, localPath). 
        RUNONCEPATH("1:/{0}":FORMAT(lib)).
        PRINT "Loaded {0}":FORMAT(localPath).
    }.
    printStorageStatus().
}

DECLARE LOCAL FUNCTION waitForLaunch {
    PRINT "Engage autopilot then press ENTER to initiate countdown.".
    LOCAL ch is "".
    UNTIL ch = CHAR(13) {
        SET ch TO TERMINAL:INPUT:GETCHAR().
    }
}

DECLARE LOCAL FUNCTION myRoll {
    RETURN 360 - desiredHeading.
}

DECLARE LOCAL FUNCTION lockToPrograde {
    WAIT UNTIL (SHIP:AVAILABLETHRUST < MASS*CONSTANT:g0).
    PRINT "Locking to prograde.".
    LOCK STEERING TO SRFPROGRADE + R(0, 0, myRoll()).
}

// DECLARE LOCAL FUNCTION deployPayload {
//     WAIT UNTIL ALTITUDE < deployAlt AND VERTICALSPEED < 0.
//     STAGE.
//     HUDTEXT("Deploying payload", 1, 2, 15, WHITE, FALSE).
//     PRINT "Deploying payload.".
// }

DECLARE LOCAL FUNCTION startLaunch {
    PRINT "Launch initiated.".
}

DECLARE LOCAL FUNCTION endLaunch {
    LOCK THROTTLE to 0.
    UNLOCK STEERING.
    HUDTEXT("Launch complete.", 1, 2, 15, WHITE, FALSE).
}

DECLARE LOCAL FUNCTION ascend {
    PRINT "Utilizing MechJeb2 ascent assistance.".
    STAGE.
    HUDTEXT("IGNITION!", 1, 2, 15, GREEN, FALSE).
    PRINT "IGNITION!".

    // Deploy fairings at >68k, altitude.
    PRINT "Waitiing for 68,000m altitude to deploy main fairing.".
    WAIT UNTIL SHIP:ALTITUDE >= 68000.
    FOR p IN SHIP:PARTSTAGGED("main_fairing") {
        IF p:Modules:Contains("ModuleJettison") {
            LOCAL m IS p:GetModule("ModuleJettison").
            HUDTEXT("Fairing jettison.", 1, 2, 15, GREEN, FALSE).
            m:doAction("deploy", TRUE).
        }
    }
}

DECLARE LOCAL FUNCTION circularizeKerbin {
    WAIT UNTIL ADDONS:MJ:ASCENT:ENABLED = FALSE.
}

DECLARE LOCAL FUNCTION executeManeuver {
    DECLARE PARAMETER args.
    LOCAL mnv IS NODE(args[0], args[1], args[2], args[3]).

    ADD(mnv).
    LOCAL startTime IS calculateStartTime(mnv).
    WAIT UNTIL startTime - 10.
    lockSteeringAtManeuverTarget(mnv).
    WAIT UNTIL startTime.
    LOCK THROTTLE TO 1.
    WAIT UNTIL isManeuverComplete(mnv).
    LOCK THROTTLE TO 0.
    REMOVE(mnv).
}

DECLARE LOCAL FUNCTION hohmannTransfer {
    DECLARE PARAMETER targetBody.
    DECLARE PARAMETER targetPe.

    // 1. Calculate required phase angle for Hohmann Transfer.
    LOCAL r1 TO SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL r2 TO targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL mu TO BODY:MU.

    LOCAL tTrans TO CONSTANT:PI * SQRT( ((r1 + r2)^3) / (8 * mu) ).
    LOCAL targetOmega TO 360 / targetBody:ORBIT:PERIOD.
    LOCAL idealPhase TO 180 - (targetOmega * tTrans). // Approx 111.5 degrees.

    // 2. Calculate required dV aiming for trailing side periapsis.
    LOCAL targetRadius IS targetBody:RADIUS + targetPe.
    LOCAL aTrans IS (r1 + r2 + targetRadius) / 2.
    LOCAL v1 TO SQRT(mu / r1).
    LOCAL vTrans TO SQRT(mu * ((2 / r1) - (2 / (r1 + r2)))).
    LOCAL dV TO vTrans - v1.

    // 3. Find the correct time for the window
    // Get current angles relative to Kerbin's center
    // TODO: consider switching from ARCTAN2 to VANG and vectors
    LOCAL shipPos TO SHIP:POSITION - BODY:POSITION.
    LOCAL targetPos TO targetBody:POSITION - BODY:POSITION.
    LOCAL shipAng TO ARCTAN2(shipPos:X, shipPos:Z).
    LOCAL targetAng TO ARCTAN2(targetPos:X, targetPos:Z).

    LOCAL currentPhase TO targetAng - shipAng.
    IF currentPhase < 0 { SET currentPhase TO currentPhase + 360. }

    LOCAL shipOmega TO 360 / SHIP:ORBIT:PERIOD.
    LOCAL phaseSpeed TO shipOmega - targetOmega.

    // Time until the ideal phase angle is met
    LOCAL phaseDiff TO currentPhase - idealPhase.
    IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }
    LOCAL timeToBurn TO phaseDiff / phaseSpeed.

    // 4. Create and attach the node.
    LOCAL burnUt TO TIME:SECONDS + timeToBurn.
    PRINT "Ideal Mun transfer calculated!".
    PRINT "DeltaV Required: " + ROUND(dv, 1) + " m/s".
    return NODE(burnUt, 0, 0, dV).
}

DECLARE LOCAL FUNCTION transMunInjection {

}

DECLARE LOCAL FUNCTION transferToMun {

}

DECLARE LOCAL FUNCTION enterMunSOI {

}

DECLARE LOCAL FUNCTION circularizeMun {

}

DECLARE LOCAL FUNCTION exit {

}