// Persistent assist intent and terminal handoff. No optimizer in this file.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION assistFlightIdle {
    RETURN NOT ABORT AND NOT maneuverBurnInterrupted()
        AND (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING" OR SHIP:STATUS = "SUB_ORBITAL")
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

GLOBAL FUNCTION assistFlightBound {
    PARAMETER flight.
    RETURN flight["mission"] = stateGet("mission_id","")
        AND flight["launch"] = stateGetNum("launch_time",0)
        AND flight["vehicle"] = stateGet("vehicle","").
}

GLOBAL FUNCTION assistFlightHold {
    PARAMETER reason.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    LOCAL flight IS stateGet("assist_flight",LEXICON()).
    IF flight:LENGTH > 0 AND assistFlightBound(flight) AND ADDONS:KAC:AVAILABLE {
        FOR key IN LIST("alarm","peAlarm") {
            IF flight:HASKEY(key) {
                IF flight[key] <> "" { DELETEALARM(flight[key]). }
            }
        }
    }
    mLogError("STATS assist mission decision=hold reason=" + reason
        + " body=" + SHIP:BODY:NAME + " resident=False").
    PRINT "ASSIST HELD: " + reason + "; flight intent and remaining node retained.".
    yieldToPrompt().
}

GLOBAL FUNCTION assistFlightScience {
    IF MISSION_ASSIST_SCIENCE > 0 AND WARP = 0 {
        IF SCIENCE_ENTRY_BANDS:HASKEY(SHIP:BODY:NAME) {
            scienceFlightPulse(scienceEntryContext(),shipPowerFraction() >= SCIENCE_ENTRY_MIN_EC).
        }
    }
}

// Freeze only serializable mission intent; never store native nodes/patches.
GLOBAL FUNCTION assistFlightStore {
    PARAMETER flight.
    PARAMETER status.
    SET flight TO flight:COPY.
    SET flight["status"] TO status.
    stateSet("assist_flight",flight).
    RETURN flight.
}

GLOBAL FUNCTION assistFlightNodeMatches {
    PARAMETER flight.
    IF NOT HASNODE OR NOT flight:HASKEY("node") { RETURN FALSE. }
    LOCAL saved IS flight["node"].
    RETURN ALLNODES:CONTAINS(NEXTNODE) AND saved["body"] = SHIP:BODY:NAME
        AND ABS(NEXTNODE:TIME-saved["ut"]) < 0.1
        AND ABS(NEXTNODE:PROGRADE-saved["pro"]) < 0.001
        AND ABS(NEXTNODE:RADIALOUT-saved["rad"]) < 0.001
        AND ABS(NEXTNODE:NORMAL-saved["normal"]) < 0.001.
}

// Build the alternate continuation without changing the selected profile id.
// In particular, an Ike success must not reload the archive's launch profile.
GLOBAL FUNCTION assistContinuationSettings {
    LOCAL values IS MISSION_ASSIST_SETTINGS:COPY.
    LOCAL route IS MISSION_ASSIST_ROUTE.
    LOCAL goal IS route[route:LENGTH-1].
    LOCAL mode IS assistGoalMode(route).
    LOCAL firstPhase IS "CAPTURE".
    IF mode = "ENTRY" { SET firstPhase TO "SCIENCE_ENTRY". }
    LOCAL tail IS LIST().
    LOCAL found IS FALSE.
    FOR phaseName IN MISSION_ASSIST_SEQUENCE {
        IF phaseName = firstPhase { SET found TO TRUE. }
        IF found {
            IF bootLibBandForPhase(phaseName,"") = "" OR tail:CONTAINS(phaseName) { RETURN LEXICON(). }
            tail:ADD(phaseName).
        }
    }
    IF tail:LENGTH = 0 OR NOT values:HASKEY("CAPTURE_PE") { RETURN LEXICON(). }
    IF mode = "ORBIT" {
        FOR key IN LIST("TARGET_AP","CAPTURE_MIN_PE","CAPTURE_MAX_PE","CAPTURE_INC") {
            IF NOT values:HASKEY(key) { RETURN LEXICON(). }
        }
        IF values["TARGET_AP"] <> goal["AP"] OR NOT goal:HASKEY("MAX_PE") { RETURN LEXICON(). }
        IF values:HASKEY("CAPTURE_RESERVE_DV") {
            IF ASSIST_RESERVE_DV < values["CAPTURE_RESERVE_DV"] { RETURN LEXICON(). }
        }
        IF NOT (goal["MIN_PE"] >= values["CAPTURE_MIN_PE"] AND goal["MAX_PE"] <= values["CAPTURE_MAX_PE"]) { RETURN LEXICON(). }
        IF values["CAPTURE_INC"] >= 0 {
            IF NOT goal:HASKEY("INC") OR NOT goal:HASKEY("INC_TOL")
                    OR NOT values:HASKEY("BPLANE_ANG_TOL") { RETURN LEXICON(). }
            IF goal["INC"] <> values["CAPTURE_INC"]
                    OR NOT (goal["INC_TOL"] > 0 AND goal["INC_TOL"] <= values["BPLANE_ANG_TOL"]) { RETURN LEXICON(). }
        }
        // The present native-route validator proves inclination, not a full
        // requested LAN/AoP. Do not quietly waive a later mission's contract.
        FOR key IN LIST("CAPTURE_LAN","CAPTURE_AOP") {
            IF values:HASKEY(key) {
                IF values[key] >= 0 { RETURN LEXICON(). }
            }
        }
    } ELSE {
        IF NOT values:HASKEY("BPLANE_PE_TOL") { RETURN LEXICON(). }
        IF goal["MIN_PE"] < values["CAPTURE_PE"]-values["BPLANE_PE_TOL"]
                OR goal["MAX_PE"] > values["CAPTURE_PE"]+values["BPLANE_PE_TOL"] { RETURN LEXICON(). }
    }
    IF NOT (values["CAPTURE_PE"] >= goal["MIN_PE"] AND values["CAPTURE_PE"] <= goal["MAX_PE"]) { RETURN LEXICON(). }
    // When the terminal body is the current mission's own arrival target,
    // runtime operator policy still wins over the optional profile branch.
    IF goal["BODY"] = getTarget() {
        IF values["CAPTURE_PE"] <> CAPTURE_PE { RETURN LEXICON(). }
        IF CAPTURE_LAN >= 0 OR CAPTURE_AOP >= 0 { RETURN LEXICON(). }
        IF mode = "ORBIT" {
            IF TARGET_AP <> goal["AP"] OR CAPTURE_INC <> values["CAPTURE_INC"]
                    OR NOT (goal["MIN_PE"] >= CAPTURE_MIN_PE AND goal["MAX_PE"] <= CAPTURE_MAX_PE)
                    OR ASSIST_RESERVE_DV < CAPTURE_RESERVE_DV { RETURN LEXICON(). }
            IF CAPTURE_INC >= 0 {
                IF goal["INC_TOL"] > BPLANE_ANG_TOL { RETURN LEXICON(). }
            }
        } ELSE IF NOT (goal["MIN_PE"] >= CAPTURE_PE-BPLANE_PE_TOL
                AND goal["MAX_PE"] <= CAPTURE_PE+BPLANE_PE_TOL) { RETURN LEXICON(). }
    }
    IF values:HASKEY("MISSION_ID") { values:REMOVE("MISSION_ID"). }
    SET values["TARGET_"] TO goal["BODY"].
    SET values["SEQUENCE"] TO tail.
    SET values["BPLANE_ARRIVAL_MODE"] TO mode.
    SET values["MISSION_ASSIST_ROUTE"] TO LIST().
    SET values["MISSION_ASSIST_SEQUENCE"] TO LIST().
    SET values["MISSION_ASSIST_SETTINGS"] TO LEXICON().
    SET values["MISSION_CACHE_HANDOFF_PHASES"] TO LIST().
    RETURN values.
}

GLOBAL FUNCTION assistFlightAffordable {
    PARAMETER flight.
    PARAMETER evidence.
    IF NOT evidence["OK"] { RETURN FALSE. }
    LOCAL fuel IS SHIP:DELTAV:VACUUM.
    LOCAL reserve IS flight["reserve"].
    IF NOT (fuel >= 0 AND fuel < 1e30 AND reserve >= 0 AND reserve < 1e30
            AND evidence["COST"] >= 0 AND evidence["COST"]+reserve <= fuel) { RETURN FALSE. }
    LOCAL duration IS 0.
    IF evidence["CAPTURE_DV"] > 0 { SET duration TO arrivalBurnSeconds(evidence["CAPTURE_DV"]). }
    IF NOT (duration >= 0 AND duration < 1e30) { RETURN FALSE. }
    LOCAL goal IS evidence["LEGS"][evidence["LEGS"]:LENGTH-1].
    // Reserve an offline band reboot, alignment and the centered capture.
    RETURN goal["PE_UT"]-MAX(TIME:SECONDS,goal["ENTRY"]) > 300+duration/2.
}

GLOBAL FUNCTION assistFlightHandoff {
    PARAMETER flight.
    IF NOT assistFlightIdle() OR HASNODE { assistFlightHold("unsafe-terminal-handoff"). RETURN. }
    LOCAL values IS flight["settings"].
    LOCAL firstPhase IS values["SEQUENCE"][0].
    SET flight TO assistFlightStore(flight,"handoff").
    missionOverrideUpdate(values).
    stateSet("target",values["TARGET_"]).
    stateSaveReloadState("ASSIST_TERMINAL",firstPhase,bootLibBandForPhase(firstPhase,"")).
    mLogSummary("STATS assist mission decision=handoff target=" + values["TARGET_"]
        + " phase=" + firstPhase + " flybys=" + flight["index"]).
    // The next phase is already durable; release the now-consumed route
    // and settings snapshot before loading heavier terminal operations.
    stateRemove("assist_flight").
    // Overrides are applied before library planning on the next boot. Keep
    // the original profile id; terminal operations retain their own settings.
    REBOOT.
}
