// Manual preview: transactional adapter for an existing planner-owned node.
// Load assist_route + maneuver before these preview files. Not flight-wired.
// DirectAssessor(node, terminalGoal, budget) supplies a verified EXACT cost or
// a certified LOWER bound for the current powered fallback. Never a guess.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _assistSearchAxes {
    PARAMETER nd.
    RETURN LIST(nd:RADIALOUT,nd:NORMAL,nd:PROGRADE).
}

LOCAL FUNCTION _assistSearchPut {
    PARAMETER ctx.
    PARAMETER axes.
    SET ctx["NODE"]:RADIALOUT TO axes[0].
    SET ctx["NODE"]:NORMAL TO axes[1].
    SET ctx["NODE"]:PROGRADE TO axes[2].
    SET ctx["EXPECTED"] TO axes:COPY.
}

LOCAL FUNCTION _assistSearchOwns {
    PARAMETER ctx.
    // Check active vessel BEFORE querying maneuver-node state (kOS API limit).
    IF SHIP <> ctx["SHIP"] OR KUNIVERSE:ACTIVEVESSEL <> SHIP OR SHIP:BODY <> ctx["BODY"] { RETURN FALSE. }
    IF stateGet("phase","") <> ctx["PHASE"] OR stateGet("mission_id","") <> ctx["MISSION"]
            OR stateGetNum("launch_time",0) <> ctx["LAUNCH"] { RETURN FALSE. }
    IF NOT ALLNODES:CONTAINS(ctx["NODE"]) { RETURN FALSE. }
    LOCAL nd IS ctx["NODE"].
    LOCAL axes IS ctx["EXPECTED"].
    RETURN ABS(nd:TIME-ctx["UT"]) < 0.00001
        AND ABS(nd:RADIALOUT-axes[0]) < 0.00001
        AND ABS(nd:NORMAL-axes[1]) < 0.00001
        AND ABS(nd:PROGRADE-axes[2]) < 0.00001.
}

GLOBAL FUNCTION assistSearchIdle {
    RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND NOT ABORT AND WARP = 0
        AND (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "ESCAPING" OR SHIP:STATUS = "SUB_ORBITAL")
        AND NOT maneuverBurnInterrupted()
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

// Only restore our last untouched probe. Never overwrite a user's edits,
// move a node in another frame, or change a node after thrust has begun.
LOCAL FUNCTION _assistSearchRestore {
    PARAMETER ctx.
    IF NOT _assistSearchOwns(ctx) OR maneuverBurnInterrupted()
            OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) { RETURN FALSE. }
    _assistSearchPut(ctx,ctx["BASE"]).
    WAIT 0.1.
    RETURN _assistSearchOwns(ctx).
}

LOCAL FUNCTION _assistSearchSameGoal {
    PARAMETER goal.
    PARAMETER other.
    // Unsupported constraints (e.g. LAN) cannot disappear from a comparison.
    LOCAL keys IS LIST("BODY","MODE","MIN_PE","MAX_PE","AP","INC","INC_TOL").
    FOR key IN goal:KEYS { IF NOT keys:CONTAINS(key) { RETURN FALSE. } }
    FOR key IN other:KEYS { IF NOT keys:CONTAINS(key) { RETURN FALSE. } }
    FOR key IN keys {
        IF goal:HASKEY(key) <> other:HASKEY(key) { RETURN FALSE. }
        IF goal:HASKEY(key) { IF goal[key] <> other[key] { RETURN FALSE. } }
    }
    RETURN TRUE.
}

