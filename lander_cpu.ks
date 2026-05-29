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

    LOCAL hasAtmo IS SHIP:BODY:ATM:EXISTS.
    WHEN (hasAtmo AND SHIP:AIRSPEED < 100 AND ALT:RADAR < 20000)
        OR (NOT hasAtmo AND SHIP:ALTITUDE < 20000) THEN {
        _deployAntennas().
    }

    LOCAL chuteFired IS FALSE.
    WHEN NOT chuteFired AND SHIP:ALTITUDE > 4000 AND SHIP:ALTITUDE < 8000
        AND SHIP:VELOCITY:SURFACE:MAG > 40 AND SHIP:VELOCITY:SURFACE:MAG < 130 THEN {
        _stageChutes().
        SET chuteFired TO TRUE.
    }

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

    UNTIL FALSE {
        LOCAL battLevel IS SHIP:ELECTRICCHARGE / MAX(1, SHIP:ELECTRICCHARGECAPACITY).
        LOCAL hasComm IS ADDONS:RT:HASKSCCONNECTION(SHIP)
            OR SHIP:CONNECTION:ISCONNECTED.
        mLog("Idle: batt=" + ROUND(battLevel * 100, 1) + "% comms=" + hasComm).
        WAIT 300.
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
