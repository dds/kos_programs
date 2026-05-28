// FR2 rockets are capable of delivering 500kg+ payloads to Kerbin system.
// Mission sortie:
//  1. Mun flyby
//  2. Kerbin CommNet
//  3. Beyond

@LAZYGLOBAL OFF.

DECLARE GLOBAL desiredAltitude IS 100000.
DECLARE GLOBAL desiredInclination IS 0.
DECLARE GLOBAL desiredHeading IS 90.
DECLARE GLOBAL fairingJettisonAltitude IS 68000.
DECLARE GLOBAL munInitialPeriapsis IS 20000.
DECLARE GLOBAL munTargetApoapsis IS 1800000.
DECLARE GLOBAL munTargetPeriapsis IS 1800000.

// Put this at the very top of FR2.ks
PARAMETER remoteCommand IS "default".
init().

IF remoteCommand = "default" {
    // If we run the file normally without parameters, do nothing here and let the script flow
}
ELSE IF remoteCommand = "transfer" {
    // Manually trigger the transfer function from inside program scope!
    init().
    ADD hohmannTransfer(Mun, munInitialPeriapsis).
    PRINT "Transfer node manually generated via Telnet!".
}
ELSE IF remoteCommand = "capture" {
    init().
    ADD planMunarCapture(munTargetApoapsis).
    PRINT "Capture node manually generated via Telnet!".
}
ELSE IF remoteCommand = "fairing" {
    init().
    deployMainFairing().
}

// Open and configure term
CORE:DOACTION("Open Terminal", TRUE).
SET TERMINAL:HEIGHT to 40.
SET TERMINAL:WIDTH to 80.

FUNCTION main {
    WAIT 2. // 2 seconds for everything to settle.

    // waitForLaunch().
    countdown(5).
    startLaunch().

    armBackgroundFairingTrigger().
    ascend().
    circularizeKerbin().
    endLaunch().

    LOCAL munTransfer IS hohmannTransfer(Mun, munInitialPeriapsis).
    ADD munTransfer.
    HUDTEXT("Mun Transfer Node Created", 1, 2, 15, WHITE, FALSE).
    executeManeuver(munTransfer).

    WAIT 1.
    warpToMunSOI().
    WAIT 1.
    
    LOCAL munCapture IS planMunarCapture(munTargetApoapsis).
    ADD munCapture.
    HUDTEXT("Mun Capture Node Created", 1, 2, 15, WHITE, FALSE).
    executeManeuver(munCapture).

    exit().
}

FUNCTION init {
    LOCAL libs IS LIST("lib/files.ks", "lib/countdown.ks", "lib/logs.ks").
    FOR lib IN libs {
        LOCAL archivePath IS "0:/{0}":FORMAT(lib).
        LOCAL localPath IS "1:/{0}":FORMAT(lib).
        COPYPATH("0:/{0}":FORMAT(lib), "1:/{0}":FORMAT(lib)).
        RUNONCEPATH("1:/{0}":FORMAT(lib)).
    }.
    printStorageStatus().

    mLog(" ").
    mLog("Initializing FR2.").

    // MechJeb2
    LOCAL mj IS ADDONS:MJ.
    LOCAL mjCore IS mj:CORE. 
    if mj:AVAILABLE {
        mLog("MechJeb is available.").
        LOCAL mjRunning IS "NOT running.".
        if mjCore:RUNNING {
            SET mjRunning TO "running.".
        }
        mLog("MechJeb core is " + mjRunning).
        // LOCAL planner IS ADDONS:MJ:PLANNER.
        // IF DEFINED(planner) {
        //     mLog("MechJeb Maneuver Planner is available.").
        // } else {
        //     mLog("MechJeb Maneuver Planner is NOT available.").
        // }

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
        mLog("WARNING: MechJeb reported as NOT AVAILABLE.").
    }
}

FUNCTION waitForLaunch {
    mLog("Engage autopilot then press ENTER to initiate countdown.").
    LOCAL ch is "".
    UNTIL ch = CHAR(13) {
        SET ch TO TERMINAL:INPUT:GETCHAR().
    }
}

FUNCTION myRoll {
    RETURN 360 - desiredHeading.
}

