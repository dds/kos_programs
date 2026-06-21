// ============================================================
// dependencies.ks - boot dependency data and phase bindings
// ============================================================

GLOBAL FUNCTION dependencyLibs {
    RETURN LEXICON(
        "core", LIST("state", "logs", "files", "phases", "dependencies", "config", "mission_type"),
        "capture", LIST("maneuver", "maneuver_plan", "orbit", "solar"),
        "deorbit_burn", LIST(),
        "duna_ike_setup", LIST("maneuver", "maneuver_plan", "orbit", "solar"),
        "deorbit_targeting", LIST("orbit", "utils", "landing_config", "landing_math"),
        "flightplan", LIST("ui"),
        "inclination", LIST("orbit_nodes"),
        "landing_config", LIST("utils"),
        "landing_deorbit", LIST("landing_config", "landing_math"),
        "landing_math", LIST("utils"),
        "vessel_hardware", LIST(),
        "landing_main", LIST("landing_config", "landing_math", "vessel_hardware", "landing_terminal"),
        "landing", LIST("landing_main"),
        "landing_site", LIST(),
        "abort", LIST(),
        "launch", LIST("orbit", "countdown", "utils", "recovery", "ascent"),
        "ascent", LIST("orbit", "countdown"),
        "hop", LIST("utils"),
        "maneuver", LIST("countdown", "orbit_nodes"),
        "maneuver_plan", LIST("maneuver", "orbit_nodes"),
        "prelaunch", LIST("flightplan"),
        "suborbit", LIST("launch"),
        "mission_type", LIST(),
        "hohmann_transfer", LIST(),
        "lib_bplane_math", LIST(),
        "maneuver_intersystem", LIST("lambert", "hohmann_transfer", "maneuver", "maneuver_targeting", "lib_navigation", "inclination"),
        "maneuver_orbit", LIST("maneuver", "maneuver_plan", "inclination", "orbit"),
        "rdv_plan", LIST("hohmann_transfer", "maneuver", "lib_navigation", "orbit"),
        "maneuver_rendezvous", LIST("hohmann_transfer", "maneuver"),
        "maneuver_transfer", LIST("hohmann_transfer", "maneuver", "maneuver_intersystem", "maneuver_targeting", "lib_navigation", "orbit", "lib_bplane_math"),
        "maneuver_mcc", LIST("maneuver", "maneuver_targeting", "lib_navigation", "orbit"),
        "molniya", LIST("maneuver", "inclination"),
        "payload_landing", LIST("landing_config"),
        "payload_ops", LIST("orbit", "utils", "solar"),
        "recovery", LIST(),
        "return_setup", LIST(),
        "return_escape", LIST("maneuver"),
        "relay_constellation", LIST("maneuver", "maneuver_plan", "orbit", "solar"),
        "scansat_ops", LIST("orbit", "solar"),
        "solar", LIST(),
        "airplane", LIST("observe", "flightplan", "utils"),
        "rover", LIST("payload_landing"),
        "science", LIST(),
        "aerobrake", LIST("maneuver", "utils", "landing_config"),
        "landing_atmo", LIST("landing_config", "utils", "orbit"),
        "descent", LIST(),
        "xfer_plan", LIST("maneuver_transfer", "orbit"),
        "orbit_nodes", LIST(),
        "orbit_shape", LIST("maneuver", "maneuver_plan", "orbit_nodes", "orbit"),
        "arrival_bplane", LIST("hohmann_transfer", "maneuver", "orbit", "lib_bplane_math"),
        "goto_plan", LIST(),
        "payload_release", LIST("maneuver", "maneuver_plan", "orbit"),
        "ssto", LIST("airplane", "maneuver", "maneuver_plan", "orbit"),
        "drone", LIST("observe", "flightplan")
    ).
}

