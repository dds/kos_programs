// Close to a review stand-off, not a docking/contact controller.
@LAZYGLOBAL OFF.
GLOBAL MATCH_FINAL_DIST IS 150.
GLOBAL MATCH_DV_CAP IS 500.
GLOBAL MATCH_RESERVE_DV IS 100.
GLOBAL RENDEZVOUS_TARGET IS "".

LOCAL FUNCTION _matchTargetVessel { RETURN rendezvousTarget(RENDEZVOUS_TARGET). }

LOCAL FUNCTION _matchLive {
    PARAMETER guard.
    LOCAL ves IS guard["OTHER"].
    IF SHIP <> guard["CRAFT"] OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR ves:ISDEAD { RETURN FALSE. }
    RETURN NOT ABORT AND WARP = 0 AND KUNIVERSE:TIMEWARP:ISSETTLED AND NOT HASNODE
        AND SHIP:BODY = ves:BODY AND SHIP:STAGENUM = guard["STAGE"]
        AND ves:THRUST >= 0 AND ves:THRUST <= 0.001
        AND ((ves:POSITION-SHIP:POSITION):MAG > 2000 OR (ves:LOADED AND ves:UNPACKED))
        AND rendezvousSafeOrbit(SHIP:ORBIT) AND rendezvousSafeOrbit(ves:ORBIT)
        AND SHIP:DELTAV:VACUUM >= guard["RESERVE"]
        AND TIME:SECONDS < guard["DEADLINE"] AND SHIP:MASS > 0
        AND (ves:POSITION-SHIP:POSITION):MAG > 50
        AND stateGet("burn_pending","false") <> "true"
        AND stateGet("burn_started","false") <> "true".
}

// Evaluated by LOCK independently of the guidance loop. A stalled publisher,
// loss of context, stage change, impulse cap or bad alignment removes thrust.
LOCAL FUNCTION _matchThrottle {
    PARAMETER command, guard.
    LOCAL nowT IS TIME:SECONDS.
    LOCAL dt IS nowT-guard["SAMPLED"].
    LOCAL acceleration IS SHIP:THRUST/MAX(0.01,SHIP:MASS).
    SET guard["IMPULSE"] TO guard["IMPULSE"]+MAX(0,dt)*(acceleration+guard["LASTACC"])/2.
    SET guard["LASTACC"] TO acceleration. SET guard["SAMPLED"] TO nowT.
    IF NOT _matchLive(guard) OR NOT (acceleration >= 0 AND acceleration < 1e6)
            OR nowT-guard["HEARTBEAT"] > 0.25 OR guard["IMPULSE"] >= guard["CAP"] {
        SET guard["STOP"] TO TRUE. RETURN 0.
    }
    LOCAL delta_ IS guard["DESIRED"]-(SHIP:VELOCITY:ORBIT-guard["OTHER"]:VELOCITY:ORBIT).
    IF NOT (delta_:MAG >= 0 AND delta_:MAG < 1e6) { SET guard["STOP"] TO TRUE. RETURN 0. }
    IF delta_:MAG < 0.1 OR VANG(SHIP:FACING:FOREVECTOR,delta_) > 5 { RETURN 0. }
    LOCAL availableAcc IS SHIP:AVAILABLETHRUST/MAX(0.01,SHIP:MASS).
    IF NOT (availableAcc > 0 AND availableAcc < 1e6) { RETURN 0. }
    RETURN MIN(command,MIN(delta_:MAG,MAX(0,guard["CAP"]-guard["IMPULSE"]))/availableAcc).
}

