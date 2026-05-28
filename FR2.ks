// FR2 rockets are capable of delivering 500kg+ payloads to Kerbin system.
// Mission sortie:
//  1. Mun flyby
//  2. Kerbin CommNet
//  3. Beyond

@LAZYGLOBAL OFF.

DECLARE LOCAL FUNCTION main {
    init().
    waitForLaunch().
    startLaunch().
    ascend().
    circularize().
    endLaunch().
}

DECLARE LOCAL FUNCTION init {
    LOCAL libs IS LIST("lib/files.ks").
    FOR lib IN libs {
        LOCAL archivePath IS "0:/{0}":FORMAT(lib).
        LOCAL localPath IS "1:/{1}":FORMAT(lib).
        COPYPATH("0:/{0}":FORMAT(lib), "1:/{0}":FORMAT(lib)).
        PRINT "Copied {0} to {1}":FORMAT(archivePath, localPath). 
        RUNONCEPATH("1:/{0}:FORMAT(lib)").
        PRINT "Loaded {1}":FORMAT(localPath).
    }.
    printStorageStatus().

    // Initialize MechJeb
    SET MJ TO addons:MJ.
}

DECLARE LOCAL FUNCTION waitForLaunch {
    PRINT "Press ENTER to launch.".
    LOCAL ch is "".
    UNTIL ch = CHAR(13) {
        SET ch TO TERMINAL:INPUT:GETCHAR().
    }
    PRINT "LAUNCH STARTED. RELEASING SAFETIES. GODSPEED.".
}

DECLARE LOCAL FUNCTION startLaunch {
    LOCK THROTTLE to 1.
    STAGE.
    PRINT "IGNITION".
    executeManeuver(TIME:seconds + 30, 100, 100, 100).
}

DECLARE LOCAL FUNCTION endLaunch {
    LOCK THROTTLE to 0.
    PRINT "Launch successful. Control released.".
}

DECLARE LOCAL FUNCTION ascend {
}

DECLARE LOCAL FUNCTION circularize {
}

DECLARE LOCAL FUNCTION executeManeuver {
    PARAMETER args.
    LOCAL mnv IS NODE(args[0], args[1], args[2], args[3]).

    addManeuverToFlightPlan(mnv).
    LOCAL startTime IS calculateStartTime(mnv).
    WAIT UNTIL startTime - 10.
    lockSteeringAtManeuverTarget(mnv).
    WAIT UNTIL startTime.
    LOCK THROTTLE TO 1.
    WAIT UNTIL isManeuverComplete(mnv).
    LOCK THROTTLE TO 0.
    removeManeuverFromFlightPlan(mnv).
}

main().
