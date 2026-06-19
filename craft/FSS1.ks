// ============================================================
// FSS1.ks  —  SSTO spaceplane flight computer  (0:/craft/FSS1.ks)
//
// Rapier-powered spaceplane template. Phase logic lives in
// lib/ssto.ks + airplaneMain() — this file is configuration.
// Ship name:  FSS1-TARGET-TYPE1-...-NN
//
// VAB/SPH setup required:
//   - Bind the rapier "Toggle Engine Mode" (and any nuke/aux
//     rocket ignition) to the SSTO_MODE_AG action group.
//   - Tag steering gear "steering_gear" for taxi power steering.
//
// Mission work in orbit goes between ROCKETCLIMB and
// SSTO_DEORBIT in the profile SEQUENCE (GOTO, RDV, SHAPE,
// payload phases) — after ROCKETCLIMB this is a normal orbital
// vessel, including cmd/goto.ks retasking.
// ============================================================

SET CRUISE_ALT TO 18000.
SET CRUISE_SPEED TO 1300.
SET TOP_SPEED TO 1500.
SET FLAP_AG TO 1.
SET AIRBORNE_RADAR_ALT TO 8.

SET SSTO_ASCENT_HDG TO 90.
SET SSTO_AIR_ALT TO 18000.
SET SSTO_SWITCH_ACCEL TO 0.2.
SET SSTO_SWITCH_SPEED TO 1400.
SET SSTO_MODE_AG TO 3.
SET SSTO_ROCKET_PITCH TO 18.
SET SSTO_TARGET_AP TO 80000.
SET SSTO_REENTRY_PE TO 28000.
SET SSTO_DEORBIT_LEAD_DEG TO 70.
SET SSTO_REENTRY_AOA TO 8.
SET SSTO_RUNWAY TO "KSC".
SET SSTO_DECISION_AGL TO 150.

GLOBAL FSS1_SEQ IS LIST(
    "PREFLIGHT", "AIRCLIMB", "ROCKETCLIMB",
    "SSTO_DEORBIT", "REENTRY", "APPROACH", "DONE"
).

GLOBAL FUNCTION bootVehicleLibs {
    RETURN airplaneVehicleLibs(FSS1_SEQ, LIST("orbit", "airplane", "solar")).
}

LOCAL FUNCTION _fss1ConfigRows {
    flightPlanSection("SSTO").
    flightPlanRow("SPEEDRUN", SSTO_AIR_ALT + " m / switch "
        + SSTO_SWITCH_SPEED + " m/s").
    flightPlanRow("TARGET AP", SSTO_TARGET_AP + " m").
    flightPlanRow("MODE AG", "AG" + SSTO_MODE_AG).
    flightPlanRow("RUNWAY", SSTO_RUNWAY).
}

GLOBAL FUNCTION main {
    airplaneMain("FSS1", LEXICON(
        "defaultSeq", FSS1_SEQ,
        "configRows", _fss1ConfigRows@,
        "phases", LEXICON(
            "AIRCLIMB",     phaseAirclimb@,
            "ROCKETCLIMB",  phaseRocketclimb@,
            "SSTO_DEORBIT", phaseSstoDeorbit@,
            "REENTRY",      phaseReentry@,
            "APPROACH",     phaseApproach@
        ),
        "checklist", LIST(
            "Engine mode AG" + SSTO_MODE_AG + " - bound in editor",
            "Control surfaces - check full deflection",
            "Flaps - takeoff setting",
            "Brakes - HOLD until ready",
            "Stage - start airbreathers",
            "Throttle - FULL",
            "Brakes - RELEASE at full thrust",
            "Rotate - gently, watch the tail strike",
            "Gear - retract on positive climb",
            "AIRCLIMB takes the jet after liftoff"
        )
    )).
}
