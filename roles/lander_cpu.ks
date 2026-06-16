// ============================================================
// lander_cpu.ks  —  Secondary CPU role: deploy + science  (0:/roles/lander_cpu.ks)
// ============================================================

LOCAL roleSeq IS LIST("DESCEND", "LANDED", "DONE").
GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs().
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN missionLibs(missionLibsForPhases(roleSeq)).
}

GLOBAL FUNCTION main {
    LOCAL seq IS roleSeq.
    SET launchSeq TO seq.
    IF stateGet("phase", "") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "DESCEND", _phaseDescend@,
        "LANDED",  _phaseLanded@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phaseDescend {
    mLogPhase("DESCEND — orbit to surface").

    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        mLog("Already on surface.").
        nextPhase(launchSeq).
        RETURN.
    }
    // SHIP:STATUS<> "FLYING" AND SHIP:STATUS <> "SUB_ORBITAL" AND 
    IF SHIP:STATUS <> "ORBITING" AND SHIP:STATUS <> "ESCAPING" {
        mLog("Waiting for orbit (status=" + SHIP:STATUS + ").").
        WAIT UNTIL SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING".
    }

    mLog("In orbit — waiting for descent.").
    WAIT UNTIL SHIP:STATUS <> "ORBITING" AND SHIP:STATUS <> "ESCAPING".

    mLog("Descent detected. Starting science + deploy monitoring.").
    LOCAL hasAtmo IS SHIP:BODY:ATM:EXISTS.
    LOCAL antennasDeployed IS FALSE.
    LOCAL chuteStaged IS FALSE.
    LOCAL scienceStarted IS FALSE.

    scienceInit().
    SET scienceStarted TO TRUE.
    mLog("Science active during descent.").

    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        IF hasAtmo AND NOT chuteStaged
            AND SHIP:ALTITUDE > 10
            AND SHIP:VELOCITY:SURFACE:MAG > 10 {
            _stageChutes().
            SET chuteStaged TO TRUE.
        }

        IF NOT antennasDeployed AND SHIP:ALTITUDE < 20000 {
            _deployAntennas().
            SET antennasDeployed TO TRUE.
        }

        IF scienceStarted {
            scienceRunAll().
        }

        WAIT 0.5.
    }

    mLog("Surface contact confirmed.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseLanded {
    mLogPhase("LANDED — post-landing ops").
    _deployAntennas().
    _deploySolarPanels().
    scienceRunAll().
    scienceTransmitAll().
    mLog("Landed ops complete. Idle.").
    nextPhase(launchSeq).
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
