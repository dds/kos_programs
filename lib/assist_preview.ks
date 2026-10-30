// Manual assist-search baseline and diagnostics. Archive-only command helper.
// Prices the original node and its configured capture, not an optimized route.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION assistPreviewMissionFallback {
    LOCAL goal IS LEXICON("BODY",TARGET_,"MODE",BPLANE_ARRIVAL_MODE).
    IF BPLANE_ARRIVAL_MODE = "ENTRY" {
        SET goal["MIN_PE"] TO CAPTURE_PE-BPLANE_PE_TOL.
        SET goal["MAX_PE"] TO CAPTURE_PE+BPLANE_PE_TOL.
        RETURN goal.
    }
    IF BPLANE_ARRIVAL_MODE <> "ORBIT" OR CAPTURE_LAN >= 0 OR CAPTURE_AOP >= 0 { RETURN LEXICON(). }
    SET goal["MIN_PE"] TO CAPTURE_MIN_PE.
    SET goal["MAX_PE"] TO CAPTURE_MAX_PE.
    SET goal["AP"] TO TARGET_AP.
    IF BPLANE_REQUIRE_PLANE > 0 AND CAPTURE_INC >= 0 {
        SET goal["INC"] TO CAPTURE_INC. SET goal["INC_TOL"] TO BPLANE_ANG_TOL.
    }
    RETURN goal.
}

LOCAL FUNCTION _assistPreviewBoundGoal {
    PARAMETER patch.
    PARAMETER goal.
    IF assistGoalMode(LIST(goal)) <> "ORBIT" OR patch:BODY:NAME <> goal["BODY"]
            OR NOT (patch:ECCENTRICITY >= 0 AND patch:ECCENTRICITY < 1)
            OR patch:HASNEXTPATCH OR NOT assistLegClear(patch,goal) { RETURN FALSE. }
    RETURN ABS(patch:APOAPSIS-goal["AP"]) <= MAX(1,0.000001*(patch:BODY:RADIUS+goal["AP"])).
}

// EXACT prices a complete equivalent direct goal in the impulsive model.
// LOWER prices only a specified mandatory capture prefix; omitted operations
// must have nonnegative cost. Neither compares optimized departure/MCC plans.
GLOBAL FUNCTION assistPreviewDirect {
    PARAMETER nd.
    PARAMETER terminal.
    PARAMETER budget.
    PARAMETER fallbackGoal.
    LOCAL rejected IS LEXICON("OK",FALSE,"REASON","original-node-capture-not-validated").
    IF NOT assistSearchTimeLeft(budget) { RETURN rejected. }
    LOCAL keys IS LIST("BODY","MODE","MIN_PE","MAX_PE","AP","INC","INC_TOL").
    FOR key IN fallbackGoal:KEYS { IF NOT keys:CONTAINS(key) { RETURN rejected. } }
    LOCAL route IS LIST(fallbackGoal).
    LOCAL bodies IS assistRouteBodies(route,1).
    IF bodies:LENGTH <> 1 { RETURN rejected. }
    LOCAL bound IS "LOWER".
    LOCAL source IS "node-plus-capture".
    LOCAL nodeDv IS nd:DELTAV:MAG.
    LOCAL cost IS nodeDv.
    LOCAL captureDv IS 0.
    LOCAL patch IS nd:ORBIT.
    IF _assistPreviewBoundGoal(patch,fallbackGoal) {
        SET source TO "planned-capture".
        IF _assistPreviewBoundGoal(patch,terminal) { SET bound TO "EXACT". }
    } ELSE {
        LOCAL proof IS assistEvaluate(nd,route,bodies,0,"",SHIP:BODY:NAME).
        IF NOT proof["OK"] {
            // XING deliberately leaves final arrival targeting to BPLANE. The
            // mandatory departure cost is a LOWER bound; later corrections
            // are nonnegative but unpriced. Prove a safe native approach,
            // never claim it already meets the requested capture/entry goal.
            IF stateGet("phase","") <> "XING" OR SHIP:BODY = bodies[0] { RETURN rejected. }
            LOCAL mode IS assistGoalMode(route).
            IF assistGoalMode(LIST(terminal)) <> mode { RETURN rejected. }
            LOCAL terminalBodies IS assistRouteBodies(LIST(terminal),1).
            IF terminalBodies:LENGTH <> 1 { RETURN rejected. }
            IF mode = "ENTRY" {
                IF terminalBodies[0] <> bodies[0] { RETURN rejected. }
                SET source TO "departure-only-pending-entry".
            } ELSE {
                // A parent-capture fallback can precede operations at its moon.
                IF terminalBodies[0] <> bodies[0] {
                    IF NOT terminalBodies[0]:HASBODY { RETURN rejected. }
                    IF terminalBodies[0]:BODY <> bodies[0] { RETURN rejected. }
                }
                SET source TO "departure-only-pending-capture".
            }
            LOCAL floorPe IS 1.
            IF bodies[0]:ATM:EXISTS { SET floorPe TO bodies[0]:ATM:HEIGHT+1. }
            IF mode = "ORBIT" { SET floorPe TO MAX(floorPe,fallbackGoal["MIN_PE"]). }
            LOCAL passage IS LEXICON("BODY",bodies[0]:NAME,"MIN_PE",floorPe).
            LOCAL prefix IS assistTrace(nd,LIST(passage),bodies,0,"",SHIP:BODY:NAME).
            IF NOT prefix["OK"] { RETURN rejected. }
            IF NOT (prefix["PATCH"]:ECCENTRICITY > 1) { RETURN rejected. }
        } ELSE {
            SET captureDv TO proof["CAPTURE_DV"]. SET cost TO nodeDv+captureDv.
        }
        IF proof["OK"] AND terminal["BODY"] = fallbackGoal["BODY"] {
            // Different same-body entry/orbit intent is not an equivalent goal.
            IF assistGoalMode(LIST(terminal)) <> assistGoalMode(route) { RETURN rejected. }
            LOCAL terminalBodies IS assistRouteBodies(LIST(terminal),1).
            IF terminalBodies:LENGTH = 1 {
                LOCAL terminalProof IS assistEvaluate(nd,LIST(terminal),terminalBodies,0,"",SHIP:BODY:NAME).
                IF terminalProof["OK"] {
                    IF ABS(terminalProof["COST"]-cost) < 0.00001 { SET bound TO "EXACT". }
                }
            }
        }
    }
    IF NOT assistSearchTimeLeft(budget) OR NOT (nodeDv >= 0 AND cost >= nodeDv AND cost < 1e30) { RETURN rejected. }
    RETURN LEXICON("OK",TRUE,"GOAL",terminal:COPY,"BOUND",bound,"COST",cost,
        "NODE_DV",nodeDv,"UT",nd:TIME,"CAPTURE_DV",captureDv,
        "PRICED_BODY",fallbackGoal["BODY"],"SOURCE",source).
}