FUNCTION lockToPrograde {
    WAIT UNTIL (SHIP:AVAILABLETHRUST < MASS*CONSTANT:g0).
    mLog("Locking to prograde.").
    LOCK STEERING TO SRFPrograde + R(0, 0, myRoll()).
}

// FUNCTION deployPayload {
//     WAIT UNTIL ALTITUDE < deployAlt AND VERTICALSPEED < 0.
//     STAGE.
//     HUDTEXT("Deploying payload", 1, 2, 15, WHITE, FALSE).
//     mLog("Deploying payload.").
// }

FUNCTION startLaunch {
    mLog("Launch initiated.").
    STAGE.
    HUDTEXT("IGNITION!", 1, 2, 15, GREEN, FALSE).
    mLog("IGNITION!").
}

FUNCTION endLaunch {
    LOCK THROTTLE to 0.
    UNLOCK STEERING.
    HUDTEXT("Launch complete.", 1, 2, 15, WHITE, FALSE).
}

FUNCTION ascend {
    mLog("Utilizing MechJeb2 ascent assistance.").
}

FUNCTION armBackgroundFairingTrigger {
    // Sits in CPU memory and is constantly updated in the background.
    WHEN SHIP:Altitude >= fairingJettisonAltitude THEN {
        deployMainFairing().
    }
}

FUNCTION deployMainFairing {
    mLog("Deploying main fairing.").
    FOR p IN SHIP:PartsTagged("main_fairing") {
        mLog("  DEBUG: SEARCHING FOR FAIRING MODULE").
        FOR m_name IN p:MODULES {
            LOCAL m IS p:GETMODULE(m_name).
            PRINT "----- Module: " + m_name + " -----".
            PRINT "  Available Events: " + m:AllEventNames.
            PRINT "  Available Actions: " + m:AllActionNames.
        }
        mLog(" ").

        IF p:Modules:Contains("ModuleAirstreamFairing") {
            LOCAL m IS p:GetModule("ModuleAirstreamFairing").
            IF m:HASEVENT("jettison") {
                m:doEvent("jettison").
                HUDTEXT("Fairing jettison.", 1, 2, 15, GREEN, FALSE).
            } else {
                mLog("ERROR: Part tagged 'main_fairing' cannot be jettisoned.").
            }
        }
    }
}

FUNCTION circularizeKerbin {
    WAIT UNTIL ADDONS:MJ:ASCENT:ENABLED = FALSE.
}

FUNCTION executeManeuver {
    DECLARE PARAMETER t.

    LOCAL startTime IS calculateStartTime(t).
    WAIT UNTIL TIME:SECONDS >= (startTime - 10).
    HUDTEXT("Executing maneuver in T-10", 1, 2, 15, WHITE, FALSE).
    countdown(9).
    lockSteeringAtManeuverTarget(t).
    WAIT UNTIL TIME:SECONDS >= startTime.
    mLog("Executing maneuver").

    LOCAL burnIV IS t:BurnVector.
    UNTIL isManeuverComplete(t, burnIV) { 
        LOCAL engs IS LIST().
        LIST ENGINES in engs.
        LOCAL needsStage IS FALSE.

        FOR eng IN engs {
            IF eng:FLAMEOUT { SET needsStage TO TRUE. }
        }
        IF SHIP:MAXTHRUST = 0 { SET needsStage TO TRUE. }

        IF needsStage {
            HUDTEXT("Staging!", 2, 2, 15, YELLOW, FALSE).
            STAGE.
            WAIT 0.5.
        }
    
        LOCAL maxAcc IS SHIP:MAXTHRUST / SHIP:MASS.
        IF maxAcc > 0 {
            IF t:DeltaV:MAG < (maxAcc * 0.5) {
                LOCK THROTTLE TO MAX(0.01, t:DeltaV:MAG / maxAcc). // Precision.
            } ELSE { 
                LOCK THROTTLE TO 1.0. // Full power.
            }
        }

        WAIT 0.01.
    }

    // Clean up and shutdown.
    LOCK THROTTLE TO 0.
    UNLOCK STEERING.
    REMOVE t.
    HUDTEXT("Maneuver complete.", 1, 2, 15, GREEN, FALSE).
}

