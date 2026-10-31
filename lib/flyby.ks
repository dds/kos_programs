// Unpowered periapsis coast, with opt-in close-pass science. Kept separate
// from capture so ordinary capture/coast bands do not load science modules.
@LAZYGLOBAL OFF.
GLOBAL FLYBY_POST_PE_HOLD IS 0.
GLOBAL FLYBY_EXIT_SOI IS 1.
// Empty retargets to the body's parent for legacy moon-return missions.
GLOBAL FLYBY_NEXT_TARGET IS "".
GLOBAL FLYBY_SCIENCE IS 0.
GLOBAL FLYBY_SCIENCE_LOW_ALT IS 0.
GLOBAL FLYBY_SCIENCE_MIN_EC IS 0.3.

LOCAL FUNCTION _flybySample {
    PARAMETER target.
    IF FLYBY_SCIENCE <= 0 OR ABORT OR WARP <> 0 OR SHIP:BODY <> target
            OR SHIP <> KUNIVERSE:ACTIVEVESSEL { RETURN. }
    LOCAL situation IS "SPACE_HIGH".
    IF SHIP:ALTITUDE < FLYBY_SCIENCE_LOW_ALT { SET situation TO "SPACE_LOW". }
    scienceFlightPulse(stateGet("mission_id","")+":"+target:NAME+":"+situation,
        shipPowerFraction() >= FLYBY_SCIENCE_MIN_EC).
}

// Stop solar searches before the inbound low-space science boundary. Use
// native elements and shared conic time, not future vessel/body vectors.
LOCAL FUNCTION _flybyLowEntryUt {
    PARAMETER target.
    PARAMETER peUt.
    IF FLYBY_SCIENCE <= 0 { RETURN peUt. }
    LOCAL rp IS target:RADIUS+SHIP:PERIAPSIS.
    LOCAL crossing IS target:RADIUS+FLYBY_SCIENCE_LOW_ALT.
    LOCAL ecc IS SHIP:ORBIT:ECCENTRICITY.
    IF NOT (rp > 0 AND rp < crossing AND ecc > 0.000001 AND ecc < 1e30) { RETURN peUt. }
    LOCAL latus IS rp*(1+ecc).
    LOCAL cosine IS (latus/crossing-1)/ecc.
    IF NOT (cosine > -1 AND cosine < 1) { RETURN peUt. }
    RETURN peUt-conicTimeFromPe(ecc,latus,target:MU,
        cosine,SQRT(MAX(0,1-cosine^2)))-30.
}

LOCAL FUNCTION _flybyPeriapsisUt {
    PARAMETER target.
    LOCAL id IS stateGet("mission_id","")+":"+stateGetNum("launch_time",0)+":"+target:NAME.
    IF stateGet("flyby_pass_id","") = id {
        RETURN stateGetNum("flyby_pe_ut",-1).
    }
    LOCAL peUt IS TIME:SECONDS+ETA:PERIAPSIS.
    // A capture centered on Pe can finish just AFTER Pe. Bound ETA then
    // names the next orbit: observe this pass rather than waiting a period.
    IF SHIP:ORBIT:ECCENTRICITY < 1 AND SHIP:VERTICALSPEED > 0 {
        SET peUt TO peUt-SHIP:ORBIT:PERIOD.
    }
    IF NOT (peUt >= 0 AND peUt < 1e30) { RETURN -1. }
    stateSet("flyby_pe_ut",peUt).
    stateSet("flyby_pass_id",id).
    RETURN peUt.
}

