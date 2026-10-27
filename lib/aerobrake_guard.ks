// Common live interlocks for optional assist and emergency capture burns.
// Domain-specific Pe/fuel/entry policies remain with each burn owner.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION aerobrakeBurnFrameReason {
    PARAMETER control.
    IF ABORT OR phaseShouldYield { RETURN "operator-abort-or-hold". }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN "landed". }
    IF SHIP:BODY:NAME <> control["BODY"] OR STAGE:NUMBER <> control["STAGE"] OR HASNODE {
        RETURN "body-stage-or-node-changed".
    }
    IF WARP <> 0 OR NOT KUNIVERSE:TIMEWARP:ISSETTLED { RETURN "warp-active". }
    IF NOT (TIME:SECONDS < control["DEADLINE"] AND control["DEADLINE"] < 1e30) {
        RETURN "forecast-duration".
    }
    IF NOT (TIME:SECONDS-control["UPDATED"] >= 0 AND TIME:SECONDS-control["UPDATED"] <= 0.5) {
        RETURN "stale-control".
    }
    IF NOT (SHIP:AVAILABLETHRUST > 0 AND SHIP:AVAILABLETHRUST < 1e30
            AND SHIP:MASS > 0 AND SHIP:MASS < 1e30
            AND SHIP:VELOCITY:ORBIT:MAG > 1 AND SHIP:VELOCITY:ORBIT:MAG < 1e30
            AND control["DIR"]:MAG > 0.5 AND control["DIR"]:MAG < 1e30) {
        RETURN "invalid-thrust-or-direction".
    }
    RETURN "".
}

GLOBAL FUNCTION aerobrakeBurnAligned {
    PARAMETER control.
    IF NOT (SHIP:FACING:FOREVECTOR:MAG > 0.5 AND SHIP:FACING:FOREVECTOR:MAG < 1e30
            AND control["DIR"]:MAG > 0.5 AND control["DIR"]:MAG < 1e30
            AND SHIP:VELOCITY:ORBIT:MAG > 1 AND SHIP:VELOCITY:ORBIT:MAG < 1e30) { RETURN FALSE. }
    LOCAL facingErr IS VANG(SHIP:FACING:FOREVECTOR,control["DIR"]).
    IF NOT (facingErr >= 0 AND facingErr < 1e30) { RETURN FALSE. }
    SET control["PEAK_FACING_ERR"] TO MAX(control["PEAK_FACING_ERR"],facingErr).
    RETURN facingErr <= 5
        AND VDOT(control["DIR"],SHIP:VELOCITY:ORBIT) < -0.01*SHIP:VELOCITY:ORBIT:MAG.
}
