// ============================================================
// ROVER.ks
//
// Ship name:  ROVER-MUN
// ============================================================


LOCAL _seq IS LIST("TARGETED_DEORBIT", "LAND", "ROVER", "DONE").
GLOBAL FUNCTION bootVehicleLibs {
    RETURN missionSequenceLibs(
        missionLibsForPhases(_seq, LIST("utils", "solar")),
        LIST("utils", "solar")
    ).
}

LOCAL FUNCTION buildPhaseSequence {
    IF SEQUENCE:LENGTH > 0 { RETURN phaseList(SEQUENCE). }
    RETURN _seq.
}

LOCAL FUNCTION _printConfig {
    LOCAL seq IS buildPhaseSequence().
    printSequence(seq).
}

GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.
    mLogPhase("MAIN").
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "TARGETED_DEORBIT", phaseTargetedDeorbit@,
        "LAND",             phaseLand@,
        "ROVER",            phaseRover@,
        "DONE",             _phaseRoverDone@
    ).

    runPhases(phaseMap).
}

LOCAL FUNCTION _phaseRoverDone {
    roverShutdown().
    phaseDone().
}
