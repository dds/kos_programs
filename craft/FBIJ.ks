// ============================================================
// FBIJ.ks  -  Fast business jet flight computer  (0:/craft/FBIJ.ks)
//
// Citation-style executive jet flying the GAP airline contracts.
// Select the contract waypoint in Waypoint Manager, then press
// AG8 after takeoff to load and fly it. Multi-leg flights restart
// via RUNPATH("0:/cmd/restartflightplan.ks") after each landing.
// Ship name:  FBIJ-TARGET-TYPE1-...-NN
//
// Flight logic lives in airplaneMain() (lib/airplane.ks); this
// file is just configuration. MIN_FLIGHT_TIME + FINAL_LANDING_SPEED
// keep touch-and-goes from ending the FLIGHT phase.
// ============================================================

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",    9000,
    "CRUISE_SPEED",   280,
    "TOP_SPEED",      360,
    "FLAP_AG",          1,
    "AIRBORNE_RADAR_ALT", 8,
    "FINAL_LANDING_SPEED", 35,
    "MIN_FLIGHT_TIME", 60
).

GLOBAL FBIJ_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "DONE").

IF stateGet("phase", "") = "" {
    LOCAL startupSeq IS FBIJ_SEQ.
    IF stateGet("mission_cfg_SEQUENCE", "") <> "" {
        SET startupSeq TO phaseListFromString(stateGet("mission_cfg_SEQUENCE", "")).
    }
    stateSet("phase", startupSeq[0]).
}

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs("AIR").
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN airplaneVehicleLibs(FBIJ_SEQ).
}

LOCAL FUNCTION _fbijConfigurePlane {
    // Airframe certified for software assists after flight testing —
    // PID control re-enabled for the GAP airline missions.
    SET PLANE_CFG["PID_CTRL"] TO TRUE.
    // Underpowered passenger jet on short island strips: full
    // reverse, and engage as soon as the wheels are down braking.
    SET PLANE_CFG["REVERSE_THROTTLE"] TO 1.0.
    SET PLANE_CFG["REVERSE_MIN_SPEED"] TO 40.
}

LOCAL FUNCTION _fbijConfigRows {
    flightPlanSection("BUSINESS JET").
    flightPlanRow("FINAL STOP", CFG["FINAL_LANDING_SPEED"] + " m/s").
    flightPlanRow("PID CTRL", "ON").
    flightPlanRow("NAV", "Select waypoint, AG8 to fly").
}

GLOBAL FUNCTION main {
    airplaneMain("FBIJ", LEXICON(
        "defaultSeq", FBIJ_SEQ,
        "configure", _fbijConfigurePlane@,
        "configRows", _fbijConfigRows@,
        "checklist", LIST(
            "Passengers - seated and emotionally prepared",
            "Waypoint Manager - select destination",
            "Control surfaces - check full deflection",
            "Flaps - takeoff setting",
            "Brakes - HOLD until ready",
            "Stage - start engines",
            "Throttle - FULL",
            "Brakes - RELEASE at full thrust",
            "Rotate - pull up at 105 m/s",
            "Gear - retract on positive climb",
            "Navigation - press AG8 after stable climb"
        )
    )).
}