FUNCTION calculateStartTime {
    DECLARE PARAMETER t.

    LOCAL maxAcc IS SHIP:MAXTHRUST / SHIP:MASS.
    IF maxAcc = 0 {
        mLog("ERROR: No active engines or out of fuel!").
        RETURN TIME:SECONDS.
    }

    LOCAL burnDuration IS t:DeltaV:MAG / maxAcc.

    // Start the burn exactly halfway before the node time
    LOCAL startUt IS t:TIME - (burnDuration / 2).
    RETURN startUt.
}

FUNCTION lockSteeringAtManeuverTarget {
    PARAMETER t.

    mLog("Aligning spacecraft with burn vector.").
    LOCK STEERING TO t:BurnVector.

    // Wait until the alignment error is under 1 degree before prcoeeding
    UNTIL VANG(SHIP:Facing:ForeVector, t:BurnVector) < 1.0 {
        WAIT 0.1.
    }
    mLog("Alignment locked.").
}

FUNCTION isManeuverComplete {
    PARAMETER t.
    PARAMETER iv.

    // If the remaining dV drops below a strict physics threshold
    IF t:DeltaV:MAG < 0.05 {
        RETURN TRUE.
    }

    IF VDOT(iv, t:DeltaV) < 0 {
        RETURN TRUE.
    }

    RETURN FALSE.
}

FUNCTION hohmannTransfer {
    DECLARE PARAMETER targetBody.
    DECLARE PARAMETER targetPe.

    LOCAL r1 IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL r2 IS targetBody:ORBIT:SEMIMAJORAXIS.
    LOCAL mu IS BODY:MU.

    // 1. Semi-major axis and dV
    LOCAL targetRadius IS targetBody:RADIUS + targetPe.
    LOCAL aTrans IS (r1 + r2 + targetRadius) / 2.

    LOCAL v1 IS SQRT(mu / r1).
    LOCAL vTrans IS SQRT(mu * ((2 / r1) - (1 / aTrans))).
    LOCAL dV IS vTrans - v1.

    // 2. Phase angle
    LOCAL tTrans IS CONSTANT:PI * SQRT( (aTrans^3) / mu).
    LOCAL targetOmega IS 360 / targetBody:Orbit:Period.
    LOCAL idealPhase IS 180 - (targetOmega * tTrans). // Approx 111.5 degrees.

    // 3. Absolute position vectors
    LOCAL shipPos IS SHIP:Position - BODY:Position.
    LOCAL targetPos IS targetBody:Position - BODY:Position.


    // Calculate current phase angle using the angular vector distance.
    LOCAL currentPhase IS VANG(shipPos, targetPos).
    LOCAL orbitNormal IS VCRS(shipPos, SHIP:Velocity:Orbit).
    LOCAL phaseSign IS VDOT(orbitNormal, VCRS(shipPos, targetPos)).

    // If the sign is negative, the target is behind us; adjust to full 360 map.
    if phaseSign < 0 {
        SET currentPhase TO 360 - currentPhase.
    }

    // 4. Calculate the timing window.
    LOCAL shipOmega IS 360 / SHIP:ORBIT:PERIOD.
    LOCAL phaseSpeed IS shipOmega - targetOmega.
    
    LOCAL phaseDiff IS currentPhase - idealPhase.
    IF phaseDiff < 0 { SET phaseDiff TO phaseDiff + 360. }
    LOCAL estimatedTimeToBurn IS phaseDiff / phaseSpeed.

    // 5. Create a temporary node to fine-tune.
    LOCAL bestUt IS TIME:SECONDS + estimatedTimeToBurn.
    LOCAL testNode IS NODE(bestUt, 0, 0, dV).
    ADD testNode.
    WAIT 0.1. // Calculate the test path.

    // 6. Iterative fine-tuning loop to minimize PE
    LOCAL bestPe IS 999999999.
    LOCAL steps IS 10.

    // Run a 3-pass loop to progressively narrow down the exact second
    FROM { LOCAL pass IS 1. } UNTIL pass > 3 STEP { SET pass TO pass + 1. } DO {
        LOCAL scanning IS TRUE.

        UNTIL NOT scanning {
            // Test moving the burn earlier (subtracting time)
            SET testNode:Time TO testNode:Time - steps.
            WAIT 0.02.

            IF testNode:Orbit:HasNextPatch AND testNode:Orbit:NextPatch:Body:Name = targetBody:Name {
                LOCAL currentPe IS testNode:Orbit:NextPatch:Periapsis.

                // If it's improving and hasn't crashed into the surface,
                IF currentPe < bestPe AND currentPe > 0 {
                    SET bestPe TO currentPe.
                    SET bestUt TO testNode:Time.
                } ELSE {
                    // If it got worse, steps back and prepare to reduce steps size
                    SET testNode:Time TO testNode:Time + steps.
                    SET scanning TO FALSE.
                }
            } ELSE {
                // If we lost the encounter completely, revert the steps
                SET testNode:TIME to testNode:TIME + steps.
                SET scanning TO FALSE.
            }
        }
        SET steps TO steps / 5. // Drop from 10s stepss to 2s and so on.
    }

    // 5. Generate the node.
    REMOVE testNode.
    mLog("Ideal Mun transfer calculated!").
    PRINT "DeltaV Required: " + ROUND(dv, 1) + " m/s".
    return NODE(bestUt, 0, 0, dV).
}

