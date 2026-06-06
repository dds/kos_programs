// ============================================================
// ROVER.ks
//
// Ship name:  ROVER-MUN
// ============================================================

GLOBAL CFG IS LEXICON(
).

GLOBAL LIBS IS LIST(
    "landing", "targeting", "rover", "utils"
).

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
        "ROVER",            phaseRoverInit@,
        "DONE",             phaseRoverShutdown@
    ).

    runPhases(phaseMap).
}
