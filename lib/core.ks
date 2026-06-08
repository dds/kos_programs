// ============================================================
// core.ks - marker for always-loaded mission core dependencies
// ============================================================

GLOBAL FUNCTION contains {
    PARAMETER item.
    PARAMETER values.
    FOR value IN values {
        IF item = value { RETURN TRUE. }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION phaseIn {
    PARAMETER phase.
    PARAMETER phaseList.
    RETURN contains(phase, phaseList).
}
