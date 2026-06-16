// ============================================================
// FJ4B.ks  —  Supersonic jet flight computer  (0:/craft/FJ4B.ks)
//
// Manually-flown jet with autopilot assists. No landing assist —
// the pilot owns the rollout. Flight logic lives in
// airplaneMain() (lib/airplane.ks).
// Ship name:  FJ4B-TARGET-TYPE1-...-NN
// ============================================================

SET CRUISE_ALT TO 5000.
SET CRUISE_SPEED TO 300.
SET TOP_SPEED TO 450.
SET FLAP_AG TO 1.

GLOBAL FJ4B_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs("AIR").
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN airplaneVehicleLibs(FJ4B_SEQ).
}

GLOBAL FUNCTION main {
    airplaneMain("FJ4B", LEXICON(
        "defaultSeq", FJ4B_SEQ,
        "landingAssist", FALSE,
        "checklist", LIST(
            "Control surfaces - check full deflection",
            "Altimeter - set to RADAR (right-click)",
            "Camera - chase view, raise above tail",
            "Brakes - HOLD until ready",
            "Stage - start engines",
            "Throttle - FULL",
            "Brakes - RELEASE at full thrust",
            "Rotate - pull up at 120 m/s",
            "Gear - retract on positive climb",
            "Climb - level off, accelerate to 200 m/s"
        )
    )).
}
