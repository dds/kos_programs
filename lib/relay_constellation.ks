// Passive relay placement: circular release, shorter resonant carrier orbit,
// circularize and repeat. Persistent records never infer a successful release
// from an event request or silently discard an interrupted/foreign maneuver.
@LAZYGLOBAL OFF.
GLOBAL TARGET_AP IS -1.
LOCAL CIRCULAR_ECC_LIMIT IS 0.001.

LOCAL FUNCTION _relayContext {
    PARAMETER bdy, allowNode IS FALSE.
    RETURN NOT ABORT AND WARP = 0 AND SHIP = KUNIVERSE:ACTIVEVESSEL
        AND SHIP:BODY = bdy AND SHIP:STATUS = "ORBITING"
        AND SHIP:BODY = missionTargetBody()
        AND SHIP:PERIAPSIS > MAX(5000,bdy:ATM:HEIGHT)
        AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
        AND SHIP:ORBIT:PERIOD > 0 AND SHIP:ORBIT:PERIOD < 1e30
        AND SHIP:ORBIT:SEMIMAJORAXIS > 0 AND SHIP:ORBIT:SEMIMAJORAXIS < 1e30
        AND SHIP:APOAPSIS < bdy:SOIRADIUS-bdy:RADIUS AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND (allowNode OR NOT HASNODE) AND NOT maneuverBurnInterrupted()
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

LOCAL FUNCTION _relayHold {
    PARAMETER reason.
    SET WARP TO 0.
    UNLOCK STEERING.
    mLogError("STATS constellation result=hold reason="+reason
        +" released="+stateGetNum("relay_deployed_count",0)).
    PRINT "RELAY DEPLOYMENT HELD: "+reason+". Existing maneuvers and release records retained.".
    yieldToPrompt().
    RETURN FALSE.
}

LOCAL FUNCTION _relayRecord {
    PARAMETER idx.
    RETURN stateGet("relay_"+idx+"_record",LEXICON()).
}

LOCAL FUNCTION _relayReleased {
    PARAMETER idx.
    RETURN _relayRecord(idx):LENGTH > 0.
}

LOCAL FUNCTION _relayReferencePeriod {
    LOCAL first IS _relayRecord(1).
    IF first:LENGTH > 0 { RETURN first["PERIOD"]. }
    RETURN SHIP:ORBIT:PERIOD.
}

LOCAL FUNCTION _relayCampaign {
    PARAMETER count, altitude, bdy.
    LOCAL id IS stateGet("mission_id","")+":"+stateGetNum("launch_time",0)
        +":"+bdy:NAME+":"+count+":"+altitude.
    LOCAL old IS stateGet("relay_campaign_id","").
    IF old <> "" { RETURN old = id. }
    // Old ledgers have no physical/period evidence: never migrate by guessing.
    IF stateGetNum("relay_deployed_count",0) > 0 { RETURN FALSE. }
    LOCAL i IS 1.
    UNTIL i > count {
        IF stateGet("relay_"+i+"_released","") <> "" { RETURN FALSE. }
        SET i TO i+1.
    }
    stateSet("relay_campaign_id",id).
    RETURN TRUE.
}

LOCAL FUNCTION _relayExecute {
    PARAMETER nd.
    IF NOT _relayContext(SHIP:BODY,TRUE) OR NOT HASNODE OR NEXTNODE <> nd {
        RETURN FALSE.
    }
    IF NOT (nd:DELTAV:MAG >= 0.001 AND nd:DELTAV:MAG < 1e30
            AND STAGE:DELTAV:VACUUM < 1e30
            AND STAGE:DELTAV:VACUUM >= nd:DELTAV:MAG+RELAY_RESERVE_DV) {
        REMOVE nd. RETURN FALSE.
    }
    LOCAL savedEvents IS BURN_STAGE_MAX_EVENTS.
    LOCAL savedWait IS BURN_STAGE_MANUAL_WAIT.
    LOCAL savedAbs IS BURN_TRIM_ABS_COMPLETE_DV.
    LOCAL savedMax IS BURN_TRIM_COMPLETE_MAX_DV.
    // Deployment burns use the active carrier stage; never stage payloads.
    SET BURN_STAGE_MAX_EVENTS TO 0.
    SET BURN_STAGE_MANUAL_WAIT TO 0.
    SET BURN_TRIM_ABS_COMPLETE_DV TO MIN(savedAbs,0.001).
    SET BURN_TRIM_COMPLETE_MAX_DV TO MIN(savedMax,0.001).
    LOCAL ok IS executeManeuver().
    SET BURN_STAGE_MAX_EVENTS TO savedEvents.
    SET BURN_STAGE_MANUAL_WAIT TO savedWait.
    SET BURN_TRIM_ABS_COMPLETE_DV TO savedAbs.
    SET BURN_TRIM_COMPLETE_MAX_DV TO savedMax.
    IF NOT thrustCutoffOk() { RETURN FALSE. }
    RETURN ok AND NOT HASNODE AND NOT maneuverBurnInterrupted().
}

LOCAL FUNCTION _circularizeCarrier {
    IF NOT _relayContext(SHIP:BODY) { RETURN FALSE. }
    LOCAL nd IS planCircularize().
    IF nd:TIME < TIME:SECONDS+180 { SET nd:TIME TO nd:TIME+SHIP:ORBIT:PERIOD. }
    RETURN _relayExecute(nd).
}

LOCAL FUNCTION _ensureCircularBeforeDeploy {
    PARAMETER altitude.
    IF NOT _relayContext(SHIP:BODY) { RETURN FALSE. }
    IF SHIP:ORBIT:ECCENTRICITY > CIRCULAR_ECC_LIMIT {
        IF NOT _circularizeCarrier() { RETURN FALSE. }
    }
    LOCAL tolerance IS MAX(1000,altitude*0.01).
    RETURN SHIP:ORBIT:ECCENTRICITY <= CIRCULAR_ECC_LIMIT
        AND ABS(SHIP:APOAPSIS-altitude) <= tolerance
        AND ABS(SHIP:PERIAPSIS-altitude) <= tolerance.
}

LOCAL FUNCTION _relayMatchPeriod {
    IF NOT _relayReleased(1) { RETURN TRUE. }
    LOCAL desired IS _relayReferencePeriod().
    LOCAL tries IS 0.
    UNTIL ABS(SHIP:ORBIT:PERIOD-desired) <= RELAY_PERIOD_TOLERANCE {
        IF tries >= 4 OR NOT _relayContext(SHIP:BODY) { RETURN FALSE. }
        LOCAL period IS SHIP:ORBIT:PERIOD.
        LOCAL apEta IS ETA:APOAPSIS.
        LOCAL peEta IS ETA:PERIAPSIS.
        UNTIL apEta >= 180 { SET apEta TO apEta+period. }
        UNTIL peEta >= 180 { SET peEta TO peEta+period. }
        LOCAL radius IS SHIP:BODY:RADIUS+SHIP:APOAPSIS.
        LOCAL eta_ IS apEta.
        IF peEta < apEta { SET radius TO SHIP:BODY:RADIUS+SHIP:PERIAPSIS. SET eta_ TO peEta. }
        LOCAL mu IS SHIP:BODY:MU.
        LOCAL sma IS (mu*(desired/(2*CONSTANT:PI))^2)^(1/3).
        LOCAL dv IS SQRT(mu*(2/radius-1/sma))
            -SQRT(mu*(2/radius-1/SHIP:ORBIT:SEMIMAJORAXIS)).
        IF ABS(dv) < 0.001 { RETURN FALSE. }
        LOCAL nd IS NODE(TIME:SECONDS+eta_,0,0,dv).
        ADD nd.
        mLog("STATS relay-period trim errorSeconds="+(period-desired)+" dv="+dv+" attempt="+tries).
        IF NOT _relayExecute(nd) { RETURN FALSE. }
        SET tries TO tries+1.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _relayReleaseContext {
    RETURN _relayContext(SHIP:BODY).
}

LOCAL FUNCTION _relayReleasedOrbit {
    PARAMETER idx, released.
    LOCAL expected IS _relayReferencePeriod().
    IF idx = 1 { SET expected TO released:ORBIT:PERIOD. }
    RETURN LEXICON("REFERENCE",expected,"VALID",
        released:ORBIT:ECCENTRICITY <= CIRCULAR_ECC_LIMIT
        AND ABS(released:ORBIT:PERIOD-expected) <= RELAY_PERIOD_TOLERANCE).
}

LOCAL FUNCTION _deployOneRelay {
    PARAMETER idx.
    RETURN relayReleasePayload(idx,_relayReleaseContext@,_relayReleasedOrbit@).
}

LOCAL FUNCTION _phaseCarrierOneSlot {
    PARAMETER count, altitude, bdy, idx.
    LOCAL key IS "relay_"+idx.
    IF stateGetNum(key+"_phase_complete",0) > 0 { RETURN TRUE. }
    LOCAL reference IS _relayReferencePeriod().
    LOCAL phasePeriod IS reference*(count-1)/count.
    LOCAL sma IS (bdy:MU*(phasePeriod/(2*CONSTANT:PI))^2)^(1/3).
    LOCAL apRadius IS bdy:RADIUS+altitude.
    LOCAL phasePe IS 2*sma-apRadius-bdy:RADIUS.
    IF stateGetNum(key+"_phase_inserted",0) = 0 {
        IF SHIP:ORBIT:ECCENTRICITY <= CIRCULAR_ECC_LIMIT {
            IF NOT _relayContext(bdy) { RETURN FALSE. }
            LOCAL eta_ IS ETA:APOAPSIS.
            UNTIL eta_ >= 180 { SET eta_ TO eta_+SHIP:ORBIT:PERIOD. }
            SET apRadius TO bdy:RADIUS+SHIP:APOAPSIS.
            SET phasePe TO 2*sma-apRadius-bdy:RADIUS.
            IF phasePe <= MAX(5000,bdy:ATM:HEIGHT+5000) { RETURN FALSE. }
            LOCAL dv IS SQRT(bdy:MU*(2/apRadius-1/sma))
                -SQRT(bdy:MU*(2/apRadius-1/SHIP:ORBIT:SEMIMAJORAXIS)).
            LOCAL nd IS NODE(TIME:SECONDS+eta_,0,0,dv).
            ADD nd.
            IF NOT _relayExecute(nd) { RETURN FALSE. }
        }
        IF ABS(SHIP:APOAPSIS-altitude) > MAX(1000,altitude*0.01)
                OR ABS(SHIP:ORBIT:PERIOD-phasePeriod) > MAX(5,phasePeriod*0.001) { RETURN FALSE. }
        stateSet(key+"_phase_inserted",TIME:SECONDS).
    }
    IF SHIP:ORBIT:ECCENTRICITY > CIRCULAR_ECC_LIMIT {
        LOCAL actualPeriod IS SHIP:ORBIT:PERIOD.
        LOCAL returnUt IS stateGetNum(key+"_return_ut",0).
        IF returnUt <= 0 { SET returnUt TO TIME:SECONDS+ETA:APOAPSIS. }
        // If reboot misses an apsis, n extra phasing orbits preserve relative
        // spacing: n*(n-1)/n is a whole number of final relay orbits.
        IF returnUt < TIME:SECONDS+180 {
            SET returnUt TO returnUt+CEILING((TIME:SECONDS+180-returnUt)/(count*actualPeriod))*count*actualPeriod.
        }
        stateSet(key+"_return_ut",returnUt).
        LOCAL wakeUt IS returnUt-180.
        LOCAL alarm IS kacEnsureAlarm("Relay phasing "+idx,wakeUt,"Carrier circularization preparation; running phase resumes.",1).
        mLog("STATS relay-phase wait index="+idx+" returnUt="+returnUt+" wakeUt="+wakeUt+" alarm="+alarm+" resident=True").
        LOCAL solarRef IS enterSolarCoast("Relay phasing",TRUE,TRUE,wakeUt).
        waitUntilOrSOI(bdy,wakeUt,5,alarm,solarRef,TRUE,TRUE).
        IF alarm <> "" { DELETEALARM(alarm). }
        IF NOT _relayContext(bdy) OR ABS(TIME:SECONDS+ETA:APOAPSIS-returnUt) > 5 { RETURN FALSE. }
        IF NOT _circularizeCarrier() { RETURN FALSE. }
    }
    IF NOT _ensureCircularBeforeDeploy(altitude) OR NOT _relayMatchPeriod() { RETURN FALSE. }
    stateSet(key+"_phase_complete",TIME:SECONDS).
    mLog("STATS relay-phase result index="+idx+" period="+SHIP:ORBIT:PERIOD+" reference="+reference).
    RETURN TRUE.
}

GLOBAL FUNCTION constellationDeploy {
    PARAMETER relayCount, targetAlt, bodyOverride IS "".
    LOCAL bdy IS SHIP:BODY.
    IF bodyOverride <> "" { SET bdy TO BODY(bodyOverride). }
    LOCAL geometry IS relayGeometry(relayCount,targetAlt,bdy).
    IF NOT geometry["OK"] { RETURN _relayHold(geometry["REASON"]). }
    IF NOT (RELAY_RESERVE_DV >= 0 AND RELAY_RESERVE_DV < 1e30
            AND RELAY_PERIOD_TOLERANCE > 0 AND RELAY_PERIOD_TOLERANCE < 60)
            OR NOT _relayContext(bdy) { RETURN _relayHold("unsafe-context-or-settings"). }
    IF NOT _relayCampaign(relayCount,targetAlt,bdy) { RETURN _relayHold("ledger-belongs-to-another-or-legacy-mission"). }
    LOCAL count IS 0.
    LOCAL i IS 1.
    UNTIL i > relayCount {
        IF _relayReleased(i) {
            IF NOT _relayRecord(i)["VALID"] { RETURN _relayHold("released-relay-period-needs-review"). }
            SET count TO count+1.
        } ELSE {
            LOCAL intent IS stateGet("relay_"+i+"_intent",LEXICON()).
            IF intent:LENGTH > 0 {
                IF relayAttachedCount(intent["UIDS"]) <> intent["UIDS"]:LENGTH {
                    RETURN _relayHold("separation-interrupted-before-physical-period-proof").
                }
            }
            LOCAL info IS relayPayloadInfo(i).
            IF NOT info["OK"] { RETURN _relayHold("relay_"+i+":"+info["REASON"]). }
        }
        SET i TO i+1.
    }
    stateSet("relay_deployed_count",count).
    IF count = 0 {
        LOCAL needed IS geometry["DEPLOY_DV"]*1.1+20+RELAY_RESERVE_DV.
        IF NOT (STAGE:DELTAV:VACUUM >= needed AND STAGE:DELTAV:VACUUM < 1e30) {
            RETURN _relayHold("active-carrier-stage-deployment-budget").
        }
    }
    mLog("STATS constellation setup count="+relayCount+" released="+count+" altitude="+targetAlt
        +" body="+bdy:NAME+" periodTolerance="+RELAY_PERIOD_TOLERANCE).
    SET i TO 1.
    UNTIL i > relayCount {
        IF NOT _relayReleased(i) {
            IF NOT _ensureCircularBeforeDeploy(targetAlt) OR NOT _relayMatchPeriod() {
                RETURN _relayHold("carrier-circular-or-period-check").
            }
            IF NOT _deployOneRelay(i) { RETURN _relayHold("release-or-period-proof-failed-relay-"+i). }
            SET count TO count+1.
            stateSet("relay_deployed_count",count).
        }
        IF i < relayCount {
            IF NOT _phaseCarrierOneSlot(relayCount,targetAlt,bdy,i) { RETURN _relayHold("phasing-relay-"+i). }
        }
        SET i TO i+1.
    }
    mLog("STATS constellation result=complete released="+count+" referencePeriod="+_relayReferencePeriod()).
    PRINT "Relays deployed. Verify CommNet paths and long-term spacing before declaring landing coverage.".
    RETURN TRUE.
}

GLOBAL FUNCTION phaseRelayConstellation {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    LOCAL altitude IS RELAY_ALT.
    IF altitude < 0 { SET altitude TO TARGET_AP. }
    IF constellationDeploy(RELAY_COUNT,altitude) { nextPhase(xferSeq). }
}

GLOBAL FUNCTION constellationStatus {
    PARAMETER count.
    LOCAL i IS 1.
    UNTIL i > count {
        mLog("Relay "+i+" record="+_relayRecord(i)+" phaseComplete="+stateGetNum("relay_"+i+"_phase_complete",0)).
        SET i TO i+1.
    }
}
