// SHRIMP booster surface temp and barometric reading script.

IF EXISTS("0:/lib/files.ks") {
    COPYPATH("0:/lib/files.ks", "1:/lib/files.ks").
    RUNONCEPATH("1:/lib/files.ks").
}

printStorageStatus().

PRINT " ".
PRINT "X_SHOT flight computer initialized. LFG.".
PRINT "Press ENTER to launch.".

LOCAL ch is "".
UNTIL ch = CHAR(13) {
    SET ch TO TERMINAL:INPUT:GETCHAR().
}

PRINT " ".
PRINT "Confirmation received!".
PRINT "Initiating launch. Good luck.".
WAIT 1.

// 1. Countdown function with beeps.
FUNCTION countdown {
    PARAMETER countStart.

    PRINT "Starting countdown.".
    SET beepVoice to GETVOICE(0).
    FROM {local i is countStart.} UNTIL i = 0 STEP {set i to i - 1.} DO {
        PRINT "T-minus " + i.
        // Play a quick 440Hz (A4) beep for 0.1 seconds
        HUDTEXT("T-minus " + i, 1, 2, 15, WHITE, FALSE).
        beepVoice:PLAY(NOTE(440, 0.1)).
        WAIT 1.
    }
    PRINT "LIFTOFF!".
    beepVoice:PLAY(NOTE(880, 0.4)). // Higher pitch beep for launch
} 

// 2. Execute countdown andlaunch.
countdown(3).
STAGE.
WAIT 1.

LOCAL targetApo IS 100000.

UNTIL SHIP:APOAPSIS > targetApo {
    IF MAXTHRUST = 0 {
        PRINT "Staging.".
        STAGE.

        WAIT 1.
    }

    WAIT 0.1.
}

WAIT UNTIL SHIP:MAXTHRUST = 0.

// Stage chutes / recovery systems.
PRINT "Staging/Deploying recovery systems.".
STAGE.

// Take a thermometer reading when flying low.
WAIT UNTIL ALT:RADAR <= 200.
PRINT "Reached 200m. Taking tamperature reading.".

FOR p IN SHIP:PARTS {
    IF p:NAME:CONTAINS("sensorThermometer") {
        // Grab the science module from the part
        LOCAL sciMod is p:GETMODULE("ModuleScienceExperiment").

        IF sciMod:INOPERABLE AND NOT sciMod:HASDATA {
            sciMod:DEPLOY().
            PRINT "Thermometer deployed.".

            when sciMod:HASDATA THEN {
                PRINT "Temperature ata collected. Transmitting to KSC.".
                sciMod:TRANSMIT().

                RETURN FALSE.
            }
        }
          
    }
}

PRINT "Waiting for touchdown.".
WAIT UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
PRINT "Safe touchdown confirmed!".

// Take Science Readings
PRINT "Collecting scientific data.".

// Find and trigger the thermometer and barometer.
FOR p IN SHIP:PARTS {
    IF p:NAME:CONTAINS("sensorThermometer") OR p:NAME:CONTAINS("sensorBarometer") {
        // Grab the science module from the part
        LOCAL sciMod is p:GETMODULE("ModuleScienceExperiment").

        // Safey checks to prevet the script from crashing
        IF sciMod:INOPERABLE {
            PRINT "{0} is broken or inoperable.":FORMAT(p:TITLE).
        }  else IF sciMod:HASDATA {
            PRINT "{0} already contains data.":FORMAT(p:TITLE).
        } else {
            sciMod:DEPLOY().
            PRINT "{0} data logged successfully.":FORMAT(p:TITLE).
        }   
    }
}

PRINT "Mission complete. Control released. Fly safe.".
