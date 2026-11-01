// Same-body relative geometry shared by planning and docking rehearsals.
@LAZYGLOBAL OFF.

// Archive-only diagnostics are supplied by manual callers; flight phases
// keep their existing boot log. Never call this while publishing thrust.
GLOBAL FUNCTION rendezvousLog {
    PARAMETER report, row.
    IF report <> 0 { diagnosticArchiveLine(report,row). }
    ELSE { mLog(row). }
}

GLOBAL FUNCTION rendezvousTarget {
    PARAMETER name IS "".
    IF name = "" {
        IF HASTARGET AND TARGET:ISTYPE("Vessel") { SET name TO TARGET:NAME. }
    }
    IF name = "" { RETURN 0. }
    LOCAL candidates IS LIST(). LIST TARGETS IN candidates.
    LOCAL found IS 0. LOCAL count IS 0.
    FOR candidate IN candidates {
        IF candidate:NAME = name AND candidate <> SHIP {
            SET found TO candidate. SET count TO count + 1.
        }
    }
    IF count <> 1 { RETURN 0. }
    RETURN found.
}

GLOBAL FUNCTION rendezvousFloor {
    LOCAL floor_ IS 10000.
    IF SHIP:BODY:ATM:EXISTS { SET floor_ TO SHIP:BODY:ATM:HEIGHT + 10000. }
    RETURN floor_.
}

GLOBAL FUNCTION rendezvousSafeOrbit {
    PARAMETER obt_.
    RETURN obt_:BODY = SHIP:BODY AND NOT obt_:HASNEXTPATCH
        AND obt_:ECCENTRICITY >= 0 AND obt_:ECCENTRICITY < 1
        AND obt_:PERIAPSIS >= rendezvousFloor()
        AND obt_:PERIOD > 0 AND obt_:PERIOD < 1e30.
}

GLOBAL FUNCTION rendezvousContext {
    PARAMETER craftRef, other, occupied IS FALSE, background IS FALSE.
    IF SHIP <> craftRef OR other:ISDEAD OR other = SHIP OR other:BODY <> SHIP:BODY { RETURN FALSE. }
    IF NOT background AND SHIP <> KUNIVERSE:ACTIVEVESSEL { RETURN FALSE. }
    // Maneuver suffixes are only accessible on the active vessel.
    IF SHIP = KUNIVERSE:ACTIVEVESSEL {
        IF HASNODE <> occupied OR (occupied AND ALLNODES:LENGTH <> 1) { RETURN FALSE. }
    } ELSE IF occupied { RETURN FALSE. }
    RETURN NOT ABORT AND WARP = 0 AND KUNIVERSE:TIMEWARP:ISSETTLED
        AND stateGet("burn_pending","false") <> "true"
        AND stateGet("burn_started","false") <> "true"
        AND NOT stateGet("rendezvous_active",FALSE)
        AND rendezvousSafeOrbit(SHIP:ORBIT) AND rendezvousSafeOrbit(other:ORBIT)
        AND SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
        AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

// Differentiate positions relative to the SAME body at each sample epoch.
// Never subtract VELOCITYAT values from different moving frames.
GLOBAL FUNCTION rendezvousVelocity {
    PARAMETER ves, epoch.
    LOCAL after_ IS POSITIONAT(ves,epoch+0.5) - POSITIONAT(ves:BODY,epoch+0.5).
    LOCAL before_ IS POSITIONAT(ves,epoch-0.5) - POSITIONAT(ves:BODY,epoch-0.5).
    RETURN after_ - before_.
}

GLOBAL FUNCTION rendezvousStamp {
    PARAMETER nd.
    RETURN LIST(nd:TIME,nd:RADIALOUT,nd:NORMAL,nd:PROGRADE).
}

GLOBAL FUNCTION rendezvousOwned {
    PARAMETER craftRef, nd, stamp.
    IF SHIP <> craftRef OR SHIP <> KUNIVERSE:ACTIVEVESSEL { RETURN FALSE. }
    RETURN HASNODE AND ALLNODES:LENGTH = 1 AND NEXTNODE = nd
        AND ABS(nd:TIME-stamp[0]) < 0.000001
        AND ABS(nd:RADIALOUT-stamp[1]) < 0.000001
        AND ABS(nd:NORMAL-stamp[2]) < 0.000001
        AND ABS(nd:PROGRADE-stamp[3]) < 0.000001.
}

GLOBAL FUNCTION rendezvousRelease {
    PARAMETER craftRef, nd, stamp.
    IF NOT rendezvousOwned(craftRef,nd,stamp) { RETURN FALSE. }
    REMOVE nd. WAIT 0.02.
    RETURN SHIP = craftRef AND SHIP = KUNIVERSE:ACTIVEVESSEL AND NOT HASNODE.
}

// Ask the native node for its three unit axes: no guessed cross-product
// signs, and no reliance on the normal convention of another orbit.
// Requires a stopped, active, node-free vessel on entry. Returns attached node.
GLOBAL FUNCTION rendezvousNode {
    PARAMETER burnUt, dvVec, other.
    LOCAL craftRef IS SHIP.
    IF NOT rendezvousContext(craftRef,other) OR NOT (dvVec:MAG > 0 AND dvVec:MAG < 1e6)
            OR NOT (burnUt > TIME:SECONDS + 60 AND burnUt < 1e30) { RETURN 0. }
    LOCAL nd IS NODE(burnUt,1,0,0). ADD nd.
    LOCAL stamp IS rendezvousStamp(nd). WAIT 0.02.
    IF NOT rendezvousOwned(craftRef,nd,stamp) { RETURN 0. }
    LOCAL radialAxis IS nd:DELTAV.
    SET nd:RADIALOUT TO 0. SET nd:NORMAL TO 1.
    LOCAL normalAxis IS nd:DELTAV.
    SET nd:NORMAL TO 0. SET nd:PROGRADE TO 1.
    LOCAL proAxis IS nd:DELTAV.
    SET nd:RADIALOUT TO VDOT(dvVec,radialAxis).
    SET nd:NORMAL TO VDOT(dvVec,normalAxis).
    SET nd:PROGRADE TO VDOT(dvVec,proAxis).
    SET stamp TO rendezvousStamp(nd). WAIT 0.02.
    IF NOT rendezvousOwned(craftRef,nd,stamp) { RETURN 0. }
    IF NOT rendezvousContext(craftRef,other,TRUE)
            OR NOT ((nd:DELTAV-dvVec):MAG <= MAX(0.001,dvVec:MAG*0.00001)) {
        rendezvousRelease(craftRef,nd,stamp). RETURN 0.
    }
    RETURN nd.
}

