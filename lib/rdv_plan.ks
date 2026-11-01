// Bounded same-body rendezvous. Native node validation follows a Lambert
// shortlist; budget BOTH departure and velocity matching. No blind retries.
@LAZYGLOBAL OFF.
GLOBAL RDV_MAX_CA IS 5000.
GLOBAL RDV_MAX_RADIUS_ERR IS 2000.
GLOBAL RDV_DV_CAP IS 500.
GLOBAL RDV_RESERVE_DV IS 100.
GLOBAL RENDEZVOUS_TARGET IS "".
GLOBAL ASTEROID_TARGET IS "".

LOCAL FUNCTION _rdvShortlist {
    PARAMETER candidates, item.
    LOCAL slot IS 0.
    UNTIL slot >= candidates:LENGTH {
        IF item["COST"] < candidates[slot]["COST"] { BREAK. }
        SET slot TO slot+1.
    }
    IF slot < 8 { candidates:INSERT(slot,item). }
    IF candidates:LENGTH > 8 { candidates:REMOVE(8). }
}

GLOBAL FUNCTION rendezvousAffordable {
    PARAMETER departDv, brakeDv, cap, reserve.
    RETURN departDv >= 0.3 AND departDv < 1e30 AND brakeDv >= 0 AND brakeDv < 1e30
        AND departDv+brakeDv+10 <= cap
        AND SHIP:DELTAV:VACUUM >= departDv+brakeDv+10+reserve
        AND STAGE:DELTAV:VACUUM >= departDv+1
        AND SHIP:AVAILABLETHRUST > 0 AND SHIP:MASS > 0.
}

