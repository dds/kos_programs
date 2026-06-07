// ============================================================
// payload_landing.ks — Minimal landing payload phases
// (0:/lib/payload_landing.ks)
// ============================================================

GLOBAL FUNCTION phaseLandDeorbit {
    landingTargetedDeorbit().
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseLandAssist {
    landingAssistStage().
    IF CFG:HASKEY("RELOAD_AFTER_LAND_ASSIST") AND CFG["RELOAD_AFTER_LAND_ASSIST"] > 0 {
        nextPhase(launchSeq).
        mLog("Reload point after landing assist release. Reboot rover CPU to continue.").
        PRINT " ".
        PRINT "  LANDING ASSIST RELEASE COMPLETE".
        PRINT "  Reboot this CPU to load rover landing code.".
        WAIT UNTIL FALSE.
    }
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseLand {
    landingExecute().
    IF CFG:HASKEY("RELOAD_AFTER_LAND") AND CFG["RELOAD_AFTER_LAND"] > 0 {
        nextPhase(launchSeq).
        mLog("Reload point after touchdown. Reboot rover CPU to load rover code.").
        PRINT " ".
        PRINT "  TOUCHDOWN COMPLETE".
        PRINT "  Reboot this CPU to load rover code.".
        WAIT UNTIL FALSE.
    }
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseRover {
    roverInit().
    roverHUD().
}