GLOBAL FUNCTION dependencyPhases {
    RETURN LEXICON(
        "PREFLIGHT", LIST("airplane"),
        "FLIGHT", LIST("airplane"),
        "POST_FLIGHT", LIST("airplane"),
        "POSTFLIGHT", LIST("airplane"),
        "EVA_SCIENCE", LIST("science", "orbit"),
        "SCIENCE_OPS", LIST("science", "orbit", "solar"),
        "SCIENCE_OPS_LOW", LIST("science", "orbit", "solar"),
        "LAUNCH", LIST("launch"),
        "HOP", LIST("hop"),
        "FAIR", LIST("launch"),
        "ANTS", LIST("launch"),
        "PARK", LIST("launch"),
        "ABORT", LIST("abort"),
        "PRELAUNCH", LIST("prelaunch"),
        "SUBORBIT", LIST("suborbit"),
        "RDV", LIST("rdv_plan"),
        "MATCH", LIST("maneuver_rendezvous"),
        "CREW_XFER", LIST("maneuver_rendezvous"),
        "XING", LIST("xfer_plan"),
        "ESCAPE", LIST("return_escape"),
        "MCC", LIST("maneuver_mcc"),
        "AEROBRAKE", LIST("aerobrake"),
        "ATMO_WALK", LIST("landing_atmo"),
        "DESCENT", LIST("descent"),
        "DUNA_AEROCAPTURE", LIST("duna_ike_setup"),
        "IKE_SETUP", LIST("duna_ike_setup"),
        "DUNA_ENTRY_SETUP", LIST("duna_ike_setup"),
        "DUNA_ENTRY_LOWER_PE", LIST("duna_ike_setup"),
        "KSC_DEORBIT", LIST("deorbit_targeting", "solar"),
        "COAST", LIST("capture"),
        "COAST_1HALF", LIST("capture"),
        "COAST_2HALF", LIST("capture"),
        "CAPTURE", LIST("capture"),
        "FLYBY", LIST("capture"),
        "CIRC", LIST("maneuver_orbit"),
        "RAISE", LIST("maneuver_orbit"),
        "INCLINE", LIST("maneuver_orbit"),
        "ELLIPTICAL", LIST("maneuver_orbit"),
        "TARGETED_DEORBIT", LIST("payload_ops", "deorbit_targeting", "landing_site"),
        "RELEASE_PROBE", LIST("payload_ops"),
        "RELAY_OPS", LIST("payload_ops"),
        "RELAY_CONSTELLATION", LIST("relay_constellation"),
        "SCANSAT_OPS", LIST("scansat_ops", "science"),
        "RETURN_SETUP", LIST("return_setup"),
        "SURFACE_RETURN_SETUP", LIST("return_setup"),
        "LAND_DEORBIT", LIST("landing_deorbit", "deorbit_targeting", "deorbit_burn"),
        "LAND", LIST("payload_landing", "landing_main"),
        "LAND_ASSIST", LIST("payload_landing", "landing_main"),
        "ROVER", LIST("rover"),
        "MOLNIYA", LIST("molniya"),
        "MOLNIYA_INSERT", LIST("molniya"),
        "DROP_FOR_IMPACT_AND_RAISE_PE", LIST("payload_release"),
        "DONE", LIST("solar", "recovery"),
        "SHAPE", LIST("orbit_shape"),
        "DEPARTURE_SHAPE", LIST("orbit_shape"),
        "BPLANE", LIST("arrival_bplane"),
        "REFINE_BPLANE", LIST("arrival_bplane"),
        "GOTO", LIST("goto_plan"),
        "AIRCLIMB", LIST("ssto"),
        "ROCKETCLIMB", LIST("ssto"),
        "SSTO_DEORBIT", LIST("ssto"),
        "REENTRY", LIST("ssto"),
        "APPROACH", LIST("ssto"),
        "ARM", LIST("drone"),
        "FLY", LIST("drone")
    ).
}

GLOBAL FUNCTION dependencyBands {
    RETURN LEXICON(
        "AIR", LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "POST_FLIGHT"),
        "SSTO_ASCENT", LIST("AIRCLIMB", "ROCKETCLIMB"),
        "SSTO_RETURN", LIST("SSTO_DEORBIT", "REENTRY", "APPROACH"),
        "PRELAUNCH", LIST("PRELAUNCH"),
        "LAUNCH", LIST("LAUNCH", "FAIR", "ANTS", "PARK"),
        "HOP", LIST("HOP"),
        "ABORT", LIST("ABORT"),
        "ESCAPE", LIST("ESCAPE"),
        "XFER_DEPARTURE_SHAPE", LIST("DEPARTURE_SHAPE"),
        "XFER_PLAN", LIST("XING"),
        "SHAPE", LIST("SHAPE"),
        "RENDEZVOUS", LIST("MATCH", "CREW_XFER"),
        "COAST", LIST("COAST"),
        "XFER_BPLANE", LIST("BPLANE", "REFINE_BPLANE"),
        "XFER_ARRIVE", LIST("COAST_1HALF", "COAST_2HALF", "CAPTURE", "FLYBY"),
        "XFER_ORBIT", LIST("CIRC", "RAISE", "INCLINE", "ELLIPTICAL"),
        "PAYLOAD_OPS", LIST("TARGETED_DEORBIT", "RELEASE_PROBE", "RELAY_OPS", "RELAY_CONSTELLATION"),
        "RETURN_SETUP", LIST("RETURN_SETUP", "SURFACE_RETURN_SETUP"),
        "AEROBRAKE", LIST("AEROBRAKE"),
        "ATMO_WALK", LIST("ATMO_WALK"),
        "DUNA_IKE_SETUP", LIST("DUNA_AEROCAPTURE", "IKE_SETUP", "DUNA_ENTRY_SETUP", "DUNA_ENTRY_LOWER_PE"),
        "LAND_DEORBIT", LIST("LAND_DEORBIT"),
        "LANDING", LIST("LAND_ASSIST", "LAND"),
        "MOLNIYA", LIST("MOLNIYA", "MOLNIYA_INSERT"),
        "DONE", LIST("DONE")
    ).
}

