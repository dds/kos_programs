// ============================================================
// FJ1A.ks  —  Juno trainer jet flight computer  (0:/craft/FJ1A.ks)
//
// Single/dual Juno trainer. Broad wings, low speed, fun to fly.
// Flight logic lives in airplaneMain() (lib/airplane.ks).
// Ship name:  FJ1A-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",    5000,
    "CRUISE_SPEED",   140,
    "TOP_SPEED",      230,
    "FLAP_AG",          1
).

GLOBAL FJ1A_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs("AIR").
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN airplaneVehicleLibs(FJ1A_SEQ).
}

GLOBAL FUNCTION main {
    airplaneMain("FJ1A", LEXICON(
        "defaultSeq", FJ1A_SEQ,
        "checklist", LIST(
            "Control surfaces - check full deflection",
            "Altimeter - set to RADAR (right-click)",
            "Camera - chase view, raise above tail",
            "Brakes - HOLD until ready",
            "Stage - start engines",
            "Throttle - FULL",
            "Brakes - RELEASE at full thrust",
            "Rotate - pull up at 80 m/s",
            "Gear - retract on positive climb",
            "Climb - level off, accelerate to 120 m/s"
        )
    )).
}
