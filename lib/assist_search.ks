// Diagnostic preview: bounded local vector search. No candidate execution.
// Probe(ctx, offsets, budget) returns numeric progress and an admissible cost.
// No nodes, bodies, mission state, engine controls or departure-date search here.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION assistSearchLimits {
    RETURN LEXICON("CHANGE_DV",20,"TRIALS",64,"POSITIONS",1536,
        "GAME_SECONDS",20,"WALL_SECONDS",30,"STOP_UT",0,"RESERVE_DV",100,
        "MIN_GAIN",25,"SCIENCE_EXTRA_DV",0,"MIN_BURN_DV",0.3).
}

GLOBAL FUNCTION assistSearchBudget {
    PARAMETER limits.
    RETURN LEXICON("PROBES",0,"POSITIONS",0,"STOP","","TIERS",LIST(0,0,0,0,0),
        "GAME_END",MIN(TIME:SECONDS+limits["GAME_SECONDS"],limits["STOP_UT"]),
        "WALL_END",KUNIVERSE:REALTIME+limits["WALL_SECONDS"]).
}

GLOBAL FUNCTION assistSearchTimeLeft {
    PARAMETER budget.
    PARAMETER reserve IS 0.
    IF TIME:SECONDS+reserve >= budget["GAME_END"] { SET budget["STOP"] TO "game-deadline". RETURN FALSE. }
    IF KUNIVERSE:REALTIME+reserve >= budget["WALL_END"] { SET budget["STOP"] TO "wall-deadline". RETURN FALSE. }
    RETURN TRUE.
}

GLOBAL FUNCTION assistSearchMagnitude {
    PARAMETER axes.
    RETURN SQRT(axes[0]^2+axes[1]^2+axes[2]^2).
}

LOCAL FUNCTION _assistSearchBetter {
    PARAMETER sample.
    PARAMETER other.
    IF sample["TIER"] <> other["TIER"] { RETURN sample["TIER"] > other["TIER"]. }
    RETURN sample["LOSS"] < other["LOSS"].
}

LOCAL FUNCTION _assistSearchKeep {
    PARAMETER beam.
    PARAMETER sample.
    IF sample["TIER"] < 0 { RETURN. }
    FOR old IN beam {
        IF ABS(old["OFFSETS"][0]-sample["OFFSETS"][0]) < 0.00001
                AND ABS(old["OFFSETS"][1]-sample["OFFSETS"][1]) < 0.00001
                AND ABS(old["OFFSETS"][2]-sample["OFFSETS"][2]) < 0.00001 { RETURN. }
    }
    IF beam:LENGTH < 3 { beam:ADD(sample). RETURN. }
    LOCAL worst IS 0.
    LOCAL index IS 1.
    UNTIL index >= beam:LENGTH {
        IF _assistSearchBetter(beam[worst],beam[index]) { SET worst TO index. }
        SET index TO index+1.
    }
    IF _assistSearchBetter(sample,beam[worst]) { SET beam[worst] TO sample. }
}

LOCAL FUNCTION _assistSearchOrder {
    PARAMETER beam.
    LOCAL ordered IS beam:COPY.
    LOCAL index IS 0.
    UNTIL index >= ordered:LENGTH {
        LOCAL other IS index+1.
        UNTIL other >= ordered:LENGTH {
            IF _assistSearchBetter(ordered[other],ordered[index]) {
                LOCAL saved IS ordered[index]. SET ordered[index] TO ordered[other]. SET ordered[other] TO saved.
            }
            SET other TO other+1.
        }
        SET index TO index+1.
    }
    RETURN ordered.
}

LOCAL FUNCTION _assistSearchProbe {
    PARAMETER ctx.
    PARAMETER probe.
    PARAMETER offsets.
    PARAMETER limits.
    PARAMETER budget.
    SET budget["PROBES"] TO budget["PROBES"]+1.
    LOCAL sample IS probe:CALL(ctx,offsets,budget).
    SET sample["OFFSETS"] TO offsets:COPY.
    IF NOT (sample["TIER"] >= -1 AND sample["TIER"] <= 3 AND sample["TIER"] = FLOOR(sample["TIER"])
            AND sample["LOSS"] >= 0 AND sample["LOSS"] < 1e30) {
        SET sample["TIER"] TO -1. SET sample["ELIGIBLE"] TO FALSE.
    }
    IF sample["ELIGIBLE"] {
        IF NOT (sample["COST"] >= 0 AND sample["COST"] < 1e30) { SET sample["ELIGIBLE"] TO FALSE. }
    }
    LOCAL tier IS sample["TIER"]+1.
    SET budget["TIERS"][tier] TO budget["TIERS"][tier]+1.
    RETURN sample.
}

