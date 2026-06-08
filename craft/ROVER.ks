// ============================================================
// ROVER.ks
//
// Ship name:  ROVER-MUN
// ============================================================

GLOBAL CFG IS LEXICON(
).

LOCAL _seq IS LIST("TARGETED_DEORBIT", "LAND", "ROVER", "DONE").
GLOBAL LIBS IS bootLibsForPhases(_seq, LIST("utils")).

LOCAL FUNCTION buildPhaseSequence {
    RETURN LIST("TARGETED_DEORBIT", "LAND", "ROVER", "DONE").
}

LOCAL FUNCTION _printConfig {
    LOCAL seq IS buildPhaseSequence().
    printSequence(seq).
}

GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    mLogPhase("MAIN").
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "TARGETED_DEORBIT", phaseTargetedDeorbit@,
        "LAND",             phaseLand@,
        "ROVER",            roverInit@,
        "DONE",             roverShutdown@
    ).

    runPhases(phaseMap).
}