FUNCTION warpToMunSOI {
    IF NOT (SHIP:Orbit:HasNextPatch) {
        mLog("ERROR: No planned Mun SOI transition found in current orbit.").
        RETURN.
    }

    LOCAL transUt IS TIME:SECONDS + SHIP:Orbit:NextPatchETA.
    LOCAL warpTargetUt IS transUt - 60.

    mLog("Warping to Mun SOI...").
    HUDTEXT("Warping to Mun SOI...", 1, 2, 15, YELLOW, FALSE).
    WARPTO(warpTargetUt).

    WAIT UNTIL KUNIVERSE:TimeWarp:Warp = 0.

    UNTIL SHIP:Body:Name = "Mun" {
        mLog("Waiting for SOI transition ...").
        WAIT 1.
    }
    RETURN.
}

FUNCTION planMunarCapture {
    PARAMETER targetApoapsis. // Target apoapsis height in meters (e.g., 20000)

    // 1. Safety Check: Verify we are in an active flyby (hyperbolic orbit)
    // Hyperbolic orbits have a negative semi-major axis in KSP physics
    IF SHIP:ORBIT:SEMIMAJORAXIS > 0 {
        PRINT "Warning: Vessel is already in a closed/captured orbit around " + SHIP:BODY:NAME.
    }

    // 2. Automatically discover parameters from the local SOI body
    LOCAL localBody IS SHIP:BODY.
    LOCAL mu        IS localBody:MU.
    LOCAL bodyRadius IS localBody:RADIUS.

    // 3. Define the geometry of the maneuver (Executed at true Periapsis)
    LOCAL rAtPe IS SHIP:ORBIT:PERIAPSIS + bodyRadius.
    
    // The target capture orbit will have its periapsis equal to our current approach Pe,
    // and its apoapsis equal to your specified parameter.
    LOCAL targetAp IS targetApoapsis + bodyRadius.
    LOCAL targetSMA IS (rAtPe + targetAp) / 2.

    // 4. Calculate Velocities using the Vis-Viva equation: v = sqrt( mu * (2/r - 1/a) )
    // Velocity right now when we reach the lowest point of the flyby:
    LOCAL vAtPe IS SQRT(mu * ( (2 / rAtPe) - (1 / SHIP:ORBIT:SEMIMAJORAXIS) )).
    
    // Desired velocity at periapsis to settle into the new elliptical/circular orbit:
    LOCAL vTarget IS SQRT(mu * ( (2 / rAtPe) - (1 / targetSMA) )).

    // 5. Calculate braking Delta-V (Will result in a negative/retrograde value)
    LOCAL captureDv IS vTarget - vAtPe.

    // 6. Locate the exact timestamp of execution
    LOCAL captureUt IS TIME:SECONDS + SHIP:ORBIT:PERIAPSIS:ETA.

    // 7. Generate and return the maneuver node
    // Format: NODE(universal_time, radial, normal, prograde)
    LOCAL captureNode IS NODE(captureUt, 0, 0, captureDv).
    
    PRINT "Capture maneuver calculated for " + localBody:NAME.
    PRINT " -> Target Apoapsis: " + ROUND(targetApoapsis / 1000, 1) + " km".
    PRINT " -> Required Delta-V: " + ROUND(ABS(captureDv), 1) + " m/s retrograde".

    RETURN captureNode.
}

FUNCTION exit {
}
