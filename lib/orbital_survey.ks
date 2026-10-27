// orbital_survey.ks - Unpowered overhead temperature survey passes.
// Observations are evidence of deployment, not a contract-completion API.
@LAZYGLOBAL OFF.

GLOBAL ORBITAL_SURVEY_MIN_PE IS 9000.
GLOBAL ORBITAL_SURVEY_MAX_AP IS 30000.
GLOBAL ORBITAL_SURVEY_RADIUS IS 1000.
GLOBAL ORBITAL_SURVEY_ORBITS IS 48.
GLOBAL ORBITAL_SURVEY_BODY IS "".

LOCAL FUNCTION _surveySafe {
    RETURN NOT ABORT AND NOT phaseShouldYield AND NOT HASNODE
        AND SHIP:STATUS = "ORBITING" AND NOT SHIP:BODY:ATM:EXISTS
        AND SHIP:BODY:NAME = ORBITAL_SURVEY_BODY
        AND SHIP:PERIAPSIS >= ORBITAL_SURVEY_MIN_PE
        AND SHIP:APOAPSIS <= ORBITAL_SURVEY_MAX_AP
        AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
        AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND SHIP:ORBIT:PERIOD > 0 AND SHIP:ORBIT:PERIOD < 1e30
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

LOCAL FUNCTION _surveyDistance {
    PARAMETER geo.
    PARAMETER site.
    LOCAL dotGeo IS SIN(geo:LAT)*SIN(site[0])
        + COS(geo:LAT)*COS(site[0])*COS(geo:LNG-site[1]).
    RETURN SHIP:BODY:RADIUS*ARCCOS(MAX(-1,MIN(1,dotGeo)))*CONSTANT:PI/180.
}

LOCAL FUNCTION _surveyForecast {
    PARAMETER done.
    LOCAL began IS TIME:SECONDS.
    LOCAL forecastBody IS SHIP:BODY.
    LOCAL firstUt IS began+180.
    LOCAL stepSec IS SHIP:ORBIT:PERIOD/32.
    LOCAL endUt IS firstUt+SHIP:ORBIT:PERIOD*ORBITAL_SURVEY_ORBITS.
    LOCAL bestTimes IS LIST().
    LOCAL bestMisses IS LIST().
    FOR site IN SCIENCE_SURVEY_POINTS {
        bestTimes:ADD(firstUt).
        bestMisses:ADD(1e30).
    }
    LOCAL sampleUt IS firstUt.
    LOCAL samples IS 0.
    mLog("STATS orbital-survey search-start firstUt=" + firstUt + " endUt=" + endUt
        + " stepSec=" + stepSec + " remaining=" + (SCIENCE_SURVEY_POINTS:LENGTH-done:LENGTH)).
    // This loop only forecasts; it never controls the vehicle. Check the
    // expensive orbit/propulsion suffixes once per scanned orbit, with
    // Abort/node/body/yield checked every sample. The caller and measurement
    // admission both recheck the complete live safety predicate afterwards.
    UNTIL sampleUt > endUt OR ABORT OR HASNODE OR phaseShouldYield OR SHIP:BODY <> forecastBody {
        IF MOD(samples,32) = 0 AND NOT _surveySafe() { BREAK. }
        LOCAL geo IS lmGroundGeoAt(sampleUt).
        LOCAL i IS 0.
        UNTIL i >= SCIENCE_SURVEY_POINTS:LENGTH {
            IF NOT done:CONTAINS(i) {
                LOCAL miss IS _surveyDistance(geo,SCIENCE_SURVEY_POINTS[i]).
                IF miss < bestMisses[i] {
                    SET bestTimes[i] TO sampleUt.
                    SET bestMisses[i] TO miss.
                }
            }
            SET i TO i+1.
        }
        SET sampleUt TO sampleUt+stepSec.
        SET samples TO samples+1.
        IF MOD(samples,256) = 0 {
            mLog("STATS orbital-survey progress samples=" + samples + " elapsed=" + (TIME:SECONDS-began)).
        }
    }
    LOCAL result IS LEXICON("FOUND",FALSE,"SITE",-1,"UT",endUt,"MISS",1e30).
    LOCAL i IS 0.
    UNTIL i >= SCIENCE_SURVEY_POINTS:LENGTH OR NOT _surveySafe() {
        IF NOT done:CONTAINS(i) {
            LOCAL lowerUt IS MAX(firstUt,bestTimes[i]-stepSec).
            LOCAL upperUt IS MIN(endUt,bestTimes[i]+stepSec).
            LOCAL refine IS 0.
            UNTIL refine >= 16 {
                LOCAL leftUt IS lowerUt+(upperUt-lowerUt)/3.
                LOCAL rightUt IS upperUt-(upperUt-lowerUt)/3.
                IF _surveyDistance(lmGroundGeoAt(leftUt),SCIENCE_SURVEY_POINTS[i])
                        < _surveyDistance(lmGroundGeoAt(rightUt),SCIENCE_SURVEY_POINTS[i]) {
                    SET upperUt TO rightUt.
                } ELSE { SET lowerUt TO leftUt. }
                SET refine TO refine+1.
            }
            LOCAL passUt IS (lowerUt+upperUt)/2.
            LOCAL miss IS _surveyDistance(lmGroundGeoAt(passUt),SCIENCE_SURVEY_POINTS[i]).
            mLog("STATS orbital-survey forecast site=" + (i+1) + " passUt=" + passUt + " missM=" + miss).
            IF NOT result["FOUND"] { SET result["MISS"] TO MIN(result["MISS"],miss). }
            IF miss <= ORBITAL_SURVEY_RADIUS AND passUt < result["UT"] {
                SET result TO LEXICON("FOUND",TRUE,"SITE",i,"UT",passUt,"MISS",miss).
            }
        }
        SET i TO i+1.
    }
    mLog("STATS orbital-survey search samples=" + samples + " elapsed=" + (TIME:SECONDS-began)
        + " found=" + result["FOUND"] + " radiusM=" + ORBITAL_SURVEY_RADIUS).
    RETURN result.
}

LOCAL FUNCTION _surveyThermometers {
    LOCAL modules IS LIST().
    // Use only stock thermometers retained with the CPU through separation.
    // No generic run-all/reset/transmit operation can silently replace data.
    FOR part IN SHIP:PARTSNAMED("sensorThermometer") {
        IF part:DECOUPLEDIN = CORE:PART:DECOUPLEDIN AND part:HASMODULE("ModuleScienceExperiment") {
            modules:ADD(part:GETMODULE("ModuleScienceExperiment")).
        }
    }
    RETURN modules.
}

LOCAL FUNCTION _surveyStore {
    FOR part IN SHIP:PARTS {
        IF part:DECOUPLEDIN = CORE:PART:DECOUPLEDIN AND part:HASMODULE("ModuleScienceContainer") {
            part:GETMODULE("ModuleScienceContainer"):COLLECTALL().
        }
    }
}

LOCAL FUNCTION _surveyReadyThermometer {
    // Collection may decline a duplicate. Leave that reading intact and
    // try another thermometer; never RESET an experiment with HASDATA.
    _surveyStore().
    FOR experiment IN _surveyThermometers() {
        IF NOT experiment:INOPERABLE AND experiment:RERUNNABLE AND NOT experiment:HASDATA {
            IF experiment:DEPLOYED { experiment:RESET(). }
            IF NOT experiment:DEPLOYED { RETURN experiment. }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _surveyObserve {
    PARAMETER index.
    LOCAL site IS SCIENCE_SURVEY_POINTS[index].
    IF NOT _surveySafe() OR WARP <> 0 OR NOT KUNIVERSE:TIMEWARP:ISSETTLED
            OR SHIP:ALTITUDE <= site[2]
            OR _surveyDistance(SHIP:GEOPOSITION,site) > ORBITAL_SURVEY_RADIUS { RETURN FALSE. }
    LOCAL experiment IS _surveyReadyThermometer().
    IF experiment = 0 { RETURN FALSE. }
    // Recheck after module actions, before the actual measurement.
    IF NOT _surveySafe() OR SHIP:ALTITUDE <= site[2]
            OR _surveyDistance(SHIP:GEOPOSITION,site) > ORBITAL_SURVEY_RADIUS { RETURN FALSE. }
    experiment:DEPLOY().
    LOCAL deadline IS TIME:SECONDS+5.
    UNTIL experiment:HASDATA OR TIME:SECONDS >= deadline OR NOT _surveySafe() { WAIT 0.1. }
    IF NOT experiment:HASDATA { RETURN FALSE. }
    mLog("STATS orbital-survey observed site=" + (index+1) + " lat=" + SHIP:GEOPOSITION:LAT
        + " lng=" + SHIP:GEOPOSITION:LNG + " altitude=" + SHIP:ALTITUDE
        + " distanceM=" + _surveyDistance(SHIP:GEOPOSITION,site)
        + " contractVerified=False retainedWithCpu=True").
    // The data is already on the retained return hardware, even if a
    // container cannot accept it. The next attempt never dumps it.
    RETURN TRUE.
}

LOCAL FUNCTION _surveyWait {
    PARAMETER wakeUt.
    LOCAL coastBody IS SHIP:BODY.
    LOCAL alarm IS kacEnsureAlarm("Orbital temperature survey",wakeUt,"Wake for a fresh overhead survey check; no maneuver burn.").
    mLog("STATS orbital-survey wait wakeUt=" + wakeUt + " alarm=" + alarm).
    LOCAL solarRef IS enterSolarCoast("Orbital survey",TRUE,TRUE,wakeUt).
    waitUntilOrSOI(coastBody,wakeUt,5,alarm,solarRef,TRUE,TRUE).
    IF alarm <> "" { DELETEALARM(alarm). }
    RETURN SHIP:BODY = coastBody AND _surveySafe().
}

GLOBAL FUNCTION phaseOrbitalSurvey {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF NOT thrustCutoffOk() { RETURN. }
    IF NOT _surveySafe() OR SCIENCE_SURVEY_POINTS:LENGTH = 0
            OR NOT (ORBITAL_SURVEY_RADIUS > 0 AND ORBITAL_SURVEY_RADIUS <= 5000)
            OR NOT (ORBITAL_SURVEY_ORBITS >= 1 AND ORBITAL_SURVEY_ORBITS <= 48) {
        mLogError("ORBITAL_SURVEY requires a safe low airless orbit and a bounded survey configuration.").
        yieldToPrompt(). RETURN.
    }
    LOCAL latitudeLimit IS MIN(SHIP:ORBIT:INCLINATION,180-SHIP:ORBIT:INCLINATION).
    FOR site IN SCIENCE_SURVEY_POINTS {
        IF site:LENGTH <> 3 {
            mLogError("ORBITAL_SURVEY: each site needs latitude, longitude and minimum ASL altitude.").
            yieldToPrompt(). RETURN.
        }
        IF ABS(site[0]) > latitudeLimit
                OR ABS(site[1]) > 180 OR NOT (site[2] >= 0 AND site[2] < SHIP:PERIAPSIS) {
            mLogError("ORBITAL_SURVEY: invalid site, unreachable latitude or altitude threshold above the orbit floor.").
            yieldToPrompt(). RETURN.
        }
    }
    LOCAL context IS configLiteral(LIST(stateGet("mission_id",""),stateGet("launch_time",""),
        SHIP:BODY:NAME,SCIENCE_SURVEY_POINTS,ORBITAL_SURVEY_RADIUS)).
    LOCAL record IS stateGet("orbital_survey",LEXICON("CONTEXT","","DONE",LIST())).
    IF record["CONTEXT"] <> context {
        SET record TO LEXICON("CONTEXT",context,"DONE",LIST()).
        stateSet("orbital_survey",record).
    }
    // Copy the nested list too: stateGet returns the cached object.
    LOCAL done IS record["DONE"]:COPY.
    UNTIL done:LENGTH >= SCIENCE_SURVEY_POINTS:LENGTH OR NOT _surveySafe() {
        IF _surveyReadyThermometer() = 0 {
            mLogError("ORBITAL_SURVEY: no empty retained thermometer. Store/review its data; no reading was discarded.").
            yieldToPrompt(). RETURN.
        }
        LOCAL forecast IS _surveyForecast(done).
        IF NOT _surveySafe() { BREAK. }
        IF NOT forecast["FOUND"] {
            mLog("STATS orbital-survey retry reason=no-close-pass nearestM=" + forecast["MISS"]).
            // New live search after a useful fraction of the scanned horizon;
            // no alarm-only exit and no repeated immediate search at the prompt.
            IF NOT _surveyWait(TIME:SECONDS+SHIP:ORBIT:PERIOD*ORBITAL_SURVEY_ORBITS/2) { BREAK. }
        } ELSE {
            IF forecast["UT"]-TIME:SECONDS > 120 {
                IF NOT _surveyWait(forecast["UT"]-120) { BREAK. }
            }
            LOCAL site IS SCIENCE_SURVEY_POINTS[forecast["SITE"]].
            LOCAL endUt IS forecast["UT"]+SHIP:ORBIT:PERIOD/32.
            LOCAL observed IS FALSE.
            UNTIL TIME:SECONDS > endUt OR NOT _surveySafe() OR observed {
                IF _surveyDistance(SHIP:GEOPOSITION,site) <= ORBITAL_SURVEY_RADIUS {
                    SET observed TO _surveyObserve(forecast["SITE"]).
                    IF NOT observed {
                        mLogError("ORBITAL_SURVEY: measurement unavailable; retaining data and phase for review.").
                        yieldToPrompt(). RETURN.
                    }
                }
                IF NOT observed { WAIT 0.2. }
            }
            IF observed {
                done:ADD(forecast["SITE"]).
                stateSet("orbital_survey",LEXICON("CONTEXT",context,"DONE",done:COPY)).
                _surveyStore().
            }
        }
    }
    IF NOT _surveySafe() {
        mLogWarn("ORBITAL_SURVEY interrupted: keeping observations and phase; review orbit/Abort/node before reboot.").
        yieldToPrompt(). RETURN.
    }
    mLog("STATS orbital-survey result=observations-recorded count=" + done:LENGTH
        + " contractVerified=False; verify all contract ticks before releasing the landing phase.").
    nextPhase(xferSeq).
}
