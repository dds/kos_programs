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

GLOBAL CFG IS LEXICON(
    "CRUISE_ALT",       18000,
    "CRUISE_SPEED",      1300,
    "TOP_SPEED",         1500,
    "FLAP_AG",              1,
    "AIRBORNE_RADAR_ALT",   8,

    "SSTO_ASCENT_HDG",     90,
    "SSTO_AIR_ALT",     18000,
    "SSTO_SWITCH_ACCEL",  0.2,
    "SSTO_SWITCH_SPEED", 1400,
    "SSTO_MODE_AG",         3,
    "SSTO_ROCKET_PITCH",   18,
    "SSTO_TARGET_AP",   80000,
    "SSTO_REENTRY_PE",  28000,
    "SSTO_DEORBIT_LEAD_DEG", 70,
    "SSTO_REENTRY_AOA",     8,
    "SSTO_RUNWAY",      "KSC",
    "SSTO_DECISION_AGL",  150
).

GLOBAL FSS1_SEQ IS LIST(
    "PREFLIGHT", "AIRCLIMB", "ROCKETCLIMB",
    "SSTO_DEORBIT", "REENTRY", "APPROACH", "DONE"
).

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs("AIR").
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN airplaneVehicleLibs(FSS1_SEQ).
}

LOCAL FUNCTION _fss1ConfigRows {
    flightPlanSection("SSTO").
    flightPlanRow("SPEEDRUN", CFG["SSTO_AIR_ALT"] + " m / switch "
        + CFG["SSTO_SWITCH_SPEED"] + " m/s").
    flightPlanRow("TARGET AP", CFG["SSTO_TARGET_AP"] + " m").
    flightPlanRow("MODE AG", "AG" + CFG["SSTO_MODE_AG"]).
    flightPlanRow("RUNWAY", CFG["SSTO_RUNWAY"]).
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
            "Engine mode AG" + CFG["SSTO_MODE_AG"] + " - bound in editor",
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
