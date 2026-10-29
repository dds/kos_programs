// ============================================================
// science_flight.ks — nonblocking stock/DMagic flight science
// (0:/lib/science_flight.ks). Loaded only by SCIENCE_ENTRY.
// TRANSMIT queues and removes data in native kOS; it is NOT an R&D receipt.
// ============================================================
@LAZYGLOBAL OFF.

LOCAL _scienceFlightDeployAfter IS LEXICON().
LOCAL _scienceFlightTransmitAfter IS LEXICON().

LOCAL FUNCTION _scienceFlightStep {
    PARAMETER experiment.
    PARAMETER instrumentId.
    PARAMETER context.
    PARAMETER canTransmit.
    IF ABORT { RETURN. }
    LOCAL sampled IS stateGet("science_flight_samples",LEXICON()).
    LOCAL pending IS stateGet("science_flight_pending",LEXICON()).
    IF experiment:HASDATA {
        // Only actual data records an observation. A deploy request alone
        // never marks the context done, including across a reboot.
        IF pending:HASKEY(instrumentId) AND experiment:DATA:LENGTH > 0 {
            SET sampled TO sampled:COPY.
            SET sampled[instrumentId] TO pending[instrumentId].
            stateSet("science_flight_samples",sampled).
            SET pending TO pending:COPY.
            pending:REMOVE(instrumentId).
            stateSet("science_flight_pending",pending).
            FOR datum IN experiment:DATA {
                mLog("STATS science-flight observed instrument=" + instrumentId
                    + " title=" + datum:TITLE + " transmitValue=" + datum:TRANSMITVALUE).
            }
        }
        IF NOT canTransmit OR NOT HOMECONNECTION:ISCONNECTED { RETURN. }
        IF _scienceFlightTransmitAfter:HASKEY(instrumentId) {
            IF TIME:SECONDS < _scienceFlightTransmitAfter[instrumentId] { RETURN. }
        }
        SET _scienceFlightTransmitAfter[instrumentId] TO TIME:SECONDS+30.
        mLog("STATS science-flight transmit-request instrument=" + instrumentId
            + " records=" + experiment:DATA:LENGTH + " deliveryConfirmed=False").
        experiment:TRANSMIT().
        // Do not reset/dump/collect the experiment after transmission. Native
        // code owns the queue; disappearance of data does not prove delivery.
        RETURN.
    }
    IF experiment:INOPERABLE { RETURN. }
    IF sampled:HASKEY(instrumentId) {
        IF sampled[instrumentId] = context { RETURN. }
    }
    // An animated/resource-consuming experiment may still be gathering.
    // Changing biome or reaching the retry clock is not permission to cancel
    // it. Retry unavailable, undeployed requests; let deployed requests finish.
    IF experiment:DEPLOYED AND pending:HASKEY(instrumentId) { RETURN. }
    IF _scienceFlightDeployAfter:HASKEY(instrumentId) {
        IF TIME:SECONDS < _scienceFlightDeployAfter[instrumentId] { RETURN. }
    }
    SET _scienceFlightDeployAfter[instrumentId] TO TIME:SECONDS+10.
    IF experiment:DEPLOYED {
        IF NOT experiment:RERUNNABLE { RETURN. }
        // Recheck immediately before a reset; never overwrite retained data.
        IF experiment:HASDATA { RETURN. }
        experiment:RESET().
    }
    IF experiment:DEPLOYED OR experiment:HASDATA OR experiment:INOPERABLE { RETURN. }
    SET pending TO pending:COPY.
    SET pending[instrumentId] TO context.
    stateSet("science_flight_pending",pending).
    experiment:DEPLOY().
    mLog("STATS science-flight deploy-request instrument=" + instrumentId + " context=" + context).
}

GLOBAL FUNCTION scienceFlightPulse {
    PARAMETER context.
    PARAMETER canTransmit.
    // Enumerate modules by index: a part may carry several experiments.
    // kOS's typed API supports stock and selected DMagic modules; unsupported
    // modules (SCANsat, etc.) are left alone rather than guessing event names.
    FOR part IN SHIP:PARTS {
        LOCAL index IS 0.
        UNTIL index >= part:MODULES:LENGTH OR ABORT {
            LOCAL experiment IS part:GETMODULEBYINDEX(index).
            IF experiment:ISTYPE("ScienceExperimentModule") {
                _scienceFlightStep(experiment,part:UID+":"+index,context,canTransmit).
            }
            SET index TO index+1.
        }
    }
}
