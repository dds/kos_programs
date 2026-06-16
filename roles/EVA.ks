// ============================================================
// EVA.ks  —  EVA kerbal controller  (0:/roles/EVA.ks)
// ============================================================

GLOBAL FUNCTION bootVehicleLibs {
    RETURN missionLibs(LIST("science", "orbit")).
}

GLOBAL FUNCTION main {
    LOCAL crew IS SHIP:CREWMEMBERS.
    LOCAL trait IS "GENERIC".
    LOCAL kName IS SHIP:NAME.
    IF crew:LENGTH > 0 {
        SET trait TO crew[0]:TRAIT.
        SET kName TO crew[0]:NAME.
    }

    mLogPhase("EVA " + trait).
    mLog("Kerbal: " + kName + "  Trait: " + trait).

    IF trait = "SCIENTIST" { _runScientist(). }
    ELSE IF trait = "ENGINEER" { _runEngineer(). }
    ELSE { _runGeneric(). }
}

LOCAL FUNCTION _runScientist {
    scienceInit().
    scienceRunAll().
    scienceTransmitAll().
    mLog("Science collected. Monitoring for biome changes.").
    stateSet("phase", "EVA_SCIENCE").
    HUDTEXT("Scientist EVA — science active", 5, 2, 14, CYAN, FALSE).
    WAIT UNTIL FALSE.
}

LOCAL FUNCTION _runEngineer {
    mLog("Engineer EVA ready.").
    stateSet("phase", "EVA_ENGINEER").
    HUDTEXT("Engineer EVA — ready", 5, 2, 14, YELLOW, FALSE).
    WAIT UNTIL FALSE.
}

LOCAL FUNCTION _runGeneric {
    mLog("Generic EVA active.").
    stateSet("phase", "EVA_GENERIC").
    HUDTEXT("EVA active", 5, 2, 14, WHITE, FALSE).
    WAIT UNTIL FALSE.
}
