// Native ordered flyby/arrival validation shared by previews and flight coasts.
@LAZYGLOBAL OFF.

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
        LOCAL mode IS "FLYBY".
        IF index = route:LENGTH-1 { SET mode TO assistGoalMode(route). }
        IF mode = "ENTRY" { SET floorPe TO 0. }
        IF NOT (leg["MIN_PE"] > floorPe AND leg["MIN_PE"] < candidate:SOIRADIUS-candidate:RADIUS) { RETURN LIST(). }
        IF index = route:LENGTH-1 {
            IF mode = "ORBIT" {
                IF NOT leg:HASKEY("AP") { RETURN LIST(). }
                IF NOT (leg["AP"] >= leg["MIN_PE"] AND leg["AP"] < candidate:SOIRADIUS-candidate:RADIUS) { RETURN LIST(). }
            } ELSE IF mode = "ENTRY" {
                IF NOT candidate:ATM:EXISTS OR NOT leg:HASKEY("MAX_PE") { RETURN LIST(). }
                IF NOT (leg["MAX_PE"] < candidate:ATM:HEIGHT) { RETURN LIST(). }
            } ELSE { RETURN LIST(). }
        } ELSE IF leg:HASKEY("MODE") {
            IF leg["MODE"] <> "FLYBY" { RETURN LIST(). }
        }
        IF leg:HASKEY("MAX_PE") {
            IF NOT (leg["MAX_PE"] >= leg["MIN_PE"] AND leg["MAX_PE"] < candidate:SOIRADIUS-candidate:RADIUS) { RETURN LIST(). }
        }
        IF leg:HASKEY("INC") {
            IF NOT (leg["INC"] >= 0 AND leg["INC"] <= 180) { RETURN LIST(). }
        }
        bodies:ADD(candidate).
        SET index TO index+1.
    }
    RETURN bodies.
}

GLOBAL FUNCTION assistGoalMode {
    PARAMETER route.
    LOCAL goal IS route[route:LENGTH-1].
    IF goal:HASKEY("MODE") { RETURN goal["MODE"]. }
    RETURN "ORBIT".
}

// Geometry only: also usable for a physically observed, just-passed flyby.
GLOBAL FUNCTION assistLegClear {
    PARAMETER patch.
    PARAMETER leg.
    IF NOT (patch:PERIAPSIS >= leg["MIN_PE"]
            AND patch:PERIAPSIS < patch:BODY:SOIRADIUS-patch:BODY:RADIUS
            AND patch:ECCENTRICITY >= 0 AND patch:ECCENTRICITY < 1e30) { RETURN FALSE. }
    IF leg:HASKEY("MAX_PE") {
        IF NOT (patch:PERIAPSIS <= leg["MAX_PE"]) { RETURN FALSE. }
    }
    IF leg:HASKEY("INC") {
        LOCAL tolerance IS 0.5.
        IF leg:HASKEY("INC_TOL") { SET tolerance TO leg["INC_TOL"]. }
        IF NOT (tolerance > 0 AND tolerance <= 0.5
                AND ABS(patch:INCLINATION-leg["INC"]) <= tolerance) { RETURN FALSE. }
    }
    RETURN TRUE.
}

// Every scored event must occur on the actual finite native patch. Parent
// transits conservatively require safe Pe even if truncated before that Pe.
// No extrapolated post-moon orbit or invisible future encounter earns credit.
GLOBAL FUNCTION assistEvaluate {
    PARAMETER nd.
    PARAMETER route.
    PARAMETER bodies.
    PARAMETER startIndex IS 0.
    PARAMETER lastBody IS "".
    LOCAL rejected IS LEXICON("OK",FALSE,"REASON","incomplete-itinerary").
    IF NOT (startIndex >= 0 AND startIndex < route:LENGTH AND bodies:LENGTH = route:LENGTH) { RETURN rejected. }
    LOCAL patch IS SHIP:ORBIT.
    LOCAL entryUt IS TIME:SECONDS.
    LOCAL correctionDv IS 0.
    IF nd <> 0 {
        SET patch TO nd:ORBIT.
        SET entryUt TO MAX(TIME:SECONDS,nd:TIME).
        SET correctionDv TO nd:DELTAV:MAG.
    }
    LOCAL legIndex IS startIndex.
    LOCAL depth IS 0.
    LOCAL report IS LIST().
    UNTIL depth >= 24 OR ABORT {
        LOCAL completedCurrent IS depth = 0 AND startIndex > 0 AND patch:BODY:NAME = lastBody
            AND patch:ETA:PERIAPSIS <= 0.
        IF patch:BODY = bodies[legIndex] AND NOT completedCurrent {
            LOCAL leg IS route[legIndex].
            LOCAL peUt IS arrivalPatchPeUt(patch,entryUt).
            IF NOT (peUt > entryUt AND assistLegClear(patch,leg)) {
                SET rejected["REASON"] TO "unsafe-or-truncated-periapsis". RETURN rejected.
            }
            report:ADD(LEXICON("BODY",patch:BODY:NAME,"PE",patch:PERIAPSIS,"ENTRY",entryUt,"PE_UT",peUt)).
            IF legIndex = route:LENGTH-1 {
                IF assistGoalMode(route) = "ENTRY" {
                    IF arrivalPatchRadiusUt(patch,patch:BODY:ATM:HEIGHT,entryUt) <= entryUt { RETURN rejected. }
                    RETURN LEXICON("OK",TRUE,"REASON","native-entry-itinerary",
                        "COST",correctionDv,"CAPTURE_DV",0,"LEGS",report).
                }
                LOCAL rp IS patch:BODY:RADIUS+patch:PERIAPSIS.
                LOCAL ra IS patch:BODY:RADIUS+leg["AP"].
                IF ra < rp OR NOT (patch:ECCENTRICITY >= 0 AND patch:ECCENTRICITY < 1e30) { RETURN rejected. }
                LOCAL incoming IS SQRT(patch:BODY:MU*(1+patch:ECCENTRICITY)/rp).
                LOCAL captured IS SQRT(patch:BODY:MU*(2/rp-2/(rp+ra))).
                LOCAL captureDv IS ABS(incoming-captured).
                RETURN LEXICON("OK",TRUE,"REASON","native-itinerary",
                    "COST",correctionDv+captureDv,"CAPTURE_DV",captureDv,"LEGS",report).
            }
            // An unpowered flyby needs an outgoing patch; bound moon orbits
            // cannot masquerade as free assistance into the next tour leg.
            IF NOT (patch:ECCENTRICITY > 1) { RETURN rejected. }
            SET legIndex TO legIndex+1.
        } ELSE {
            IF NOT _assistAncestor(patch:BODY,bodies[legIndex]) {
                // A confirmed flyby can still be the current patch while
                // awaiting escape. No arbitrary unrequested body is allowed.
                IF patch:BODY:NAME <> lastBody OR NOT (patch:ECCENTRICITY > 1) { RETURN rejected. }
            }
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

