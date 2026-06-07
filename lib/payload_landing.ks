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
    nextPhase(launchSeq).
}

GLOBAL FUNCTION phaseLand {
    landingExecute().
    nextPhase(launchSeq).
}
