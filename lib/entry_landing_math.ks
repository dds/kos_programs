// Atmospheric terminal burn: measured authority, descending stopping curve.
@LAZYGLOBAL OFF.
GLOBAL ENTRY_LANDING_RESERVE_DV IS 300.
GLOBAL ENTRY_LANDING_MIN_TWR IS 1.5.
GLOBAL ENTRY_LANDING_TOUCHDOWN_SPEED IS 2.
GLOBAL ENTRY_LANDING_MAX_TILT IS 20.
GLOBAL ENTRY_LANDING_REACTION IS 3.
GLOBAL ENTRY_LANDING_ALIGN_DEG IS 8.
GLOBAL ENTRY_LANDING_CLEARANCE IS 3.
GLOBAL ENTRY_LANDING_MAX_ALT IS 10000.
GLOBAL ENTRY_LANDING_MAX_AIRSPEED IS 300.

GLOBAL FUNCTION entryLandingPreflight {
    PARAMETER extraDv IS 0.
    LOCAL out IS LEXICON("OK",FALSE,"REASON","invalid-landing-configuration").
    IF NOT (ENTRY_LANDING_RESERVE_DV > 0 AND ENTRY_LANDING_RESERVE_DV < 1e30
            AND ENTRY_LANDING_MIN_TWR > 1.2 AND ENTRY_LANDING_MIN_TWR <= 10
            AND ENTRY_LANDING_TOUCHDOWN_SPEED > 0 AND ENTRY_LANDING_TOUCHDOWN_SPEED <= 5
            AND ENTRY_LANDING_MAX_TILT >= 0 AND ENTRY_LANDING_MAX_TILT <= 30
            AND ENTRY_LANDING_REACTION >= 2 AND ENTRY_LANDING_REACTION <= 30
            AND ENTRY_LANDING_ALIGN_DEG > 0 AND ENTRY_LANDING_ALIGN_DEG <= 10
            AND ENTRY_LANDING_CLEARANCE >= 0 AND ENTRY_LANDING_CLEARANCE <= 20
            AND ENTRY_LANDING_MAX_ALT >= 1000 AND ENTRY_LANDING_MAX_ALT <= 20000
            AND ENTRY_LANDING_MAX_AIRSPEED >= 50 AND ENTRY_LANDING_MAX_AIRSPEED <= 500
            AND extraDv >= 0 AND extraDv < 1e30) { RETURN out. }
    SET out["REASON"] TO "no-measured-landing-authority".
    IF NOT (SHIP:MASS > 0 AND SHIP:MASS < 1e30 AND SHIP:AVAILABLETHRUST > 0
            AND SHIP:AVAILABLETHRUST < 1e30 AND SHIP:BODY:MU > 0 AND SHIP:BODY:RADIUS > 0) { RETURN out. }
    LOCAL grav IS SHIP:BODY:MU/SHIP:BODY:RADIUS^2.
    LOCAL twr IS SHIP:AVAILABLETHRUST/SHIP:MASS/grav.
    SET out["TWR"] TO twr.
    IF twr < ENTRY_LANDING_MIN_TWR OR 0.9*twr*COS(ENTRY_LANDING_MAX_TILT) <= 1 { RETURN out. }
    SET out["REASON"] TO "active-stage-fuel-reserve".
    SET out["AVAILABLE"] TO STAGE:DELTAV:VACUUM.
    IF NOT (out["AVAILABLE"] >= extraDv+ENTRY_LANDING_RESERVE_DV AND out["AVAILABLE"] < 1e30) { RETURN out. }
    SET out["REASON"] TO "no-stock-parachutes".
    LOCAL chutes IS 0.
    FOR part IN SHIP:PARTS { IF part:HASMODULE("ModuleParachute") { SET chutes TO chutes+1. } }
    SET out["CHUTES"] TO chutes.
    IF chutes = 0 { RETURN out. }
    SET out["OK"] TO TRUE. SET out["REASON"] TO "measured-active-stage".
    RETURN out.
}

// No drag credit: gravity and the tilt/response reserve bound vertical arrest.
// Target speed is always downward. Lateral effort gets only unused tilt.
GLOBAL FUNCTION entryLandingPlan {
    PARAMETER height.
    PARAMETER down.
    PARAMETER acceleration.
    PARAMETER gravity.
    LOCAL out IS LEXICON("OK",FALSE,"STOP",1e30,"TARGET_DOWN",0,"UP_ACC",0).
    IF NOT (height >= 0 AND height < 1e30 AND down >= 0 AND down < 1e30
            AND acceleration > 0 AND acceleration < 1e30 AND gravity > 0 AND gravity < 1e30) { RETURN out. }
    LOCAL net IS 0.9*acceleration*COS(ENTRY_LANDING_MAX_TILT)-gravity.
    IF net <= 0 { RETURN out. }
    LOCAL clearance IS ENTRY_LANDING_CLEARANCE.
    LOCAL reaction IS ENTRY_LANDING_REACTION.
    LOCAL terminal IS ENTRY_LANDING_TOUCHDOWN_SPEED.
    LOCAL distance IS MAX(0,height-clearance-down*reaction).
    LOCAL targetDown IS SQRT(terminal^2+2*net*distance).
    SET out["STOP"] TO MAX(0,(down^2-terminal^2)/(2*net))+down*reaction+clearance.
    SET out["TARGET_DOWN"] TO targetDown.
    SET out["UP_ACC"] TO MAX(0,MIN(acceleration,gravity+(down-targetDown)/1.5)).
    SET out["OK"] TO TRUE.
    RETURN out.
}
