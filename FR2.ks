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
    PRINT "Welcome to FR2.".

    WAIT 2. // 2 seconds for everything to settle.

    // waitForLaunch().
    countdown(5).
    startLaunch().
    ascend().
    circularizeKerbin().
    endLaunch().
    planMunTransfer().
    transMunInjection().
    transferToMun().
    enterMunSOI().
    circularizeMun().
    exit().
}

DECLARE LOCAL FUNCTION init {
    CLEARSCREEN.
    PRINT "INITFR".

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
    PRINT "Launch successful. Control released.".
}

DECLARE LOCAL FUNCTION ascend {
    PRINT "Utilizing MechJeb2 ascent assistance.".
    STAGE.
    HUDTEXT("IGNITION!", 1, 2, 15, GREEN, FALSE).
    PRINT "IGNITION!".

    // Deploy fairings at >68k, altitude.
    WAIT UNTIL ALT:RADAR > 68000.
    HUDTEXT("Fairing jettison.", 1, 2, 15, GREEN, FALSE).
    FOR p IN SHIP:PARTSTAGGED("main_fairing") {
        IF p:Modules:Contains("ModuleJettison") {
            LOCAL m IS p:GetModule("ModuleJettison").
            m:doAction("deploy", TRUE).
        }
    }
}

DECLARE LOCAL FUNCTION circularizeKerbin {
    WAIT UNTIL ADDONS:MJ:ASCENT:ENABLED = FALSE.
}

// DECLARE LOCAL FUNCTION executeManeuver {
//     DECLARE PARAMETER args.
//     LOCAL mnv IS NODE(args[0], args[1], args[2], args[3]).
// 
//     ADD(mnv).
//     LOCAL startTime IS calculateStartTime(mnv).
//     WAIT UNTIL startTime - 10.
//     lockSteeringAtManeuverTarget(mnv).
//     WAIT UNTIL startTime.
//     LOCK THROTTLE TO 1.
//     WAIT UNTIL isManeuverComplete(mnv).
//     LOCK THROTTLE TO 0.
//     REMOVE(mnv).
// }

DECLARE LOCAL FUNCTION planMunTransfer {

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