// Three small basins avoid retaining a full candidate grid. Coarse probes
// include diagonal directions; local refinement changes only PRN components.
GLOBAL FUNCTION assistSearchVectors {
    PARAMETER ctx.
    PARAMETER probe.
    PARAMETER limits.
    PARAMETER budget.
    LOCAL best IS LEXICON("OK",FALSE,"REASON","no-admissible-assist").
    LOCAL beam IS LIST().
    LOCAL directions IS LIST(LIST(1,0,0),LIST(0,1,0),LIST(0,0,1),
        LIST(1,1,1),LIST(1,1,-1),LIST(1,-1,1),LIST(-1,1,1)).
    // The unmodified maneuver participates too: an existing natural assist
    // does not need an artificial steering burn to become a candidate.
    LOCAL zero IS _assistSearchProbe(ctx,probe,LIST(0,0,0),limits,budget).
    _assistSearchKeep(beam,zero).
    IF zero["ELIGIBLE"] { SET best TO zero. SET best["OK"] TO TRUE. }
    FOR fraction IN LIST(0.25,1) {
        FOR direction IN directions {
            FOR sign IN LIST(-1,1) {
                IF budget["PROBES"] >= limits["TRIALS"]-2 OR NOT assistSearchTimeLeft(budget,1) OR ctx["CANCELLED"] { BREAK. }
                LOCAL scale IS sign*fraction*limits["CHANGE_DV"]/assistSearchMagnitude(direction).
                LOCAL offsets IS LIST(scale*direction[0],scale*direction[1],scale*direction[2]).
                LOCAL sample IS _assistSearchProbe(ctx,probe,offsets,limits,budget).
                _assistSearchKeep(beam,sample).
                IF sample["ELIGIBLE"] {
                    IF NOT best["OK"] OR sample["COST"] < best["COST"] { SET best TO sample. SET best["OK"] TO TRUE. }
                }
            }
        }
    }
    LOCAL stepDv IS limits["CHANGE_DV"]/4.
    UNTIL stepDv < 0.02 OR beam:LENGTH = 0 OR budget["PROBES"] >= limits["TRIALS"]-2
            OR NOT assistSearchTimeLeft(budget,1) OR ctx["CANCELLED"] {
        LOCAL improved IS FALSE.
        LOCAL starts IS _assistSearchOrder(beam).
        FOR seed IN starts {
            FOR axis IN LIST(0,1,2) {
                FOR sign IN LIST(-1,1) {
                    IF budget["PROBES"] >= limits["TRIALS"]-2 OR NOT assistSearchTimeLeft(budget,1) OR ctx["CANCELLED"] { BREAK. }
                    LOCAL offsets IS seed["OFFSETS"]:COPY.
                    SET offsets[axis] TO offsets[axis]+sign*stepDv.
                    IF assistSearchMagnitude(offsets) <= limits["CHANGE_DV"] {
                        LOCAL sample IS _assistSearchProbe(ctx,probe,offsets,limits,budget).
                        IF _assistSearchBetter(sample,starts[0]) { SET improved TO TRUE. }
                        _assistSearchKeep(beam,sample).
                        IF sample["ELIGIBLE"] {
                            IF NOT best["OK"] OR sample["COST"] < best["COST"] { SET best TO sample. SET best["OK"] TO TRUE. }
                        }
                    }
                }
            }
            IF improved { BREAK. }
        }
        IF NOT improved { SET stepDv TO stepDv/2. }
    }
    // Re-probe a useful result; a cached encounter/goal score is not enough.
    IF best["OK"] AND NOT ctx["CANCELLED"] AND assistSearchTimeLeft(budget) AND budget["PROBES"] < limits["TRIALS"] {
        SET best TO _assistSearchProbe(ctx,probe,best["OFFSETS"],limits,budget).
        SET best["OK"] TO best["ELIGIBLE"].
    } ELSE { SET best["OK"] TO FALSE. }
    SET best["TRIALS"] TO budget["PROBES"].
    SET best["POSITIONS"] TO budget["POSITIONS"].
    SET best["STOP"] TO budget["STOP"].
    SET best["TIERS"] TO budget["TIERS"]:COPY.
    SET best["BEST_TIER"] TO -1.
    IF beam:LENGTH > 0 {
        LOCAL ranked IS _assistSearchOrder(beam).
        SET best["BEST_TIER"] TO ranked[0]["TIER"].
        SET best["BEST_LOSS"] TO ranked[0]["LOSS"].
        SET best["BEST_OFFSETS"] TO ranked[0]["OFFSETS"]:COPY.
    }
    RETURN best.
}