// Leaves one inspection node only on success. Never burns, stages or changes
// the selected mission. Eight native trials maximum, 20 game/30 wall seconds.
GLOBAL FUNCTION rendezvousSearch {
    PARAMETER other, cap IS 500, reserve IS 100, report IS 0.
    LOCAL craftRef IS SHIP.
    LOCAL failed IS LEX("OK",FALSE,"REASON","context-or-budget").
    IF NOT rendezvousContext(craftRef,other) OR NOT (cap >= 0.3 AND cap < 1e6
            AND reserve >= 0 AND reserve < 1e6) { RETURN failed. }
    LOCAL epoch IS TIME:SECONDS. LOCAL stopUt IS epoch+20.
    LOCAL stopWall IS KUNIVERSE:REALTIME+30.
    LOCAL period_ IS MAX(SHIP:ORBIT:PERIOD,other:ORBIT:PERIOD).
    LOCAL candidates IS LIST(). LOCAL evaluated IS 0.
    LOCAL minimumCost IS 1e30.
    // Single-revolution arcs; scan departures over two periods, then refine
    // the chosen native encounter on a later explicit operator pass if needed.
    FOR departIndex IN RANGE(0,12) {
        LOCAL departUt IS epoch+300+period_*departIndex/6.
        LOCAL startPos IS POSITIONAT(SHIP,departUt)-POSITIONAT(SHIP:BODY,departUt).
        LOCAL startVel IS rendezvousVelocity(SHIP,departUt).
        FOR timeIndex IN RANGE(0,8) {
            IF TIME:SECONDS >= stopUt OR KUNIVERSE:REALTIME >= stopWall
                    OR NOT rendezvousContext(craftRef,other) {
                SET failed["REASON"] TO "context-or-deadline". RETURN failed.
            }
            LOCAL tof IS period_*(0.2+timeIndex*0.15).
            LOCAL arriveUt IS departUt+tof.
            LOCAL endPos IS POSITIONAT(other,arriveUt)-POSITIONAT(SHIP:BODY,arriveUt).
            LOCAL endVel IS rendezvousVelocity(other,arriveUt).
            // Aim500m radially outside the target, never its centre of mass.
            SET endPos TO endPos+endPos:NORMALIZED*500.
            IF (startPos-endPos):MAG > 1 AND VCRS(startPos,endPos):MAG > startPos:MAG*endPos:MAG*0.00001 {
                FOR flip_ IN LIST(FALSE,TRUE) {
                    LOCAL sol IS lambertSolve(startPos,endPos,tof,SHIP:BODY:MU,flip_).
                    LOCAL dvVec IS sol["v1"]-startVel.
                    LOCAL brakeDv IS (endVel-sol["v2"]):MAG.
                    LOCAL cost IS dvVec:MAG+brakeDv+10.
                    IF cost >= 0 AND cost < minimumCost { SET minimumCost TO cost. }
                    IF rendezvousAffordable(dvVec:MAG,brakeDv,cap,reserve) {
                        _rdvShortlist(candidates,LEX("UT",departUt,"ARRIVE",arriveUt,
                            "DV",dvVec,"BRAKE",brakeDv,"COST",cost)).
                    }
                    SET evaluated TO evaluated+1.
                }
            }
        }
        WAIT 0.
    }
    rendezvousLog(report,"STATS rdv search lambertTrials="+evaluated+" shortlisted="+candidates:LENGTH
        +" minimumCost="+minimumCost+" cap="+cap+" reserve="+reserve).
    FOR item IN candidates {
        IF TIME:SECONDS >= stopUt OR KUNIVERSE:REALTIME >= stopWall
                OR NOT rendezvousContext(craftRef,other) {
            SET failed["REASON"] TO "context-or-deadline". RETURN failed.
        }
        LOCAL nd IS rendezvousNode(item["UT"],item["DV"],other).
        IF nd = 0 { SET failed["REASON"] TO "native-vector-or-context". RETURN failed. }
        LOCAL stamp IS rendezvousStamp(nd).
        LOCAL ca IS _findClosestApproach(other,MAX(nd:TIME+1,item["ARRIVE"]-period_*0.1),
            item["ARRIVE"]+period_*0.1,24).
        LOCAL sep IS ca["distance"].
        LOCAL brakeDv IS (rendezvousVelocity(SHIP,ca["time"])-rendezvousVelocity(other,ca["time"])):MAG.
        LOCAL radiusErr IS ABS((POSITIONAT(SHIP,ca["time"])-POSITIONAT(SHIP:BODY,ca["time"])):MAG
            -(POSITIONAT(other,ca["time"])-POSITIONAT(SHIP:BODY,ca["time"])):MAG).
        LOCAL accepted IS rendezvousSafeOrbit(nd:ORBIT)
            AND sep >= 100 AND sep <= RDV_MAX_CA AND radiusErr <= RDV_MAX_RADIUS_ERR
            AND rendezvousAffordable(nd:DELTAV:MAG,brakeDv,cap,reserve)
            AND nd:ETA > 180+nd:DELTAV:MAG/(SHIP:AVAILABLETHRUST/SHIP:MASS)
            AND TIME:SECONDS < stopUt AND KUNIVERSE:REALTIME < stopWall.
        rendezvousLog(report,"STATS rdv candidate dv="+nd:DELTAV:MAG+" matchDv="+brakeDv
            +" ca="+sep+" caUt="+ca["time"]+" radiusErr="+radiusErr+" accepted="+accepted).
        IF NOT rendezvousOwned(craftRef,nd,stamp) { SET failed["REASON"] TO "node-changed". RETURN failed. }
        IF accepted AND rendezvousContext(craftRef,other,TRUE) {
            RETURN LEX("OK",TRUE,"REASON","native-validated","NODE",nd,"STAMP",stamp,
                "CA",sep,"CAUT",ca["time"],"BRAKE",brakeDv,"CAP",cap,"RESERVE",reserve).
        }
        IF NOT rendezvousRelease(craftRef,nd,stamp) { SET failed["REASON"] TO "node-changed". RETURN failed. }
    }
    SET failed["REASON"] TO "no-affordable-native-intercept".
    RETURN failed.
}

GLOBAL FUNCTION planRendezvous {
    PARAMETER targetVessel.
    LOCAL result IS rendezvousSearch(targetVessel,RDV_DV_CAP,RDV_RESERVE_DV).
    IF NOT result["OK"] { mLogError("RDV: "+result["REASON"]). RETURN 0. }
    RETURN result["NODE"].
}

GLOBAL FUNCTION phaseRendezvous {
    LOCAL name IS RENDEZVOUS_TARGET.
    IF ASTEROID_TARGET <> "" { SET name TO ASTEROID_TARGET. }
    LOCAL other IS rendezvousTarget(name).
    IF other = 0 { mLogError("RDV: select one uniquely named vessel target."). yieldToPrompt(). RETURN. }
    LOCAL nd IS planRendezvous(other).
    IF nd = 0 { yieldToPrompt(). RETURN. }
    // Failed/interrupted attempts belong to their executor. Preserve them
    // for review instead of deleting their node and trying another burn.
    IF NOT executeManeuver() { yieldToPrompt(). RETURN. }
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseRdv { phaseRendezvous(). }