GLOBAL FUNCTION assistPreviewSeekIndex {
    PARAMETER nd.
    PARAMETER route.
    LOCAL bodies IS assistRouteBodies(route).
    IF bodies:LENGTH <> route:LENGTH { RETURN -1. }
    LOCAL patch IS nd:ORBIT.
    LOCAL depth IS 0.
    LOCAL seen IS 0.
    UNTIL depth >= 24 {
        IF patch:BODY = bodies[seen] {
            SET seen TO seen+1.
            IF seen = route:LENGTH { RETURN 0. }
        }
        IF NOT patch:HASNEXTPATCH { RETURN seen. }
        SET patch TO patch:NEXTPATCH. SET depth TO depth+1.
    }
    RETURN seen.
}

// Bounded native snapshot, only while the original node is attached.
GLOBAL FUNCTION assistPreviewPatchRows {
    PARAMETER nd.
    PARAMETER reportState.
    LOCAL patch IS nd:ORBIT.
    LOCAL depth IS 0.
    UNTIL depth >= 12 {
        diagnosticArchiveLine(reportState,"STATS assist-search original-patch index=" + depth
            + " body=" + patch:BODY:NAME + " pe=" + patch:PERIAPSIS + " ap=" + patch:APOAPSIS
            + " ecc=" + patch:ECCENTRICITY + " inc=" + patch:INCLINATION
            + " peEta=" + patch:ETA:PERIAPSIS + " hasNext=" + patch:HASNEXTPATCH).
        IF NOT patch:HASNEXTPATCH {
            IF patch:ECCENTRICITY > 1 {
                diagnosticArchiveLine(reportState,"STATS assist-search prediction-warning=open-hyperbolic-tail"
                    + " visibleSegments=" + (depth+1) + " tailBody=" + patch:BODY:NAME
                    + " possibleLookaheadLimit=True").
            }
            RETURN.
        }
        SET patch TO patch:NEXTPATCH. SET depth TO depth+1.
    }
}

GLOBAL FUNCTION assistPreviewResult {
    PARAMETER result.
    PARAMETER reportState.
    diagnosticArchiveLine(reportState,"STATS assist-search result ok=" + result["OK"]
        + " reason=" + result["REASON"] + " restored=" + result["RESTORED"] + " noBurn=True").
    IF result:HASKEY("REFERENCE_CHECK") {
        diagnosticArchiveLine(reportState,"STATS assist-search reference-check details="
            + configLiteral(result["REFERENCE_CHECK"])).
    }
    IF result:HASKEY("DIRECT_COST") {
        diagnosticArchiveLine(reportState,"STATS assist-search baseline totalDv=" + result["DIRECT_COST"]
            + " bound=" + result["DIRECT_BOUND"] + " source=" + result["DIRECT_SOURCE"]
            + " optimizedDirect=False").
    }
    IF result:HASKEY("TRIALS") {
        diagnosticArchiveLine(reportState,"STATS assist-search work trials=" + result["TRIALS"]
            + " positions=" + result["POSITIONS"] + " stop=" + result["STOP"]
            + " cancelled=" + result["CANCELLED"] + " tiers=" + configLiteral(result["TIERS"])
            + " bestTier=" + result["BEST_TIER"]).
        IF result["BEST_TIER"] >= 0 {
            diagnosticArchiveLine(reportState,"STATS assist-search progress loss=" + result["BEST_LOSS"]
                + " offsets=" + configLiteral(result["BEST_OFFSETS"])).
        }
    }
    IF NOT result["OK"] { RETURN. }
    diagnosticArchiveLine(reportState,"STATS assist-search proposal ut=" + result["EPOCH"]
        + " radial=" + result["AXES"][0] + " normal=" + result["AXES"][1] + " prograde=" + result["AXES"][2]
        + " totalDv=" + result["COST"] + " captureDv=" + result["CAPTURE_DV"]
        + " directDv=" + result["DIRECT_COST"] + " directBound=" + result["DIRECT_BOUND"]
        + " extraDv=" + result["EXTRA_DV"] + " needsAdmission=True").
    FOR leg IN result["LEGS"] {
        diagnosticArchiveLine(reportState,"STATS assist-search proposed-leg body=" + leg["BODY"]
            + " pe=" + leg["PE"] + " entryUt=" + leg["ENTRY"] + " peUt=" + leg["PE_UT"]).
    }
}