LOCAL FUNCTION _matchBurnRel {
    PARAMETER ves, desiredVec, cap IS 20, reserve IS 100, report IS 0.
    LOCAL beginUt IS TIME:SECONDS.
    LOCAL guard IS LEX("CRAFT",SHIP,"OTHER",ves,"STAGE",SHIP:STAGENUM,
        "RESERVE",reserve,"DEADLINE",TIME:SECONDS+180,"CAP",cap,
        "IMPULSE",0,"LASTACC",0,"SAMPLED",TIME:SECONDS,
        "HEARTBEAT",TIME:SECONDS,"DESIRED",desiredVec,"STOP",FALSE).
    LOCAL throttleCmd IS 0. LOCAL converged IS FALSE.
    IF NOT _matchLive(guard) OR stateGet("rendezvous_active",FALSE) { RETURN FALSE. }
    // A reboot never resumes a non-node approach pulse automatically.
    stateSet("rendezvous_active",TRUE).
    SET guard["HEARTBEAT"] TO TIME:SECONDS. SET guard["SAMPLED"] TO TIME:SECONDS.
    SAS OFF.
    LOCK THROTTLE TO _matchThrottle(throttleCmd,guard).
    UNTIL guard["STOP"] OR NOT _matchLive(guard) {
        LOCAL errVec IS desiredVec-(SHIP:VELOCITY:ORBIT-ves:VELOCITY:ORBIT).
        IF NOT (errVec:MAG >= 0 AND errVec:MAG < 1e6) { BREAK. }
        IF errVec:MAG < 0.1 { SET converged TO TRUE. BREAK. }
        IF NOT (SHIP:AVAILABLETHRUST > 0 AND SHIP:AVAILABLETHRUST < 1e9) { BREAK. }
        LOCK STEERING TO desiredVec-(SHIP:VELOCITY:ORBIT-ves:VELOCITY:ORBIT).
        SET guard["HEARTBEAT"] TO TIME:SECONDS.
        SET throttleCmd TO 1.
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCAL stopped IS _matchStopThrottle().
    IF converged AND NOT ABORT AND stopped AND NOT guard["STOP"] {
        stateRemove("rendezvous_active").
    }
    LOCAL residual IS -1.
    IF NOT ves:ISDEAD { SET residual TO (desiredVec-(SHIP:VELOCITY:ORBIT-ves:VELOCITY:ORBIT)):MAG. }
    rendezvousLog(report,"STATS match pulse success="+converged+" cutoff="+stopped
        +" watchdog="+guard["STOP"]+" elapsed="+(TIME:SECONDS-beginUt)
        +" impulse="+guard["IMPULSE"]+" cap="+cap
        +" residual="+residual).
    RETURN converged AND NOT ABORT AND stopped AND NOT guard["STOP"].
}

LOCAL FUNCTION _matchStopThrottle {
    LOCAL stopped IS thrustCutoffOk().
    UNLOCK STEERING. SAS ON.
    RETURN stopped.
}

LOCAL FUNCTION _matchHold {
    PARAMETER reason.
    _matchStopThrottle(). mLogError("MATCH held: "+reason+"."). yieldToPrompt().
}

LOCAL FUNCTION _matchConverged {
    PARAMETER separation, relativeSpeed, finalDist.
    RETURN NOT ABORT AND separation <= finalDist AND relativeSpeed < 0.2.
}

GLOBAL FUNCTION matchRendezvous {
    PARAMETER ves, finalDist IS 150, cap IS 500, reserve IS 100, report IS 0.
    LOCAL craftRef IS SHIP.
    IF NOT rendezvousContext(craftRef,ves) OR NOT (finalDist >= 150 AND finalDist <= 1000
            AND cap >= 1 AND cap < 1e6 AND reserve >= 0 AND reserve < 1e6) { RETURN FALSE. }
    LOCAL spent IS 0. LOCAL fuelStart IS SHIP:DELTAV:VACUUM.
    LOCAL sep IS (ves:POSITION-SHIP:POSITION):MAG.
    LOCAL relSpd IS (SHIP:VELOCITY:ORBIT-ves:VELOCITY:ORBIT):MAG.
    IF sep > 5000 OR relSpd > 15 {
        LOCAL ca IS _findClosestApproach(ves,TIME:SECONDS+180,TIME:SECONDS+SHIP:ORBIT:PERIOD*1.5,96).
        LOCAL acc IS SHIP:AVAILABLETHRUST/MAX(0.01,SHIP:MASS).
        IF NOT (acc > 0 AND acc < 1e6) { RETURN FALSE. }
        LOCAL estimatedDv IS (rendezvousVelocity(ves,ca["time"])-rendezvousVelocity(SHIP,ca["time"])):MAG.
        // Brake BEFORE closest approach. A centred burn at CA can carry the
        // chaser through its target before the burn has even finished.
        LOCAL burnUt IS ca["time"]-MAX(60,estimatedDv/acc+30).
        IF burnUt < TIME:SECONDS+180 OR ca["distance"] > 5000 { RETURN FALSE. }
        LOCAL dvVec IS rendezvousVelocity(ves,burnUt)-rendezvousVelocity(SHIP,burnUt).
        IF dvVec:MAG+20 > cap OR SHIP:DELTAV:VACUUM < dvVec:MAG+20+reserve
                OR STAGE:DELTAV:VACUUM < dvVec:MAG+1 { RETURN FALSE. }
        LOCAL nd IS rendezvousNode(burnUt,dvVec,ves).
        IF nd = 0 { RETURN FALSE. }
        LOCAL stamp IS rendezvousStamp(nd).
        IF NOT rendezvousSafeOrbit(nd:ORBIT) {
            rendezvousRelease(craftRef,nd,stamp). RETURN FALSE.
        }
        IF NOT executeManeuver() { RETURN FALSE. }
        SET spent TO dvVec:MAG.
    }
    LOCAL approachPass IS 0.
    UNTIL approachPass >= 8 OR ABORT {
        IF NOT rendezvousContext(craftRef,ves) { RETURN FALSE. }
        SET spent TO MAX(spent,fuelStart-SHIP:DELTAV:VACUUM).
        IF spent+2 > cap { RETURN FALSE. }
        SET sep TO (ves:POSITION-SHIP:POSITION):MAG.
        SET relSpd TO (SHIP:VELOCITY:ORBIT-ves:VELOCITY:ORBIT):MAG.
        IF _matchConverged(sep,relSpd,finalDist) { RETURN TRUE. }
        IF sep < finalDist {
            IF NOT _matchBurnRel(ves,V(0,0,0),MIN(20,cap-spent),reserve,report) { RETURN FALSE. }
            SET spent TO spent+MIN(20,cap-spent).
        } ELSE {
            LOCAL closeSpd IS MIN(5,MAX(0.2,(sep-finalDist)/120)).
            LOCAL direction_ IS (ves:POSITION-SHIP:POSITION):NORMALIZED.
            IF NOT _matchBurnRel(ves,direction_*closeSpd,MIN(20,cap-spent),reserve,report) { RETURN FALSE. }
            SET spent TO spent+MIN(20,cap-spent).
            LOCAL coastEnd IS TIME:SECONDS+MAX(60,2*sep/closeSpd).
            LOCAL alarm IS kacEnsureAlarm("Rendezvous approach review",
                MIN(coastEnd,TIME:SECONDS+MAX(1,(sep-finalDist*0.8)/closeSpd-30)),
                "Resident1x approach; no automatic warp or docking.",1).
            LOCAL previousSep IS sep+1.
            UNTIL ABORT OR TIME:SECONDS >= coastEnd {
                IF NOT rendezvousContext(craftRef,ves) { RETURN FALSE. }
                SET sep TO (ves:POSITION-SHIP:POSITION):MAG.
                // Reserve30s for a main-engine turn before slowing down.
                IF sep <= finalDist*0.8+closeSpd*30 OR sep > previousSep { BREAK. }
                SET previousSep TO sep. WAIT 0.2.
            }
            IF alarm <> "" { DELETEALARM(alarm). }
            SET spent TO MAX(spent,fuelStart-SHIP:DELTAV:VACUUM).
            IF NOT _matchBurnRel(ves,V(0,0,0),MIN(20,cap-spent),reserve,report) { RETURN FALSE. }
            SET spent TO spent+MIN(20,cap-spent).
        }
        SET approachPass TO approachPass+1.
        rendezvousLog(report,"STATS match pass="+approachPass+" sep="+(ves:POSITION-SHIP:POSITION):MAG
            +" relV="+(SHIP:VELOCITY:ORBIT-ves:VELOCITY:ORBIT):MAG).
    }
    RETURN FALSE.
}

GLOBAL FUNCTION phaseMatch {
    LOCAL ves IS _matchTargetVessel().
    IF ves = 0 { _matchHold("no unique rendezvous target"). RETURN. }
    IF NOT matchRendezvous(ves,MATCH_FINAL_DIST,MATCH_DV_CAP,MATCH_RESERVE_DV) {
        _matchHold("distance, velocity, context or budget check failed; inspect retained burn"). RETURN.
    }
    mLog("STATS match result sep="+(ves:POSITION-SHIP:POSITION):MAG
        +" relV="+(SHIP:VELOCITY:ORBIT-ves:VELOCITY:ORBIT):MAG+" target="+ves:NAME).
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseCrewXfer {
    LOCAL startCount IS stateGetNum("crew_xfer_start", -1).
    IF startCount < 0 {
        SET startCount TO SHIP:CREW():LENGTH.
        stateSet("crew_xfer_start", startCount).
    }
    IF SHIP:CREW():LENGTH > startCount {
        mLog("CREW_XFER: crew aboard (" + SHIP:CREW():LENGTH + ").").
    } ELSE {
        PRINT " ".
        PRINT "  CREW TRANSFER".
        PRINT "  EVA the rescued kerbal to this ship.".
        mLog("CREW_XFER: waiting for crew count > " + startCount + ".").
        LOCAL nextHud IS 0.
        UNTIL SHIP:CREW():LENGTH > startCount {
            IF TIME:SECONDS > nextHud {
                HUDTEXT("Awaiting crew transfer ("
                    + SHIP:CREW():LENGTH + "/" + (startCount + 1) + ")",
                    15, 2, 16, YELLOW, FALSE).
                SET nextHud TO TIME:SECONDS + 15.
            }
            WAIT 1.
        }
    }
    LOCAL roster IS "".
    FOR crewMember IN SHIP:CREW() {
        SET roster TO roster + crewMember:NAME + " ".
    }
    mLog("STATS crew_xfer result count=" + SHIP:CREW():LENGTH
        + " roster=" + roster:TRIM).
    stateRemove("crew_xfer_start").
    nextPhase(xferSeq).
}
