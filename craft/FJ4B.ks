// ============================================================
// FJ4B.ks  —  Supersonic jet flight computer  (0:/craft/FJ4B.ks)
//
// Manual takeoff/landing, optional in-flight assists:
//   AG1 flaps, AG7 autopilot, AG8 selected-waypoint navigation.
// Bind flaps to AG1 in the SPH; keep AG7/AG8 clear of part actions.
// Engine modes, airbrakes and rollout remain under pilot control.
// Flight logic lives in airplaneMain() (lib/airplane.ks).
// Ship name: FJ4B or FJ4B-KERBIN-SCIENCE-01.
// ============================================================

SET CRUISE_ALT TO 5000.
SET CRUISE_SPEED TO 300.
SET TOP_SPEED TO 450.
SET FLAP_AG TO 1.
SET AIRBORNE_SPEED TO 120.
SET AIRBORNE_RADAR_ALT TO 8.
SET MIN_FLIGHT_TIME TO 60.
SET FINAL_LANDING_SPEED TO 25.

GLOBAL FJ4B_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "DONE").

// Profile-less boot needs a real aircraft phase before band selection.
// Preserve saved flight progress and any explicit mission sequence.
IF stateGet("phase", "") = "" {
    LOCAL startupSeq IS FJ4B_SEQ.
    IF SEQUENCE:LENGTH > 0 { SET startupSeq TO phaseList(SEQUENCE). }
    stateSet("phase", startupSeq[0]).
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN airplaneVehicleLibs(FJ4B_SEQ).
}

LOCAL FUNCTION _fj4bConfigurePlane {
    // Configure after library defaults load, including on a resumed phase.
    // Enabling the controllers does not engage them; AG7/AG8 do that.
    // Keep the shared gains until an airtest flight establishes this jet's
    // bank sign and response; don't copy passenger-jet trim corrections.
    SET PLANE_PID_CTRL TO TRUE.
    SET PLANE_AP_AG TO 7.
    SET PLANE_WPTNAV_AG TO 8.
    // No assumed reverser hardware or automatic engine-mode action group.
    // Zero also prevents preflight's reverser reset from touching AG2.
    SET PLANE_REVERSE_AUTO TO FALSE.
    SET PLANE_REVERSE_AG TO 0.
}

LOCAL FUNCTION _fj4bConfigRows {
    flightPlanSection("SUPERSONIC JET").
    flightPlanRow("FLAPS", "AG1 (bind in SPH)").
    flightPlanRow("AUTOPILOT", "AG7 toggle; initially off").
    flightPlanRow("NAV", "Select waypoint, AG8 to fly").
    flightPlanRow("TAKEOFF / LAND", "Pilot control; no automatic reverse").
}

GLOBAL FUNCTION main {
    airplaneMain("FJ4B", LEXICON(
        "defaultSeq", FJ4B_SEQ,
        "configure", _fj4bConfigurePlane@,
        "configRows", _fj4bConfigRows@,
        "landingAssist", FALSE,
        "checklist", LIST(
            "Control surfaces - check full deflection",
            "Reset pilot trims (Mod+X); flaps - takeoff setting",
            "AG7 / AG8 - reserved for AP / waypoint navigation",
            "Altimeter - set to RADAR (right-click)",
            "Camera - chase view, raise above tail",
            "Brakes - HOLD until ready",
            "Stage - start engines",
            "Throttle - FULL",
            "Brakes - RELEASE at full thrust",
            "Rotate - pull up at 120 m/s",
            "Gear - retract on positive climb",
            "Climb - level off, accelerate to 200 m/s",
            "Stable flight - AG7 for AP, or select waypoint and toggle AG8",
            "Landing and rollout - pilot control"
        )
    )).
}
