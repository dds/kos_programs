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

// Single Wheesley, Mk1 cockpit, 8 passenger seats — a clean business
// jet. Flaps up it cruises 6000m at 280-320 m/s; flaps down it flies
// nicely at 60 m/s, so the stall warning sits just below approach.
SET CRUISE_ALT TO 6000.
SET CRUISE_SPEED TO 300.
SET TOP_SPEED TO 320.
SET FLAP_AG TO 1.
SET AIRBORNE_RADAR_ALT TO 8.
SET FINAL_LANDING_SPEED TO 35.
SET MIN_FLIGHT_TIME TO 60.

GLOBAL FBIJ_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "DONE").

IF stateGet("phase", "") = "" {
    LOCAL startupSeq IS FBIJ_SEQ.
    IF SEQUENCE:LENGTH > 0 {
        SET startupSeq TO phaseList(SEQUENCE).
    }
    stateSet("phase", startupSeq[0]).
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN airplaneVehicleLibs(FBIJ_SEQ).
}

LOCAL FUNCTION _fbijConfigurePlane {
    // Airframe certified for software assists after flight testing —
    // PID control re-enabled for the GAP airline missions.
    SET PLANE_PID_CTRL TO TRUE.
    // Flaps down it flies nicely at 60 m/s, so warn just below that.
    SET PLANE_STALL_SPEED TO 55.
    // Flight-director toggles within easy reach (AG1 is flaps):
    //   AG2 = autopilot (wing-leveler + alt + heading hold)
    //   AG3 = waypoint nav (also brings up the autopilot)
    SET PLANE_AP_AG TO 2.
    SET PLANE_WPTNAV_AG TO 3.
    // Auto reverser moved off AG2 (now the autopilot) to AG4 — bind
    // the reverse-thrust/airbrake parts to AG4 in the VAB.
    SET PLANE_REVERSE_AG TO 4.
    // Underpowered passenger jet on short island strips: full
    // reverse, and engage as soon as the wheels are down braking.
    SET PLANE_REVERSE_THROTTLE TO 1.0.
    SET PLANE_REVERSE_MIN_SPEED TO 40.
}

LOCAL FUNCTION _fbijConfigRows {
    flightPlanSection("BUSINESS JET").
    flightPlanRow("FINAL STOP", FINAL_LANDING_SPEED + " m/s").
    flightPlanRow("PID CTRL", "ON").
    flightPlanRow("FLAPS", "AG1").
    flightPlanRow("AUTOPILOT", "AG2 toggle").
    flightPlanRow("NAV", "Select wpt, AG3 to fly").
    flightPlanRow("REVERSE", "AG4 (auto on land)").
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
            "Rotate - pull up at 75 m/s",
            "Gear - retract on positive climb",
            "Navigation - press AG3 after stable climb (AG2 = AP only)"
        )
    )).
}