LOCAL FUNCTION _assistSearchReferenceCheck {
    PARAMETER reference.
    PARAMETER ctx.
    LOCAL checked IS LEXICON("OK",FALSE,"REASON","direct-reference-unavailable").
    IF NOT reference["OK"] {
        IF reference:HASKEY("REASON") { SET checked["REASON"] TO reference["REASON"]. }
        RETURN checked.
    }
    SET checked["COST"] TO reference["COST"].
    SET checked["NODE_DV"] TO reference["NODE_DV"].
    SET checked["REASON"] TO "unsupported-reference-bound".
    IF reference["BOUND"] <> "EXACT" AND reference["BOUND"] <> "LOWER" { RETURN checked. }
    SET checked["REASON"] TO "reference-goal-mismatch".
    IF NOT _assistSearchSameGoal(ctx["GOAL"],reference["GOAL"]) { RETURN checked. }
    // Price and NODE_DV belong to the same snapshot. The live check below
    // retains its original tolerance; raw vector/time ownership is separate.
    SET checked["REASON"] TO "invalid-reference-price".
    IF NOT (reference["NODE_DV"] >= 0 AND reference["COST"] >= reference["NODE_DV"]
            AND reference["COST"] < 1e30) { RETURN checked. }
    LOCAL liveDv IS ctx["NODE"]:DELTAV:MAG.
    SET checked["LIVE_NODE_DV"] TO liveDv.
    SET checked["DV_DRIFT"] TO liveDv-reference["NODE_DV"].
    SET checked["REASON"] TO "reference-node-dv-changed".
    IF NOT (ABS(liveDv-reference["NODE_DV"]) < 0.00001) { RETURN checked. }
    SET checked["UT_DRIFT"] TO reference["UT"]-ctx["UT"].
    SET checked["REASON"] TO "reference-node-epoch-changed".
    IF NOT (ABS(reference["UT"]-ctx["UT"]) < 0.00001) { RETURN checked. }
    SET checked["OK"] TO TRUE. SET checked["REASON"] TO "verified".
    RETURN checked.
}

// Numeric-only progress: partial scores guide exploration; ONLY assistEvaluate
// can prove the complete itinerary. Do not retain these live patch references.
LOCAL FUNCTION _assistSearchWalk {
    PARAMETER ctx.
    LOCAL patch IS ctx["NODE"]:ORBIT.
    LOCAL startUt IS ctx["UT"].
    LOCAL seen IS 0.
    LOCAL depth IS 0.
    LOCAL result IS LEXICON("SEEK",0,"GOAL",0,"PARENT",0,"START",0,"END",0).
    LOCAL seekBody IS ctx["BODIES"][ctx["SEEK"]].
    UNTIL depth >= 24 {
        IF patch:BODY = ctx["BODIES"][seen] {
            IF seen = ctx["SEEK"] { SET result["SEEK"] TO patch. }
            SET seen TO seen+1.
            IF seen = ctx["ROUTE"]:LENGTH { SET result["GOAL"] TO patch. RETURN result. }
        }
        IF patch:BODY = seekBody:BODY AND result["PARENT"] = 0 {
            SET result["PARENT"] TO patch. SET result["START"] TO startUt.
            IF patch:HASNEXTPATCH { SET result["END"] TO TIME:SECONDS+patch:NEXTPATCHETA. }
            ELSE IF patch:ECCENTRICITY < 1 AND patch:PERIOD > 0 AND patch:PERIOD < 1e30 {
                SET result["END"] TO startUt+patch:PERIOD.
            }
        }
        IF NOT patch:HASNEXTPATCH { RETURN result. }
        LOCAL endUt IS TIME:SECONDS+patch:NEXTPATCHETA.
        IF NOT (endUt > startUt AND endUt < 1e30) { RETURN result. }
        SET startUt TO endUt. SET patch TO patch:NEXTPATCH. SET depth TO depth+1.
    }
    RETURN result.
}

LOCAL FUNCTION _assistSearchSeparation {
    PARAMETER ctx.
    PARAMETER epoch.
    PARAMETER budget.
    IF budget["POSITIONS"] >= ctx["LIMITS"]["POSITIONS"] OR NOT assistSearchTimeLeft(budget)
            OR NOT assistSearchIdle() OR NOT _assistSearchOwns(ctx) {
        SET budget["STOP"] TO "position-budget-or-context". RETURN 1e30.
    }
    SET budget["POSITIONS"] TO budget["POSITIONS"]+1.
    RETURN (POSITIONAT(SHIP,epoch)-POSITIONAT(ctx["BODIES"][ctx["SEEK"]],epoch)):MAG.
}