GLOBAL FUNCTION phaseFlyby {
    LOCAL target IS missionTargetBody().
    IF ABORT OR NOT thrustCutoffOk() { RETURN. }
    IF HASNODE {
        mLogError("FLYBY: existing maneuver retained; review before coasting.").
        yieldToPrompt(). RETURN.
    }
    IF SHIP:BODY <> target {
        mLog("Flyby waiting for " + target:NAME + " SOI.").
        waitForSOI(target).
    }
    IF ABORT OR SHIP:BODY <> target { RETURN. }
    IF NOT (FLYBY_POST_PE_HOLD >= 0 AND FLYBY_POST_PE_HOLD < 1e30)
            OR (FLYBY_SCIENCE > 0 AND (target:ATM:EXISTS
                OR NOT (FLYBY_SCIENCE_LOW_ALT > 0 AND FLYBY_SCIENCE_LOW_ALT < target:SOIRADIUS
                    AND FLYBY_SCIENCE_MIN_EC >= 0 AND FLYBY_SCIENCE_MIN_EC < 1))) {
        mLogError("FLYBY: invalid coast/science configuration.").
        yieldToPrompt(). RETURN.
    }
    LOCAL peUt IS _flybyPeriapsisUt(target).
    IF peUt < 0 {
        mLogError("FLYBY: native periapsis time unavailable.").
        yieldToPrompt(). RETURN.
    }
    LOCAL endUt IS peUt+FLYBY_POST_PE_HOLD.
    LOCAL lowUt IS endUt.
    IF FLYBY_SCIENCE > 0 { SET lowUt TO _flybyLowEntryUt(target,peUt). }
    LOCAL alarms IS LIST().
    IF lowUt > TIME:SECONDS AND FLYBY_SCIENCE > 0 {
        alarms:ADD(kacEnsureAlarm("Flyby science: "+target:NAME,lowUt,
            "Low-space sampling begins shortly; resident phase continues.",1)).
    }
    IF peUt > TIME:SECONDS {
        alarms:ADD(kacEnsureAlarm("Flyby Pe: "+target:NAME,peUt,
            "Resident flyby phase continues after periapsis.",1)).
    }
    IF endUt > TIME:SECONDS AND FLYBY_POST_PE_HOLD > 0 {
        alarms:ADD(kacEnsureAlarm("Flyby review: "+target:NAME,endUt,
            "Close-pass science complete; review capture and stored data.",1)).
    }
    mLog("STATS flyby setup target="+target:NAME+" peUt="+peUt
        +" lowWakeUt="+lowUt+" endUt="+endUt+" science="+FLYBY_SCIENCE
        +" bound="+(SHIP:ORBIT:ECCENTRICITY < 1)+" resident=True").
    LOCAL solarRef IS -1.
    _flybySample(target).
    IF TIME:SECONDS < MIN(lowUt,endUt) {
        SET solarRef TO enterSolarCoast("FLYBY",TRUE,FALSE,MIN(lowUt,endUt)).
    }
    UNTIL ABORT OR HASNODE OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR TIME:SECONDS >= endUt OR SHIP:BODY <> target {
        // The close-pass window never starts an attitude search or blind
        // minute-long wait. Preserve the existing attitude and sample at2Hz.
        LOCAL delay IS MIN(60,MAX(0.1,endUt-TIME:SECONDS)).
        IF FLYBY_SCIENCE > 0 AND TIME:SECONDS >= lowUt { SET delay TO MIN(delay,0.5). }
        ELSE {
            SET solarRef TO trySolarHoldTick(solarRef,lowUt).
            SET delay TO MIN(delay,MAX(0.1,lowUt-TIME:SECONDS)).
        }
        _flybySample(target).
        WAIT delay.
    }
    FOR alarm IN alarms { IF alarm <> "" { DELETEALARM(alarm). } }
    IF ABORT { RETURN. }
    IF HASNODE OR SHIP <> KUNIVERSE:ACTIVEVESSEL {
        mLogError("FLYBY: coast context changed; existing maneuver retained.").
        yieldToPrompt(). RETURN.
    }
    IF FLYBY_EXIT_SOI > 0 AND SHIP:BODY = target {
        IF SHIP:ORBIT:ECCENTRICITY < 1 {
            mLogError("FLYBY: bound orbit cannot coast to SOI exit.").
            yieldToPrompt(). RETURN.
        }
        LOCAL exitAlarm IS "".
        IF SHIP:ORBIT:HASNEXTPATCH AND SHIP:ORBIT:NEXTPATCHETA > 0 {
            SET exitAlarm TO kacEnsureAlarm("Exit SOI: "+target:NAME,
                TIME:SECONDS+SHIP:ORBIT:NEXTPATCHETA,"Resident flyby coast.",1).
        }
        UNTIL ABORT OR HASNODE OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR SHIP:BODY <> target {
            SET solarRef TO trySolarHoldTick(solarRef).
            _flybySample(target).
            WAIT 60.
        }
        IF exitAlarm <> "" { DELETEALARM(exitAlarm). }
    }
    IF ABORT { RETURN. }
    IF HASNODE OR SHIP <> KUNIVERSE:ACTIVEVESSEL {
        mLogError("FLYBY: coast context changed; existing maneuver retained.").
        yieldToPrompt(). RETURN.
    }
    orbitSummary().
    mLog("STATS flyby result target="+target:NAME+" body="+SHIP:BODY:NAME
        +" remainingDv="+SHIP:DELTAV:VACUUM+" deliveryConfirmed=False").
    LOCAL nextTgt IS FLYBY_NEXT_TARGET.
    IF nextTgt = "" AND target:HASBODY { SET nextTgt TO target:BODY:NAME. }
    IF nextTgt <> "" { stateSet("target",nextTgt). }
    nextPhase(xferSeq).
}
