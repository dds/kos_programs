// ============================================================
// maneuver_rendezvous.ks - Close approach and crew transfer phases
// (0:/lib/maneuver_rendezvous.ks)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL MATCH_FINAL_DIST IS 150.
GLOBAL RENDEZVOUS_TARGET IS "".

LOCAL FUNCTION _nodeFromDvVector {
    PARAMETER burnUt.
    PARAMETER dvVec.
    LOCAL r1 IS POSITIONAT(SHIP, burnUt) - POSITIONAT(SHIP:BODY, burnUt).
    LOCAL progradeHat IS VELOCITYAT(SHIP, burnUt):ORBIT:NORMALIZED.
    LOCAL normalHat IS VCRS(r1, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(normalHat, progradeHat):NORMALIZED.
    LOCAL dvPro IS VDOT(dvVec, progradeHat).
    LOCAL dvNor IS VDOT(dvVec, normalHat).
    LOCAL dvRad IS VDOT(dvVec, radialHat).
    RETURN NODE(burnUt, dvRad, dvNor, dvPro).
}

LOCAL FUNCTION _matchTargetVessel {
    LOCAL nm IS "".
    SET nm TO RENDEZVOUS_TARGET.
    IF nm = "" AND HASTARGET AND TARGET:ISTYPE("Vessel") {
        SET nm TO TARGET:NAME.
    }
    IF nm = "" { RETURN 0. }
    LOCAL vs IS LIST().
    LIST TARGETS IN vs.
    FOR tv IN vs {
        IF tv:NAME = nm { RETURN tv. }
    }
    RETURN 0.
}

LOCAL FUNCTION _matchBurnRel {
    PARAMETER ves.
    PARAMETER desiredVec.
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL deadline IS TIME:SECONDS + 180.
    UNTIL TIME:SECONDS > deadline {
        LOCAL errVec IS desiredVec - (SHIP:VELOCITY:ORBIT - ves:VELOCITY:ORBIT).
        IF errVec:MAG < 0.2 { BREAK. }
        LOCK STEERING TO errVec.
        IF VANG(SHIP:FACING:FOREVECTOR, errVec) < 5 {
            LOCAL acc IS MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
            SET throttleCmd TO MIN(1, MAX(0.02, errVec:MAG / acc / 0.8)).
        } ELSE {
            SET throttleCmd TO 0.
        }
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
}

GLOBAL FUNCTION phaseMatch {
    LOCAL ves IS _matchTargetVessel().
    IF NOT ves:ISTYPE("Vessel") {
        mLogWarn("MATCH: no rendezvous target found - skipping.").
        nextPhase(xferSeq).
        RETURN.
    }
    SET TARGET TO ves.
    LOCAL finalDist IS 150.
    SET finalDist TO MATCH_FINAL_DIST.

    LOCAL sep IS (ves:POSITION - SHIP:POSITION):MAG.
    LOCAL relSpd IS (SHIP:VELOCITY:ORBIT - ves:VELOCITY:ORBIT):MAG.
    mLog("MATCH: " + ves:NAME + " sep=" + ROUND(sep / 1000, 2)
        + "km relV=" + ROUND(relSpd, 1) + " m/s.").
    IF sep > 5000 OR relSpd > 15 {
        LOCAL ca IS _findClosestApproach(ves, TIME:SECONDS + 60,
            TIME:SECONDS + SHIP:ORBIT:PERIOD * 1.5, 120).
        LOCAL caT IS ca["time"].
        LOCAL dvVec IS VELOCITYAT(ves, caT):ORBIT - VELOCITYAT(SHIP, caT):ORBIT.
        mLog("MATCH: brake at CA in " + ROUND(caT - TIME:SECONDS, 0)
            + "s  dist=" + ROUND(ca["distance"] / 1000, 2)
            + "km  dv=" + ROUND(dvVec:MAG, 1) + " m/s.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        ADD _nodeFromDvVector(caT, dvVec).
        IF NOT executeManeuver() {
            mLogError("MATCH: brake burn failed - holding.").
            yieldToPrompt().
            RETURN.
        }
    }

    SAS OFF.
    LOCAL pass IS 0.
    UNTIL pass >= 5 {
        SET pass TO pass + 1.
        SET sep TO (ves:POSITION - SHIP:POSITION):MAG.
        IF sep < finalDist { BREAK. }
        LOCAL closeSpd IS MIN(15, MAX(1, sep / 120)).
        LOCAL approachDir IS (ves:POSITION - SHIP:POSITION):NORMALIZED.
        mLog("MATCH: approach pass " + pass + " sep="
            + ROUND(sep, 0) + "m at " + ROUND(closeSpd, 1) + " m/s.").
        _matchBurnRel(ves, approachDir * closeSpd).

        LOCAL lastSep IS sep + 1.
        UNTIL FALSE {
            SET sep TO (ves:POSITION - SHIP:POSITION):MAG.
            IF sep < finalDist OR sep > lastSep { BREAK. }
            SET lastSep TO sep.
            WAIT 1.
        }
        _matchBurnRel(ves, V(0, 0, 0)).
    }

    SET sep TO (ves:POSITION - SHIP:POSITION):MAG.
    SET relSpd TO (SHIP:VELOCITY:ORBIT - ves:VELOCITY:ORBIT):MAG.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLog("MATCH complete: sep=" + ROUND(sep, 0) + "m relV="
        + ROUND(relSpd, 2) + " m/s.").
    mLog("STATS match result sep=" + ROUND(sep, 0)
        + " relV=" + ROUND(relSpd, 2) + " target=" + ves:NAME).
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
