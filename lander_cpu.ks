// ============================================================
// lander_cpu.ks  —  Secondary CPU role: deploy + science
// ============================================================

GLOBAL CFG IS LEXICON().

GLOBAL LIBS IS LIST("phases", "science", "orbit").

GLOBAL FUNCTION main {
    LOCAL seq IS LIST("MONITOR", "DEPLOY", "SCIENCE", "DONE").
    SET launchSeq TO seq.
    IF stateGet("phase", "") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "MONITOR", _phaseMonitor@,
        "DEPLOY",  _phaseDeploy@,
        "SCIENCE", _phaseScience@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phaseMonitor {
    mLogPhase("MONITOR — waiting for landing").

    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        mLog("Already on surface.").
        nextPhase(launchSeq).
        RETURN.
    }

    // 1. SLEEP completely until we are actually dropping out of orbit
    IF SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING" {
        mLog("Coasting in orbit. Core hibernating...").
        WAIT UNTIL SHIP:STATUS <> "ORBITING" AND SHIP:STATUS <> "ESCAPING".
    }

    // 2. Now that we are descending, wait for the deployment ceiling safely
    LOCAL hasAtmo IS SHIP:BODY:ATM:EXISTS.
    mLog("Descent detected. Monitoring altitude for hardware deploy.").
    
    IF hasAtmo {
        WAIT UNTIL SHIP:AIRSPEED < 100 AND ALT:RADAR < 20000.
    } ELSE {
        WAIT UNTIL SHIP:ALTITUDE < 20000.
    }
    _deployAntennas().

    // 3. Wait for the parachute deployment window
    IF hasAtmo {
        mLog("Waiting for safe parachute deployment window...").
        WAIT UNTIL SHIP:ALTITUDE > 4000 AND SHIP:ALTITUDE < 8000
               AND SHIP:VELOCITY:SURFACE:MAG > 40 AND SHIP:VELOCITY:SURFACE:MAG < 130.
        _stageChutes().
    }

    // 4. Wait for final touchdown
    WAIT UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    mLog("Surface contact confirmed.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseDeploy {
    mLogPhase("DEPLOY — extending hardware").
    IF SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING" {
        mLog("Still in orbit — waiting for descent.").
        WAIT UNTIL SHIP:STATUS <> "ORBITING" AND SHIP:STATUS <> "ESCAPING".
    }
    _deployAntennas().
    _deploySolarPanels().
    mLog("Deploy complete.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseScience {
    mLogPhase("SCIENCE — collecting data").
    IF SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING" {
        mLog("Still in orbit — waiting for descent.").
        WAIT UNTIL SHIP:STATUS <> "ORBITING" AND SHIP:STATUS <> "ESCAPING".
    }
    scienceInit().
    scienceRunAll().
    mLog("Initial science collected. Entering idle monitor.").

    LOCAL ecCapacity IS 0.
    
    FOR res IN SHIP:RESOURCES {
        IF res:NAME = "ELECTRICCHARGE" {
            SET ecCapacity TO res:CAPACITY.
            BREAK. // Found it, no need to keep looping
        }
    }
    
    // Now you can safely use ecCapacity in your logic
    IF ecCapacity > 0 {
        LOCAL ecPercent IS (SHIP:ELECTRICCHARGE / ecCapacity) * 100.
        mLog("Battery status: " + ROUND(ecPercent, 1) + "%").
    }
}

LOCAL FUNCTION _deployAntennas {
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            p:GETMODULE("ModuleDeployableAntenna"):DOACTION("extend antenna", TRUE).
        }
        IF p:HASMODULE("ModuleDataTransmitter") {
            LOCAL m IS p:GETMODULE("ModuleDataTransmitter").
            IF m:HASFIELD("require complete") {
                m:SETFIELD("require complete", FALSE).
            }
        }
    }
}

LOCAL FUNCTION _stageChutes {
    mLog("Staging chute at " + ROUND(SHIP:ALTITUDE) + "m, " + ROUND(SHIP:VELOCITY:SURFACE:MAG) + "m/s.").
    STAGE.
}

LOCAL FUNCTION _deploySolarPanels {
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            p:GETMODULE("ModuleDeployableSolarPanel"):DOACTION("extend solar panel", TRUE).
        }
    }
}
