// Preserve per-engine limits while lengthening a short maneuver burn.
// Cached with the executor; boot loads it only for an unfinished restore.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _burnLimitsIdle {
    RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
        AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

GLOBAL FUNCTION burnThrustSave {
    IF NOT _burnLimitsIdle() OR stateGet("engine_thrust_restore",LIST()):LENGTH > 0 { RETURN FALSE. }
    LOCAL limits IS LIST().
    FOR eng IN SHIP:ENGINES {
        IF NOT (eng:THRUSTLIMIT >= 0 AND eng:THRUSTLIMIT <= 100) { RETURN FALSE. }
        limits:ADD(LEXICON("UID",eng:UID,"LIMIT",eng:THRUSTLIMIT)).
    }
    // Hardware restoration must survive commands clearing the burn_* attempt.
    stateSet("engine_thrust_restore",limits).
    RETURN _burnLimitsIdle().
}

GLOBAL FUNCTION burnThrustRestore {
    LOCAL limits IS stateGet("engine_thrust_restore",LIST()).
    IF limits:LENGTH = 0 { RETURN TRUE. }
    IF NOT _burnLimitsIdle() { RETURN FALSE. }
    FOR item IN limits {
        FOR eng IN SHIP:ENGINES {
            IF eng:UID = item["UID"] { SET eng:THRUSTLIMIT TO item["LIMIT"]. }
        }
    }
    WAIT 0.02.
    IF NOT _burnLimitsIdle() { RETURN FALSE. }
    stateRemove("engine_thrust_restore").
    RETURN TRUE.
}