LOCAL FUNCTION _assistSearchMiss {
    PARAMETER ctx.
    PARAMETER path.
    PARAMETER budget.
    IF NOT (path["END"] > path["START"] AND path["END"] < 1e30) { RETURN 1e30. }
    LOCAL step IS (path["END"]-path["START"])/12.
    LOCAL bestUt IS path["START"].
    LOCAL best IS 1e30.
    FOR index IN LIST(0,1,2,3,4,5,6,7,8,9,10,11,12) {
        LOCAL epoch IS path["START"]+index*step.
        LOCAL distance IS _assistSearchSeparation(ctx,epoch,budget).
        IF distance < best { SET best TO distance. SET bestUt TO epoch. }
        IF budget["STOP"] <> "" { RETURN 1e30. }
    }
    LOCAL lo IS MAX(path["START"],bestUt-step).
    LOCAL hi IS MIN(path["END"],bestUt+step).
    LOCAL iteration IS 0.
    UNTIL iteration >= 5 OR budget["STOP"] <> "" {
        LOCAL leftUt IS lo+(hi-lo)/3. LOCAL rightUt IS hi-(hi-lo)/3.
        LOCAL leftDist IS _assistSearchSeparation(ctx,leftUt,budget).
        LOCAL rightDist IS _assistSearchSeparation(ctx,rightUt,budget).
        SET best TO MIN(best,MIN(leftDist,rightDist)).
        IF leftDist < rightDist { SET hi TO rightUt. } ELSE { SET lo TO leftUt. }
        SET iteration TO iteration+1.
    }
    RETURN best.
}

LOCAL FUNCTION _assistSearchGoalLoss {
    PARAMETER patch.
    PARAMETER goal.
    LOCAL upperPe IS patch:BODY:SOIRADIUS-patch:BODY:RADIUS.
    IF goal:HASKEY("MAX_PE") { SET upperPe TO goal["MAX_PE"]. }
    LOCAL scale IS MAX(1000,upperPe-goal["MIN_PE"]).
    LOCAL error IS MAX(0,MAX(goal["MIN_PE"]-patch:PERIAPSIS,patch:PERIAPSIS-upperPe))/scale.
    LOCAL loss IS error^2.
    IF goal:HASKEY("INC") {
        LOCAL tolerance IS 0.5.
        IF goal:HASKEY("INC_TOL") { SET tolerance TO goal["INC_TOL"]. }
        SET loss TO loss+(MAX(0,ABS(patch:INCLINATION-goal["INC"])-tolerance)/MAX(0.01,tolerance))^2.
    }
    IF goal:HASKEY("AP") { SET loss TO loss+(MAX(0,patch:PERIAPSIS-goal["AP"])/scale)^2. }
    RETURN loss.
}

