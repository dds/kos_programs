// Generic ordered encounter traversal; optimizer is absent from this band.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _assistClearArrivedSoi {
    IF stateGet("soi_alarm_target","") <> SHIP:BODY:NAME { RETURN. }
    LOCAL alarm IS stateGet("soi_alarm_id","").
    IF alarm <> "" AND ADDONS:KAC:AVAILABLE { DELETEALARM(alarm). }
    FOR key IN LIST("soi_alarm_id","soi_alarm_target","soi_alarm_ut") { stateRemove(key). }
}

LOCAL FUNCTION _assistWait {
    PARAMETER wakeUt.
    LOCAL coastBody IS SHIP:BODY.
    // Critical seconds use an ordinary 1x clock wait. Do not create a new
    // alarm/solar search/log row each second around Pe or an SOI boundary.
    IF wakeUt-TIME:SECONDS <= 60 {
        SET WARP TO 0.
        WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
        UNTIL NOT assistFlightIdle() OR HASNODE OR TIME:SECONDS >= wakeUt OR SHIP:BODY <> coastBody {
            assistFlightScience().
            WAIT MIN(1,MAX(0.01,wakeUt-TIME:SECONDS)).
        }
        RETURN.
    }
    LOCAL alarm IS kacEnsureAlarm("Assist encounter wake",wakeUt,
        "Running assist coast resumes at the next encounter checkpoint.",1).
    LOCAL flight IS stateGet("assist_flight",LEXICON()):COPY.
    SET flight["alarm"] TO alarm.
    stateSet("assist_flight",flight).
    mLogSummary("STATS assist coast wakeUt=" + wakeUt + " alarm=" + alarm
        + " index=" + flight["index"] + " body=" + coastBody:NAME + " resident=True").
    LOCAL solarRef IS enterSolarCoast("Assist coast",TRUE,TRUE,wakeUt).
    IF assistFlightIdle() AND NOT HASNODE AND TIME:SECONDS < wakeUt
            AND SHIP:BODY = coastBody AND alarm <> "" AND solarCoastCanWarp(solarRef,"Assist coast") {
        coastAutoWarp(wakeUt,"Assist coast",alarm).
    }
    UNTIL NOT assistFlightIdle() OR HASNODE OR TIME:SECONDS >= wakeUt OR SHIP:BODY <> coastBody {
        assistFlightScience().
        SET solarRef TO trySolarHoldTick(solarRef,wakeUt).
        IF TIME:SECONDS >= wakeUt { BREAK. }
        WAIT MIN(5,MAX(0.1,wakeUt-TIME:SECONDS)).
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF alarm <> "" AND ADDONS:KAC:AVAILABLE { DELETEALARM(alarm). }
    SET flight TO stateGet("assist_flight",LEXICON()):COPY.
    SET flight["alarm"] TO "".
    stateSet("assist_flight",flight).
}

GLOBAL FUNCTION phaseAssistCoast {
    LOCAL flight IS stateGet("assist_flight",LEXICON()).
    IF flight:LENGTH = 0 { nextPhase(xferSeq). RETURN. }
    IF NOT assistFlightBound(flight) { assistFlightHold("saved-flight-mismatch"). RETURN. }
    IF flight["status"] <> "coast" AND flight["status"] <> "handoff" {
        assistFlightHold("unfinished-assist-plan"). RETURN.
    }
    IF flight["alarm"] <> "" AND ADDONS:KAC:AVAILABLE { DELETEALARM(flight["alarm"]). }
    SET flight TO flight:COPY.
    SET flight["alarm"] TO "".
    stateSet("assist_flight",flight).
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    LOCAL route IS flight["route"].
    LOCAL bodies IS assistRouteBodies(route).
    IF bodies:LENGTH <> route:LENGTH { assistFlightHold("saved-route-invalid"). RETURN. }
    UNTIL ABORT {
        SET flight TO stateGet("assist_flight",LEXICON()).
        IF NOT assistFlightIdle() OR HASNODE { assistFlightHold("coast-controls-or-node"). RETURN. }
        _assistClearArrivedSoi().
        assistFlightScience().
        LOCAL index IS flight["index"].
        IF NOT (index >= 0 AND index < route:LENGTH) { assistFlightHold("invalid-leg-index"). RETURN. }
        LOCAL consumedCurrent IS FALSE.
        IF flight:HASKEY("lastPeUt") AND flight["lastBody"] = SHIP:BODY:NAME {
            SET consumedCurrent TO ABS(TIME:SECONDS+SHIP:ORBIT:ETA:PERIAPSIS-flight["lastPeUt"]) < 1.
        }
        IF SHIP:BODY = bodies[index] AND index < route:LENGTH-1 AND NOT consumedCurrent {
            LOCAL patch IS SHIP:ORBIT.
            IF NOT assistLegClear(patch,route[index]) OR NOT (patch:ECCENTRICITY > 1)
                    OR NOT patch:HASNEXTPATCH { assistFlightHold("unsafe-live-flyby"). RETURN. }
            LOCAL peEta IS patch:ETA:PERIAPSIS.
            IF peEta <= 0 AND peEta > -1e30 {
                SET flight TO flight:COPY.
                IF flight["peAlarm"] <> "" AND ADDONS:KAC:AVAILABLE { DELETEALARM(flight["peAlarm"]). }
                SET flight["peAlarm"] TO "".
                SET flight["index"] TO index+1.
                SET flight["lastBody"] TO SHIP:BODY:NAME.
                SET flight["lastPeUt"] TO TIME:SECONDS+peEta.
                SET consumedCurrent TO TRUE.
                stateSet("assist_flight",flight).
                mLogSummary("STATS assist flyby completed index=" + index
                    + " body=" + SHIP:BODY:NAME + " Pe=" + patch:PERIAPSIS).
                // Repeated bodies are ordered by index; continue from the
                // actual outgoing patch, never count an unobserved encounter.
                SET index TO index+1.
            }
        }
        LOCAL evidence IS assistEvaluate(0,route,bodies,index,flight["lastBody"]).
        IF NOT assistFlightAffordable(flight,evidence) { assistFlightHold("remaining-route-budget-or-timing"). RETURN. }
        IF index = route:LENGTH-1 AND SHIP:BODY = bodies[index] {
            assistFlightHandoff(flight). RETURN.
        }
        LOCAL wakeUt IS 0.
        IF SHIP:ORBIT:HASNEXTPATCH {
            LOCAL transitionUt IS TIME:SECONDS+SHIP:ORBIT:NEXTPATCHETA.
            IF NOT (transitionUt > TIME:SECONDS AND transitionUt < 1e30) {
                assistFlightHold("invalid-next-transition"). RETURN.
            }
            LOCAL nextBody IS SHIP:ORBIT:NEXTPATCH:BODY.
            ensureSoiAlarm(nextBody,transitionUt,"Assist encounter transition; running coast owns resumption.").
            IF transitionUt-TIME:SECONDS > 60 {
                SET wakeUt TO transitionUt-30.
            } ELSE { SET wakeUt TO transitionUt+0.1. }
            IF NOT flight:HASKEY("reviewBody") OR flight["reviewBody"] <> SHIP:BODY:NAME {
                SET flight TO flight:COPY.
                SET flight["reviewBody"] TO SHIP:BODY:NAME.
                SET flight["reviewUt"] TO 0.
                IF transitionUt-TIME:SECONDS > 21600 {
                    SET flight["reviewUt"] TO (TIME:SECONDS+transitionUt)/2.
                }
                stateSet("assist_flight",flight).
            }
            IF flight["reviewUt"] > TIME:SECONDS { SET wakeUt TO MIN(wakeUt,flight["reviewUt"]). }
        } ELSE { assistFlightHold("expected-transition-missing"). RETURN. }
        IF SHIP:BODY = bodies[index] AND index < route:LENGTH-1 AND NOT consumedCurrent {
            LOCAL peUt IS TIME:SECONDS+SHIP:ORBIT:ETA:PERIAPSIS.
            LOCAL peAlarm IS kacEnsureAlarm("Assist flyby Pe: " + SHIP:BODY:NAME,peUt,
                "Unpowered flyby; running assist coast verifies passage.",1).
            SET flight TO flight:COPY.
            SET flight["peAlarm"] TO peAlarm.
            stateSet("assist_flight",flight).
            IF peUt-TIME:SECONDS > 60 {
                SET wakeUt TO MIN(wakeUt,peUt-30).
            } ELSE { SET wakeUt TO MIN(wakeUt,peUt+0.1). }
        }
        _assistWait(wakeUt).
    }
    assistFlightHold("abort").
}
