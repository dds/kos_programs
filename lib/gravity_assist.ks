// Bounded refinement of an existing native encounter itinerary. Preview only.
// Route is an ordered list: flybys, then one powered orbit-capture goal.
// Body names are data; repeated parents/moons support later tour legs.
@LAZYGLOBAL OFF.
GLOBAL ASSIST_MAX_TRIALS IS 48.
GLOBAL ASSIST_PLAN_SECONDS IS 30.
GLOBAL ASSIST_MIN_GAIN IS 25.
GLOBAL ASSIST_DV_CAP IS 50.
GLOBAL ASSIST_RESERVE_DV IS 100.

LOCAL FUNCTION _assistOwned {
    PARAMETER nd.
    RETURN HASNODE AND NEXTNODE = nd AND ALLNODES:CONTAINS(nd).
}

LOCAL FUNCTION _assistRelease {
    PARAMETER nd.
    IF ALLNODES:CONTAINS(nd) { REMOVE nd. }
}

LOCAL FUNCTION _assistBody {
    PARAMETER name.
    LOCAL bodies IS LIST().
    LIST BODIES IN bodies.
    FOR candidate IN bodies { IF candidate:NAME = name { RETURN candidate. } }
    RETURN 0.
}

LOCAL FUNCTION _assistAncestor {
    PARAMETER ancestor.
    PARAMETER descendant.
    LOCAL cursor IS descendant.
    UNTIL NOT cursor:HASBODY {
        SET cursor TO cursor:BODY.
        IF cursor = ancestor { RETURN TRUE. }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION assistRouteBodies {
    PARAMETER route.
    LOCAL bodies IS LIST().
    IF route:LENGTH < 2 OR route:LENGTH > 8 { RETURN bodies. }
    LOCAL index IS 0.
    FOR leg IN route {
        IF NOT leg:HASKEY("BODY") OR NOT leg:HASKEY("MIN_PE") { RETURN LIST(). }
        LOCAL candidate IS _assistBody(leg["BODY"]).
        IF candidate = 0 { RETURN LIST(). }
        IF NOT (candidate:MU > 0 AND candidate:MU < 1e30) { RETURN LIST(). }
        LOCAL floorPe IS 0.
        IF candidate:ATM:EXISTS { SET floorPe TO candidate:ATM:HEIGHT. }
        IF NOT (leg["MIN_PE"] > floorPe AND leg["MIN_PE"] < candidate:SOIRADIUS-candidate:RADIUS) { RETURN LIST(). }
        IF index = route:LENGTH-1 {
            IF NOT leg:HASKEY("AP") { RETURN LIST(). }
            IF NOT (leg["AP"] >= leg["MIN_PE"] AND leg["AP"] < candidate:SOIRADIUS-candidate:RADIUS) { RETURN LIST(). }
        }
        bodies:ADD(candidate).
        SET index TO index+1.
    }
    RETURN bodies.
}

// Every scored event must occur on the actual finite native patch. Parent
// transits conservatively require safe Pe even if truncated before that Pe.
// No extrapolated post-moon orbit or invisible future encounter earns credit.
GLOBAL FUNCTION assistEvaluate {
    PARAMETER nd.
    PARAMETER route.
    PARAMETER bodies.
    LOCAL rejected IS LEXICON("OK",FALSE,"REASON","incomplete-itinerary").
    LOCAL patch IS nd:ORBIT.
    LOCAL entryUt IS MAX(TIME:SECONDS,nd:TIME).
    LOCAL legIndex IS 0.
    LOCAL depth IS 0.
    LOCAL report IS LIST().
    UNTIL depth >= 24 OR ABORT {
        IF patch:BODY = bodies[legIndex] {
            LOCAL leg IS route[legIndex].
            LOCAL peUt IS arrivalPatchPeUt(patch,entryUt).
            IF NOT (peUt > entryUt AND patch:PERIAPSIS >= leg["MIN_PE"]
                    AND patch:PERIAPSIS < patch:BODY:SOIRADIUS-patch:BODY:RADIUS) {
                SET rejected["REASON"] TO "unsafe-or-truncated-periapsis". RETURN rejected.
            }
            IF leg:HASKEY("MAX_PE") {
                IF NOT (patch:PERIAPSIS <= leg["MAX_PE"]) { RETURN rejected. }
            }
            IF leg:HASKEY("INC") {
                IF NOT (ABS(patch:INCLINATION-leg["INC"]) <= 0.5) {
                    SET rejected["REASON"] TO "required-plane". RETURN rejected.
                }
            }
            report:ADD(LEXICON("BODY",patch:BODY:NAME,"PE",patch:PERIAPSIS,"ENTRY",entryUt,"PE_UT",peUt)).
            IF legIndex = route:LENGTH-1 {
                LOCAL rp IS patch:BODY:RADIUS+patch:PERIAPSIS.
                LOCAL ra IS patch:BODY:RADIUS+leg["AP"].
                IF ra < rp OR NOT (patch:ECCENTRICITY >= 0 AND patch:ECCENTRICITY < 1e30) { RETURN rejected. }
                LOCAL incoming IS SQRT(patch:BODY:MU*(1+patch:ECCENTRICITY)/rp).
                LOCAL captured IS SQRT(patch:BODY:MU*(2/rp-2/(rp+ra))).
                LOCAL captureDv IS ABS(incoming-captured).
                RETURN LEXICON("OK",TRUE,"REASON","native-itinerary",
                    "COST",nd:DELTAV:MAG+captureDv,"CAPTURE_DV",captureDv,"LEGS",report).
            }
            // An unpowered flyby needs an outgoing patch; bound moon orbits
            // cannot masquerade as free assistance into the next tour leg.
            IF NOT (patch:ECCENTRICITY > 1) { RETURN rejected. }
            SET legIndex TO legIndex+1.
        } ELSE {
            IF NOT _assistAncestor(patch:BODY,bodies[legIndex]) { RETURN rejected. }
            LOCAL floorPe IS 0.
            IF patch:BODY:ATM:EXISTS { SET floorPe TO patch:BODY:ATM:HEIGHT. }
            IF NOT (patch:PERIAPSIS > floorPe) {
                SET rejected["REASON"] TO "unsafe-parent-transit". RETURN rejected.
            }
        }
        IF NOT patch:HASNEXTPATCH { RETURN rejected. }
        LOCAL nextUt IS TIME:SECONDS+patch:NEXTPATCHETA.
        IF NOT (nextUt > entryUt AND nextUt < 1e30) { RETURN rejected. }
        SET entryUt TO nextUt.
        SET patch TO patch:NEXTPATCH.
        SET depth TO depth+1.
    }
    RETURN rejected.
}

LOCAL FUNCTION _assistIdle {
    RETURN NOT ABORT AND WARP = 0 AND NOT maneuverBurnInterrupted()
        AND (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING" OR SHIP:STATUS = "SUB_ORBITAL")
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

GLOBAL FUNCTION planAssistRefinement {
    PARAMETER route.
    LOCAL none IS LEXICON("OK",FALSE,"REASON","unsafe-planning-context").
    IF HASNODE OR NOT _assistIdle() { RETURN none. }
    LOCAL bodies IS assistRouteBodies(route).
    IF bodies:LENGTH < 2 OR bodies:LENGTH <> route:LENGTH { SET none["REASON"] TO "invalid-route". RETURN none. }
    IF NOT (ASSIST_DV_CAP > 0 AND ASSIST_DV_CAP < 1e30
            AND ASSIST_MIN_GAIN > 0 AND ASSIST_MIN_GAIN < 1e30
            AND ASSIST_RESERVE_DV >= 0 AND ASSIST_RESERVE_DV < 1e30
            AND ASSIST_MAX_TRIALS >= 2 AND ASSIST_MAX_TRIALS <= 96
            AND ASSIST_PLAN_SECONDS > 0 AND ASSIST_PLAN_SECONDS <= 120) { RETURN none. }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF HASNODE OR NOT _assistIdle() { RETURN none. }
    LOCAL duration IS arrivalBurnSeconds(ASSIST_DV_CAP).
    IF duration < 0 { RETURN none. }
    LOCAL epoch IS TIME:SECONDS+MAX(600,duration/2+180).
    // Keep the complete burn in this frame; never plan through the first SOI.
    IF NOT SHIP:ORBIT:HASNEXTPATCH { SET none["REASON"] TO "no-native-opportunity". RETURN none. }
    IF NOT (epoch+duration/2+120 < TIME:SECONDS+SHIP:ORBIT:NEXTPATCHETA) { RETURN none. }
    LOCAL nd IS NODE(epoch,0,0,0).
    ADD nd.
    WAIT 0.1.
    IF NOT _assistOwned(nd) { _assistRelease(nd). RETURN none. }
    LOCAL baseline IS assistEvaluate(nd,route,bodies).
    IF NOT baseline["OK"] {
        REMOVE nd.
        SET none["REASON"] TO "no-complete-native-seed". RETURN none.
    }
    LOCAL best IS baseline.
    LOCAL axes IS LIST(0,0,0).
    LOCAL stepDv IS ASSIST_DV_CAP/2.
    LOCAL trials IS 1.
    LOCAL deadline IS TIME:SECONDS+ASSIST_PLAN_SECONDS.
    UNTIL trials >= ASSIST_MAX_TRIALS-1 OR TIME:SECONDS >= deadline OR stepDv < 0.1 OR NOT _assistIdle() {
        IF NOT HASNODE OR NEXTNODE <> nd { BREAK. }
        LOCAL improved IS FALSE.
        LOCAL axis IS 0.
        UNTIL axis >= 3 OR trials >= ASSIST_MAX_TRIALS-1 OR TIME:SECONDS >= deadline OR NOT _assistIdle() {
            FOR sign IN LIST(-1,1) {
                IF trials >= ASSIST_MAX_TRIALS-1 OR TIME:SECONDS >= deadline OR NOT _assistIdle() { BREAK. }
                SET nd:RADIALOUT TO axes[0]. SET nd:NORMAL TO axes[1]. SET nd:PROGRADE TO axes[2].
                IF axis = 0 { SET nd:RADIALOUT TO axes[0]+sign*stepDv. }
                IF axis = 1 { SET nd:NORMAL TO axes[1]+sign*stepDv. }
                IF axis = 2 { SET nd:PROGRADE TO axes[2]+sign*stepDv. }
                IF nd:DELTAV:MAG <= ASSIST_DV_CAP {
                    WAIT 0.1.
                    IF NOT _assistOwned(nd) { _assistRelease(nd). RETURN none. }
                    LOCAL candidate IS assistEvaluate(nd,route,bodies).
                    SET trials TO trials+1.
                    IF candidate["OK"] {
                        IF candidate["COST"] < best["COST"] {
                            SET best TO candidate.
                            SET axes TO LIST(nd:RADIALOUT,nd:NORMAL,nd:PROGRADE).
                            SET improved TO TRUE.
                        }
                    }
                }
            }
            SET axis TO axis+1.
        }
        IF NOT improved { SET stepDv TO stepDv/2. }
    }
    IF NOT HASNODE OR NEXTNODE <> nd {
        _assistRelease(nd).
        SET none["REASON"] TO "node-ownership-changed". RETURN none.
    }
    SET nd:RADIALOUT TO axes[0]. SET nd:NORMAL TO axes[1]. SET nd:PROGRADE TO axes[2].
    WAIT 0.1.
    IF NOT _assistOwned(nd) { _assistRelease(nd). RETURN none. }
    LOCAL final IS assistEvaluate(nd,route,bodies).
    IF NOT _assistIdle() OR NOT HASNODE OR NEXTNODE <> nd OR NOT final["OK"] {
        REMOVE nd. RETURN none.
    }
    IF NOT (nd:DELTAV:MAG > 0.3 AND final["COST"]+ASSIST_MIN_GAIN <= baseline["COST"]
            AND final["COST"]+ASSIST_RESERVE_DV <= SHIP:DELTAV:VACUUM
            AND nd:TIME-duration/2 > TIME:SECONDS+30) {
        REMOVE nd.
        SET none["REASON"] TO "no-useful-affordable-improvement". RETURN none.
    }
    SET final["NODE"] TO nd.
    SET final["BASELINE_COST"] TO baseline["COST"].
    SET final["TRIALS"] TO trials+1.
    mLogSummary("STATS assist preview trials=" + (trials+1) + " baselineDv=" + baseline["COST"]
        + " candidateDv=" + final["COST"] + " correctionDv=" + nd:DELTAV:MAG + " noBurn=True").
    RETURN final.
}