LOCAL FUNCTION _assistSearchAdmissible {
    PARAMETER ctx.
    PARAMETER evidence.
    IF NOT evidence["OK"] { RETURN FALSE. }
    LOCAL nd IS ctx["NODE"].
    LOCAL limits IS ctx["LIMITS"].
    LOCAL cost IS evidence["COST"].
    IF NOT (cost >= 0 AND cost < 1e30 AND cost+limits["RESERVE_DV"] <= SHIP:DELTAV:VACUUM
            AND SHIP:DELTAV:VACUUM < 1e30) { RETURN FALSE. }
    IF nd:DELTAV:MAG > 0 AND nd:DELTAV:MAG <= limits["MIN_BURN_DV"] { RETURN FALSE. }
    LOCAL duration IS 0.
    IF nd:DELTAV:MAG > 0 { SET duration TO arrivalBurnSeconds(nd:DELTAV:MAG). }
    IF NOT (duration >= 0 AND duration < 1e30 AND nd:ORBIT:BODY = ctx["BODY"]
            AND nd:TIME-duration/2 > TIME:SECONDS+30) { RETURN FALSE. }
    FOR patch IN LIST(SHIP:ORBIT,nd:ORBIT) {
        IF patch:HASNEXTPATCH {
            IF NOT (nd:TIME+duration/2+120 < TIME:SECONDS+patch:NEXTPATCHETA) { RETURN FALSE. }
        }
    }
    LOCAL goal IS evidence["LEGS"][evidence["LEGS"]:LENGTH-1].
    LOCAL captureSeconds IS 0.
    IF evidence["CAPTURE_DV"] > 0 { SET captureSeconds TO arrivalBurnSeconds(evidence["CAPTURE_DV"]). }
    IF NOT (captureSeconds >= 0 AND captureSeconds < 1e30
            AND goal["PE_UT"]-MAX(TIME:SECONDS,goal["ENTRY"]) > 300+captureSeconds/2) { RETURN FALSE. }
    IF cost+limits["MIN_GAIN"] <= ctx["DIRECT"]["COST"] { RETURN TRUE. }
    // Science expenditure is opt-in and may buy only a NEW encounter chain.
    RETURN limits["SCIENCE_EXTRA_DV"] > 0 AND NOT ctx["BASE_HAS_ROUTE"]
        AND cost <= ctx["DIRECT"]["COST"]+limits["SCIENCE_EXTRA_DV"].
}

GLOBAL FUNCTION assistSearchNativeProbe {
    PARAMETER ctx.
    PARAMETER offsets.
    PARAMETER budget.
    LOCAL sample IS LEXICON("TIER",-1,"LOSS",1e29,"ELIGIBLE",FALSE,"COST",1e29).
    IF NOT assistSearchIdle() OR NOT _assistSearchOwns(ctx) OR ALLNODES:LENGTH <> 1 OR NOT assistSearchTimeLeft(budget) {
        SET ctx["CANCELLED"] TO TRUE. RETURN sample.
    }
    LOCAL base IS ctx["BASE"].
    _assistSearchPut(ctx,LIST(base[0]+offsets[0],base[1]+offsets[1],base[2]+offsets[2])).
    WAIT 0.1.
    IF assistSearchIdle() AND _assistSearchOwns(ctx) AND ALLNODES:LENGTH = 1 AND assistSearchTimeLeft(budget) {
        LOCAL proof IS assistEvaluate(ctx["NODE"],ctx["ROUTE"],ctx["BODIES"],0,"",ctx["BODY"]:NAME).
        IF proof["OK"] {
            SET sample["TIER"] TO 3. SET sample["LOSS"] TO proof["COST"].
            SET sample["COST"] TO proof["COST"].
            SET sample["CAPTURE_DV"] TO proof["CAPTURE_DV"].
            SET sample["LEGS"] TO proof["LEGS"].
            SET sample["ELIGIBLE"] TO _assistSearchAdmissible(ctx,proof).
        } ELSE {
            LOCAL path IS _assistSearchWalk(ctx).
            IF path["GOAL"] <> 0 {
                SET sample["TIER"] TO 2. SET sample["LOSS"] TO _assistSearchGoalLoss(path["GOAL"],ctx["GOAL"]).
            } ELSE IF path["SEEK"] <> 0 {
                SET sample["TIER"] TO 1. SET sample["LOSS"] TO 1.
            } ELSE IF path["PARENT"] <> 0 {
                LOCAL distance IS _assistSearchMiss(ctx,path,budget).
                IF distance < 1e29 {
                    SET sample["TIER"] TO 0.
                    SET sample["LOSS"] TO distance/ctx["BODIES"][ctx["SEEK"]]:SOIRADIUS.
                }
            }
        }
    } ELSE { SET ctx["CANCELLED"] TO TRUE. }
    SET ctx["RESTORED"] TO _assistSearchRestore(ctx).
    IF NOT ctx["RESTORED"] OR NOT assistSearchIdle() { SET ctx["CANCELLED"] TO TRUE. }
    RETURN sample.
}

