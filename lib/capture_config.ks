// Shared capture intent; no flight controller or node creation.
@LAZYGLOBAL OFF.
GLOBAL TARGET_AP IS -1.
GLOBAL CAPTURE_RESERVE_DV IS -1.
GLOBAL CAPTURE_MIN_PE IS -1.
GLOBAL CAPTURE_MAX_PE IS -1.
GLOBAL CAPTURE_ACCEPT_BOUND IS 0.
// Only an unflown, explicitly optional capture may hand to a following FLYBY.
GLOBAL CAPTURE_OPTIONAL_FLYBY IS 0.

GLOBAL FUNCTION capturePeriapsisOk {
    PARAMETER pe.
    RETURN pe > 0 AND pe < 1e30
        AND (CAPTURE_MIN_PE < 0 OR pe >= CAPTURE_MIN_PE)
        AND (CAPTURE_MAX_PE < 0 OR pe <= CAPTURE_MAX_PE).
}
