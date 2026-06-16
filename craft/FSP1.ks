// ============================================================
// FSP1.ks  —  Seaplane/submersible flight computer  (0:/craft/FSP1.ks)
//
// Standard airplane lifecycle plus water phases: FLIGHT ends at
// splashdown (or runway landing), then SPLASHDOWN/SURFACE_OPS.
// Flight logic lives in airplaneMain() (lib/airplane.ks).
// Ship name:  FSP1-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",       2000,
    "CRUISE_SPEED",      120,
    "TOP_SPEED",         180,
    "FLAP_AG",             1,
    "SPLASHDOWN_SPEED",   40
).

GLOBAL FSP1_SEQ IS LIST("PREFLIGHT", "FLIGHT", "SPLASHDOWN", "SURFACE_OPS", "DONE").

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs("AIR").
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN airplaneVehicleLibs(FSP1_SEQ).
}

LOCAL FUNCTION _fsp1ConfigRows {
    flightPlanRow("SPLASH SPD", CFG["SPLASHDOWN_SPEED"] + " m/s").
}

LOCAL FUNCTION _phaseSplashdown {
    mLogPhase("SPLASHDOWN").
    planeShutdown().
    mLog("Water landing complete.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseSurfaceOps {
    mLogPhase("SURFACE_OPS").
    IF missionHasPayload("SCIENCE") {
        scienceRunAll().
        scienceTransmitAll().
        mLog("Water surface science collected.").
    }
    mLog("Dive ops not yet implemented (needs marine.ks).").
    nextPhase(launchSeq).
}

GLOBAL FUNCTION main {
    airplaneMain("FSP1", LEXICON(
        "defaultSeq", FSP1_SEQ,
        "configRows", _fsp1ConfigRows@,
        "phases", LEXICON(
            "SPLASHDOWN", _phaseSplashdown@,
            "SURFACE_OPS", _phaseSurfaceOps@
        ),
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
            "Splashdown target - " + CFG["SPLASHDOWN_SPEED"] + " m/s"
        )
    )).
}
