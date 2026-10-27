// survey_hardware.ks - Read-only preflight for retained temperature data.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION surveyHardwareReady {
    PARAMETER required.
    LOCAL emptyCount IS 0.
    LOCAL containers IS 0.
    FOR part IN SHIP:PARTS {
        IF part:DECOUPLEDIN = CORE:PART:DECOUPLEDIN {
            IF part:NAME = "sensorThermometer" AND part:HASMODULE("ModuleScienceExperiment") {
                LOCAL experiment IS part:GETMODULE("ModuleScienceExperiment").
                IF NOT experiment:INOPERABLE AND experiment:RERUNNABLE AND NOT experiment:HASDATA {
                    SET emptyCount TO emptyCount+1.
                }
            }
            IF part:HASMODULE("ModuleScienceContainer") { SET containers TO containers+1. }
        }
    }
    mLog("STATS survey-hardware emptyThermometers=" + emptyCount
        + " retainedContainers=" + containers + " sites=" + required).
    RETURN emptyCount >= required OR (emptyCount > 0 AND containers > 0).
}