GLOBAL FUNCTION dependencyBindPhase {
    PARAMETER phaseMap.
    PARAMETER phaseName.
    LOCAL phaseKey IS phaseName.
    IF phaseKey = "PREFLIGHT" { phaseMapSet(phaseMap, phaseKey, phasePreflight@). }
    ELSE IF phaseKey = "FLIGHT" { phaseMapSet(phaseMap, phaseKey, phaseFlight@). }
    ELSE IF phaseKey = "POST_FLIGHT" { phaseMapSet(phaseMap, phaseKey, phasePostFlight@). }
    ELSE IF phaseKey = "POSTFLIGHT" { phaseMapSet(phaseMap, phaseKey, phasePostflight@). }
    ELSE IF phaseKey = "EVA_SCIENCE" { phaseMapSet(phaseMap, phaseKey, phaseEvaScience@). }
    ELSE IF phaseKey = "SCIENCE_OPS" { phaseMapSet(phaseMap, phaseKey, phaseScienceOps@). }
    ELSE IF phaseKey = "SCIENCE_OPS_LOW" { phaseMapSet(phaseMap, phaseKey, phaseScienceOpsLow@). }
    ELSE IF phaseKey = "LAUNCH" { phaseMapSet(phaseMap, phaseKey, phaseLaunch@). }
    ELSE IF phaseKey = "HOP" { phaseMapSet(phaseMap, phaseKey, phaseHop@). }
    ELSE IF phaseKey = "FAIR" { phaseMapSet(phaseMap, phaseKey, phaseFair@). }
    ELSE IF phaseKey = "ANTS" { phaseMapSet(phaseMap, phaseKey, phaseAnts@). }
    ELSE IF phaseKey = "PARK" { phaseMapSet(phaseMap, phaseKey, phasePark@). }
    ELSE IF phaseKey = "ABORT" { phaseMapSet(phaseMap, phaseKey, phaseAbort@). }
    ELSE IF phaseKey = "PRELAUNCH" { phaseMapSet(phaseMap, phaseKey, phasePrelaunch@). }
    ELSE IF phaseKey = "SUBORBIT" { phaseMapSet(phaseMap, phaseKey, phaseSuborbit@). }
    ELSE IF phaseKey = "RDV" { phaseMapSet(phaseMap, phaseKey, phaseRdv@). }
    ELSE IF phaseKey = "MATCH" { phaseMapSet(phaseMap, phaseKey, phaseMatch@). }
    ELSE IF phaseKey = "CREW_XFER" { phaseMapSet(phaseMap, phaseKey, phaseCrewXfer@). }
    ELSE IF phaseKey = "XING" { phaseMapSet(phaseMap, phaseKey, phaseXing@). }
    ELSE IF phaseKey = "ESCAPE" { phaseMapSet(phaseMap, phaseKey, phaseEscape@). }
    ELSE IF phaseKey = "MCC" { phaseMapSet(phaseMap, phaseKey, phaseMcc@). }
    ELSE IF phaseKey = "AEROBRAKE" { phaseMapSet(phaseMap, phaseKey, phaseAerobrake@). }
    ELSE IF phaseKey = "ATMO_WALK" { phaseMapSet(phaseMap, phaseKey, phaseAtmoWalk@). }
    ELSE IF phaseKey = "DESCENT" { phaseMapSet(phaseMap, phaseKey, phaseDescent@). }
    ELSE IF phaseKey = "DUNA_AEROCAPTURE" { phaseMapSet(phaseMap, phaseKey, phaseDunaAerocapture@). }
    ELSE IF phaseKey = "IKE_SETUP" { phaseMapSet(phaseMap, phaseKey, phaseIkeSetup@). }
    ELSE IF phaseKey = "DUNA_ENTRY_SETUP" { phaseMapSet(phaseMap, phaseKey, phaseDunaEntrySetup@). }
    ELSE IF phaseKey = "DUNA_ENTRY_LOWER_PE" { phaseMapSet(phaseMap, phaseKey, phaseDunaEntryLowerPe@). }
    ELSE IF phaseKey = "KSC_DEORBIT" { phaseMapSet(phaseMap, phaseKey, phaseKscDeorbit@). }
    ELSE IF phaseKey = "COAST" { phaseMapSet(phaseMap, phaseKey, phaseCoast@). }
    ELSE IF phaseKey = "COAST_1HALF" { phaseMapSet(phaseMap, phaseKey, phaseCoast1half@). }
    ELSE IF phaseKey = "COAST_2HALF" { phaseMapSet(phaseMap, phaseKey, phaseCoast2half@). }
    ELSE IF phaseKey = "CAPTURE" { phaseMapSet(phaseMap, phaseKey, phaseCapture@). }
    ELSE IF phaseKey = "FLYBY" { phaseMapSet(phaseMap, phaseKey, phaseFlyby@). }
    ELSE IF phaseKey = "CIRC" { phaseMapSet(phaseMap, phaseKey, phaseCirc@). }
    ELSE IF phaseKey = "RAISE" { phaseMapSet(phaseMap, phaseKey, phaseRaise@). }
    ELSE IF phaseKey = "INCLINE" { phaseMapSet(phaseMap, phaseKey, phaseIncline@). }
    ELSE IF phaseKey = "ELLIPTICAL" { phaseMapSet(phaseMap, phaseKey, phaseElliptical@). }
    ELSE IF phaseKey = "TARGETED_DEORBIT" { phaseMapSet(phaseMap, phaseKey, phaseTargetedDeorbit@). }
    ELSE IF phaseKey = "RELEASE_PROBE" { phaseMapSet(phaseMap, phaseKey, phaseReleaseProbe@). }
    ELSE IF phaseKey = "RELAY_OPS" { phaseMapSet(phaseMap, phaseKey, phaseRelayOps@). }
    ELSE IF phaseKey = "RELAY_CONSTELLATION" { phaseMapSet(phaseMap, phaseKey, phaseRelayConstellation@). }
    ELSE IF phaseKey = "SCANSAT_OPS" { phaseMapSet(phaseMap, phaseKey, phaseScansatOps@). }
    ELSE IF phaseKey = "RETURN_SETUP" { phaseMapSet(phaseMap, phaseKey, phaseReturnSetup@). }
    ELSE IF phaseKey = "SURFACE_RETURN_SETUP" { phaseMapSet(phaseMap, phaseKey, phaseSurfaceReturnSetup@). }
    ELSE IF phaseKey = "LAND_DEORBIT" { phaseMapSet(phaseMap, phaseKey, phaseLandDeorbit@). }
    ELSE IF phaseKey = "LAND" { phaseMapSet(phaseMap, phaseKey, phaseLand@). }
    ELSE IF phaseKey = "LAND_ASSIST" { phaseMapSet(phaseMap, phaseKey, phaseLandAssist@). }
    ELSE IF phaseKey = "ROVER" { phaseMapSet(phaseMap, phaseKey, phaseRover@). }
    ELSE IF phaseKey = "MOLNIYA" { phaseMapSet(phaseMap, phaseKey, phaseMolniya@). }
    ELSE IF phaseKey = "MOLNIYA_INSERT" { phaseMapSet(phaseMap, phaseKey, phaseMolniyaInsert@). }
    ELSE IF phaseKey = "DROP_FOR_IMPACT_AND_RAISE_PE" { phaseMapSet(phaseMap, phaseKey, phaseDropForImpactAndRaisePe@). }
    ELSE IF phaseKey = "DONE" { phaseMapSet(phaseMap, phaseKey, phaseDone@). }
    ELSE IF phaseKey = "SHAPE" { phaseMapSet(phaseMap, phaseKey, phaseShape@). }
    ELSE IF phaseKey = "DEPARTURE_SHAPE" { phaseMapSet(phaseMap, phaseKey, phaseDepartureShape@). }
    ELSE IF phaseKey = "BPLANE" { phaseMapSet(phaseMap, phaseKey, phaseBplane@). }
    ELSE IF phaseKey = "REFINE_BPLANE" { phaseMapSet(phaseMap, phaseKey, phaseRefineBplane@). }
    ELSE IF phaseKey = "GOTO" { phaseMapSet(phaseMap, phaseKey, phaseGoto@). }
    ELSE IF phaseKey = "AIRCLIMB" { phaseMapSet(phaseMap, phaseKey, phaseAirclimb@). }
    ELSE IF phaseKey = "ROCKETCLIMB" { phaseMapSet(phaseMap, phaseKey, phaseRocketclimb@). }
    ELSE IF phaseKey = "SSTO_DEORBIT" { phaseMapSet(phaseMap, phaseKey, phaseSstoDeorbit@). }
    ELSE IF phaseKey = "REENTRY" { phaseMapSet(phaseMap, phaseKey, phaseReentry@). }
    ELSE IF phaseKey = "APPROACH" { phaseMapSet(phaseMap, phaseKey, phaseApproach@). }
    ELSE IF phaseKey = "ARM" { phaseMapSet(phaseMap, phaseKey, phaseArm@). }
    ELSE IF phaseKey = "FLY" { phaseMapSet(phaseMap, phaseKey, phaseFly@). }
}