// Result contains a proposed vector, NEVER a modified live node or permission
// to ignite. Caller must apply and admit it freshly through its normal path.
GLOBAL FUNCTION searchAssistNode {
    PARAMETER nd.
    PARAMETER route.
    PARAMETER seekIndex.
    PARAMETER directAssessor.
    PARAMETER limits.
    LOCAL rejected IS LEXICON("OK",FALSE,"REASON","unsafe-context","RESTORED",TRUE).
    IF NOT assistSearchIdle() OR NOT HASNODE OR ALLNODES:LENGTH <> 1 OR NEXTNODE <> nd { RETURN rejected. }
    SET rejected["REASON"] TO "invalid-search-limits".
    IF NOT (limits["CHANGE_DV"] > 0 AND limits["CHANGE_DV"] < 1000
            AND limits["TRIALS"] >= 4 AND limits["TRIALS"] <= 96
            AND limits["TRIALS"] = FLOOR(limits["TRIALS"])
            AND limits["POSITIONS"] >= 24 AND limits["POSITIONS"] <= 4096
            AND limits["POSITIONS"] = FLOOR(limits["POSITIONS"])
            AND limits["GAME_SECONDS"] > 1 AND limits["GAME_SECONDS"] <= 120
            AND limits["WALL_SECONDS"] > 1 AND limits["WALL_SECONDS"] <= 120
            AND limits["STOP_UT"] > TIME:SECONDS+1 AND limits["STOP_UT"] < 1e30
            AND limits["RESERVE_DV"] >= 0 AND limits["RESERVE_DV"] < 1e30
            AND limits["MIN_GAIN"] > 0 AND limits["MIN_GAIN"] < 1e30
            AND limits["SCIENCE_EXTRA_DV"] >= 0 AND limits["SCIENCE_EXTRA_DV"] < 1e30
            AND limits["MIN_BURN_DV"] >= 0.3 AND limits["MIN_BURN_DV"] < 1e30) { RETURN rejected. }
    SET rejected["REASON"] TO "invalid-or-unsupported-route".
    LOCAL keys IS LIST("BODY","MODE","MIN_PE","MAX_PE","INC","INC_TOL").
    LOCAL legIndex IS 0.
    FOR leg IN route {
        FOR key IN leg:KEYS {
            IF NOT keys:CONTAINS(key) AND NOT (key = "AP" AND legIndex = route:LENGTH-1) { RETURN rejected. }
        }
        SET legIndex TO legIndex+1.
    }
    LOCAL bodies IS assistRouteBodies(route,1).
    IF bodies:LENGTH <> route:LENGTH OR NOT (seekIndex >= 0 AND seekIndex < route:LENGTH AND seekIndex = FLOOR(seekIndex)) { RETURN rejected. }
    LOCAL budget IS assistSearchBudget(limits).
    LOCAL axes IS _assistSearchAxes(nd).
    LOCAL ctx IS LEXICON("NODE",nd,"SHIP",SHIP,"BODY",SHIP:BODY,"UT",nd:TIME,
        "BASE",axes,"EXPECTED",axes,"ROUTE",route,"BODIES",bodies,"SEEK",seekIndex,
        "PHASE",stateGet("phase",""),"MISSION",stateGet("mission_id",""),"LAUNCH",stateGetNum("launch_time",0),
        "GOAL",route[route:LENGTH-1],"LIMITS",limits,"CANCELLED",FALSE,"RESTORED",TRUE).
    LOCAL direct IS directAssessor:CALL(nd,ctx["GOAL"],budget).
    IF NOT _assistSearchOwns(ctx) OR NOT assistSearchIdle() {
        SET rejected["RESTORED"] TO FALSE. SET rejected["CANCELLED"] TO TRUE. RETURN rejected.
    }
    LOCAL referenceCheck IS _assistSearchReferenceCheck(direct,ctx).
    IF NOT referenceCheck["OK"] {
        SET rejected["REASON"] TO referenceCheck["REASON"].
        SET rejected["REFERENCE_CHECK"] TO referenceCheck.
        RETURN rejected.
    }
    SET ctx["DIRECT"] TO direct.
    SET ctx["BASE_HAS_ROUTE"] TO assistEvaluate(nd,route,bodies,0,"",SHIP:BODY:NAME)["OK"].
    LOCAL result IS assistSearchVectors(ctx,assistSearchNativeProbe@,limits,budget).
    SET result["REFERENCE_CHECK"] TO referenceCheck.
    SET result["DIRECT_COST"] TO direct["COST"].
    SET result["DIRECT_BOUND"] TO direct["BOUND"].
    SET result["DIRECT_SOURCE"] TO "caller-provided".
    IF direct:HASKEY("SOURCE") { SET result["DIRECT_SOURCE"] TO direct["SOURCE"]. }
    IF result["OK"] AND ctx["RESTORED"] AND NOT ctx["CANCELLED"] AND assistSearchTimeLeft(budget) {
        // Refresh the direct cost only while the ORIGINAL vector is in place.
        SET direct TO directAssessor:CALL(nd,ctx["GOAL"],budget).
        IF NOT _assistSearchOwns(ctx) OR NOT assistSearchIdle() OR NOT assistSearchTimeLeft(budget) {
            SET result["OK"] TO FALSE. SET ctx["CANCELLED"] TO TRUE.
        } ELSE {
            SET referenceCheck TO _assistSearchReferenceCheck(direct,ctx).
            SET result["REFERENCE_CHECK"] TO referenceCheck.
            IF NOT referenceCheck["OK"] { SET result["OK"] TO FALSE. }
            ELSE {
                SET result["OK"] TO result["COST"]+limits["MIN_GAIN"] <= direct["COST"]
                    OR (limits["SCIENCE_EXTRA_DV"] > 0 AND NOT ctx["BASE_HAS_ROUTE"]
                        AND result["COST"] <= direct["COST"]+limits["SCIENCE_EXTRA_DV"]).
                SET result["DIRECT_COST"] TO direct["COST"].
                SET result["DIRECT_BOUND"] TO direct["BOUND"].
                IF direct:HASKEY("SOURCE") { SET result["DIRECT_SOURCE"] TO direct["SOURCE"]. }
                SET result["EXTRA_DV"] TO result["COST"]-direct["COST"].
            }
        }
    } ELSE { SET result["OK"] TO FALSE. }
    IF NOT _assistSearchOwns(ctx) OR NOT assistSearchIdle() OR NOT assistSearchTimeLeft(budget) {
        SET result["OK"] TO FALSE. SET ctx["CANCELLED"] TO TRUE.
    }
    SET ctx["RESTORED"] TO ctx["RESTORED"] AND _assistSearchOwns(ctx).
    SET result["RESTORED"] TO ctx["RESTORED"].
    SET result["CANCELLED"] TO ctx["CANCELLED"].
    SET result["NEEDS_ADMISSION"] TO TRUE.
    SET result["EPOCH"] TO ctx["UT"].
    SET result["REASON"] TO "no-admissible-assist".
    IF result["OK"] { SET result["REASON"] TO "candidate-requires-admission". }
    IF NOT referenceCheck["OK"] { SET result["REASON"] TO referenceCheck["REASON"]. }
    IF ctx["CANCELLED"] { SET result["REASON"] TO "planning-cancelled". }
    IF result["OK"] {
        LOCAL offsets IS result["OFFSETS"].
        SET result["AXES"] TO LIST(axes[0]+offsets[0],axes[1]+offsets[1],axes[2]+offsets[2]).
    }
    RETURN result.
}
