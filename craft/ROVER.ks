// ============================================================
// ROVER.ks
//
// Ship name:  ROVER-MUN
// ============================================================

GLOBAL CFG IS LEXICON(
).

LOCAL _seq IS LIST("TARGETED_DEORBIT", "LAND", "ROVER", "DONE").
GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs().
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN missionSequenceLibs(
        missionLibsForPhases(_seq, LIST("utils")),
        LIST("utils")
    ).
}

LOCAL FUNCTION buildPhaseSequence {
    LOCAL seq IS missionListFromCsv(missionCfgGet("SEQUENCE", "")).
    IF seq:LENGTH > 0 { RETURN seq. }
    RETURN _seq.
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
