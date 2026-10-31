// ============================================================
// dependencies.ks - boot dependency data and phase bindings
// ============================================================

GLOBAL FUNCTION dependencyLibs {
    RETURN LEXICON(
        "core", LIST("state", "logs", "files", "phases", "dependencies", "config", "mission_type"),
        "capture", LIST("maneuver", "maneuver_plan", "orbit", "coast_wait", "midcourse"),
        "flyby", LIST("coast_wait", "orbit", "science_flight", "conic_time", "thrust_cutoff"),
        "coast_wait", LIST("solar"),
        "midcourse", LIST(),
        "deorbit_burn", LIST("vessel_hardware", "landing_light", "coast_wait"),
        "duna_ike_setup", LIST("duna_entry", "ike_setup"),
        "duna_ike_config", LIST(),
        "duna_entry", LIST("duna_ike_config", "maneuver_plan", "orbit", "solar"),
        "ike_setup", LIST("duna_ike_config"),
        "deorbit_targeting", LIST("orbit", "utils", "landing_config", "landing_math", "deorbit_burn", "landing_deorbit_lead"),
        "flightplan", LIST("ui"),
        "inclination", LIST("orbit_nodes", "maneuver"),
        "landing_config", LIST("utils"),
        "landing_review", LIST("landing_config", "orbit", "coast_wait", "thrust_cutoff", "entry_landing_math"),
        "excursion", LIST("landing_config", "thrust_cutoff"),
        "atmo_deorbit", LIST("landing_review", "landing_math", "deorbit_burn"),
        "entry_landing_math", LIST(),
        "entry_landing", LIST("entry_landing_math", "landing_config", "thrust_cutoff"),
        "landing_deorbit", LIST("landing_config", "landing_math", "vessel_hardware"),
        "landing_math", LIST("utils"),
        "landing_light_math", LIST("landing_config", "landing_math", "landing_radio"),
        "landing_radio", LIST(),
        "landing_light", LIST("landing_light_math"),
        "landing_light_search", LIST("landing_light"),
        "landing_light_wait", LIST("landing_light_search", "coast_wait", "thrust_cutoff"),
        "vessel_hardware", LIST("thrust_cutoff", "landing_roles"),
        "landing_roles", LIST(),
        "thrust_cutoff", LIST(),
        "landing_divert", LIST("landing_light_math", "landing_diagnostics", "landing_stage_brake"),
        "landing_diagnostics", LIST(),
        "landing_main", LIST("landing_config", "landing_math", "vessel_hardware", "landing_terminal", "landing_divert", "landing_disposal", "landing_brake_math"),
        "landing_brake_math", LIST("landing_stage_brake"),
        "landing_prediction", LIST("landing_brake_math"),
        "landing_brake_fuel", LIST("landing_config", "vessel_hardware"),
        "landing_stage_brake", LIST("landing_config", "landing_math", "vessel_hardware", "landing_brake_fuel"),
        "landing_deorbit_lead", LIST("landing_prediction"),
        "landing_disposal", LIST("landing_config", "landing_math", "vessel_hardware"),
        "landing", LIST("landing_main"),
        "landing_site", LIST("landing_config"),
        "abort", LIST(),
        "launch", LIST("orbit", "countdown", "utils", "recovery", "ascent", "launch_window"),
        "launch_window", LIST(),
        "ascent", LIST("orbit", "countdown", "launch_window", "thrust_cutoff"),
        "hop", LIST("utils", "thrust_cutoff", "landing_config", "landing_math", "vessel_hardware"),
        "hop_control", LIST("hop", "payload_landing"),
        "hop_route", LIST("hop", "science"),
        "maneuver", LIST("countdown", "orbit_nodes", "thrust_cutoff"),
        "maneuver_plan", LIST("maneuver", "orbit_nodes"),
        "prelaunch", LIST("flightplan", "launch_window"),
        "suborbit", LIST("launch"),
        "mission_type", LIST(),
        "hohmann_transfer", LIST(),
        "lib_bplane_math", LIST(),
        "maneuver_intersystem", LIST("lambert", "hohmann_transfer", "maneuver", "maneuver_targeting", "lib_navigation", "inclination"),
        "maneuver_orbit", LIST("maneuver", "maneuver_plan", "inclination", "orbit"),
        "rdv_plan", LIST("hohmann_transfer", "maneuver", "lib_navigation", "orbit"),
        "maneuver_rendezvous", LIST("hohmann_transfer", "maneuver"),
        "maneuver_transfer", LIST("hohmann_transfer", "maneuver", "maneuver_intersystem", "maneuver_targeting", "lib_navigation", "orbit", "lib_bplane_math"),
        "maneuver_mcc", LIST("maneuver", "maneuver_targeting", "lib_navigation", "orbit", "coast_wait", "return_mcc_config"),
        "molniya", LIST("maneuver", "inclination", "orbit"),
        "payload_landing", LIST("landing_config"),
        "payload_ops", LIST("orbit", "utils", "solar"),
        "recovery", LIST(),
        "return_setup", LIST("aerobrake_config", "return_mcc_config"),
        "return_mcc_config", LIST(),
        "return_escape", LIST("maneuver"),
        "return_direct", LIST(),
        "relay_constellation", LIST("maneuver", "maneuver_plan", "orbit", "coast_wait", "relay_release"),
        "relay_release", LIST("relay_hardware", "thrust_cutoff"),
        "molniya_pair", LIST("relay_release"),
        "relay_hardware", LIST(),
        "scansat_ops", LIST("orbit", "solar", "science", "thrust_cutoff"),
        "solar", LIST("solar_diagnostics"),
        "solar_diagnostics", LIST(),
        "airplane", LIST("observe", "flightplan", "utils"),
        "rover", LIST(),
        "science", LIST(),
        "science_flight", LIST(),
        "science_entry", LIST("science_flight", "aerobrake_ap_math", "coast_wait", "thrust_cutoff"),
        "science_impact", LIST("science_entry", "maneuver_plan"),
        "science_surface", LIST("science_flight", "thrust_cutoff"),
        "surface_review", LIST("thrust_cutoff"),
        "orbital_survey", LIST("science", "landing_math", "coast_wait", "thrust_cutoff"),
        "aerobrake", LIST("maneuver", "utils", "landing_config", "aerobrake_assist", "solar", "reentry_pe"),
        "reentry_pe", LIST("maneuver_plan"),
        "aerobrake_assist", LIST("aerobrake_config", "aerobrake_ap_math", "aerobrake_staging", "aerobrake_guard", "thrust_cutoff"),
        "aerobrake_guard", LIST(),
        "aerobrake_staging", LIST("aerobrake_config", "thrust_cutoff"),
        "aerobrake_ap_math", LIST("conic_time"),
        "conic_time", LIST(),
        "arrival_policy", LIST("conic_time"),
        "assist_route", LIST("arrival_policy"),
        "gravity_assist", LIST("assist_route", "maneuver"),
        "assist_runtime", LIST("assist_route", "maneuver", "coast_wait"),
        "assist_plan", LIST("assist_runtime", "gravity_assist"),
        "assist_coast", LIST("assist_runtime"),
        "assist_search", LIST(),
        "assist_search_native", LIST("assist_search", "assist_route", "maneuver"),
        "assist_preview", LIST("assist_search_native"),
        "diagnostic_log", LIST(),
        "assist_midcourse", LIST("assist_preview", "diagnostic_log"),
        "aerobrake_config", LIST(),
        "landing_atmo", LIST("landing_config", "utils", "orbit", "thrust_cutoff"),
        "descent", LIST("thrust_cutoff"),
        "xfer_plan", LIST("maneuver_transfer", "orbit", "solar"),
        "orbit_nodes", LIST(),
        "orbit_shape", LIST("maneuver", "maneuver_plan", "orbit_nodes", "orbit"),
        "landing_orbit", LIST("orbit_shape", "landing_route", "vessel_hardware", "coast_wait"),
        "landing_route", LIST("landing_config", "vessel_hardware"),
        "arrival_bplane", LIST("hohmann_transfer", "maneuver", "orbit", "lib_bplane_math", "midcourse", "coast_wait", "arrival_policy"),
        "free_return", LIST("maneuver", "orbit", "lib_bplane_math"),
        "return_trim", LIST("maneuver", "orbit", "utils"),
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
        "SCIENCE_ENTRY", LIST("science_entry"),
        "LANDING_REVIEW", LIST("landing_review"),
        "EXCURSION_READY", LIST("excursion"),
        "ATMO_DEORBIT", LIST("atmo_deorbit"),
        "SCIENCE_IMPACT", LIST("science_impact"),
        "SURFACE_SCIENCE", LIST("science_surface"),
        "SURFACE_REVIEW", LIST("surface_review"),
        "ORBITAL_SURVEY", LIST("orbital_survey"),
        "LAUNCH", LIST("launch"),
        "HOP", LIST("hop_control"),
        "HOP_REVIEW", LIST("hop"),
        "HOP_ROUTE_SETUP", LIST("hop_route"),
        "HOP_AUTO_REVIEW", LIST("hop_route"),
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
        "DUNA_AEROCAPTURE", LIST("duna_entry"),
        "IKE_SETUP", LIST("ike_setup"),
        "DUNA_ENTRY_SETUP", LIST("duna_entry"),
        "DUNA_ENTRY_LOWER_PE", LIST("duna_entry"),
        "KSC_DEORBIT", LIST("deorbit_targeting", "solar"),
        "COAST", LIST("capture"),
        "COAST_1HALF", LIST("capture"),
        "COAST_2HALF", LIST("capture"),
        "CAPTURE", LIST("capture"),
        "ASSIST", LIST("assist_plan"),
        "ASSIST_COAST", LIST("assist_coast"),
        "FLYBY", LIST("flyby"),
        "CIRC", LIST("maneuver_orbit"),
        "RAISE", LIST("maneuver_orbit"),
        "INCLINE", LIST("maneuver_orbit"),
        "ELLIPTICAL", LIST("maneuver_orbit"),
        "TARGETED_DEORBIT", LIST("payload_ops", "deorbit_targeting", "landing_site"),
        "RELEASE_PROBE", LIST("payload_ops"),
        "RELAY_OPS", LIST("payload_ops"),
        "RELAY_CONSTELLATION", LIST("relay_constellation"),
        "MOLNIYA_PAIR", LIST("molniya_pair"),
        "SCANSAT_OPS", LIST("scansat_ops", "science"),
        "RETURN_SETUP", LIST("return_setup"),
        "SURFACE_RETURN_SETUP", LIST("return_setup"),
        "LAND_DEORBIT", LIST("landing_deorbit", "deorbit_targeting", "deorbit_burn"),
        "LAND_PREP", LIST("landing_orbit"),
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
        "FREE_RT_BPLANE", LIST("free_return"),
        "RETURN_TRIM", LIST("return_trim"),
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
        "HOP", LIST("HOP", "HOP_REVIEW"),
        "HOP_ROUTE", LIST("HOP_ROUTE_SETUP", "HOP_AUTO_REVIEW"),
        "ABORT", LIST("ABORT"),
        "ESCAPE", LIST("ESCAPE"),
        "XFER_DEPARTURE_SHAPE", LIST("DEPARTURE_SHAPE"),
        "XFER_PLAN", LIST("XING"),
        "ASSIST_PLAN", LIST("ASSIST"),
        "ASSIST_COAST", LIST("ASSIST_COAST"),
        "SHAPE", LIST("SHAPE"),
        "RENDEZVOUS", LIST("MATCH", "CREW_XFER"),
        "COAST", LIST("COAST"),
        "XFER_BPLANE", LIST("BPLANE", "REFINE_BPLANE"),
        "FREE_RT", LIST("FREE_RT_BPLANE"),
        "RETURN_TRIM", LIST("RETURN_TRIM"),
        "XFER_ARRIVE", LIST("COAST_1HALF", "COAST_2HALF", "CAPTURE"),
        "FLYBY", LIST("FLYBY"),
        "XFER_ORBIT", LIST("CIRC", "RAISE", "INCLINE", "ELLIPTICAL"),
        "PAYLOAD_OPS", LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "RELAY_OPS", LIST("RELAY_OPS"),
        "RELAY_CONSTELLATION", LIST("RELAY_CONSTELLATION"),
        "MOLNIYA_PAIR", LIST("MOLNIYA_PAIR"),
        "RETURN_SETUP", LIST("RETURN_SETUP", "SURFACE_RETURN_SETUP"),
        "AEROBRAKE", LIST("AEROBRAKE"),
        "ATMO_WALK", LIST("ATMO_WALK"),
        "DUNA_ENTRY", LIST("DUNA_AEROCAPTURE", "DUNA_ENTRY_SETUP", "DUNA_ENTRY_LOWER_PE"),
        "IKE_SETUP", LIST("IKE_SETUP"),
        "LAND_DEORBIT", LIST("LAND_DEORBIT"),
        "LAND_PREP", LIST("LAND_PREP"),
        "ORBITAL_SURVEY", LIST("ORBITAL_SURVEY"),
        "SCIENCE_ENTRY", LIST("SCIENCE_ENTRY"),
        "LANDING_REVIEW", LIST("LANDING_REVIEW"),
        "EXCURSION", LIST("EXCURSION_READY"),
        "ATMO_DEORBIT", LIST("ATMO_DEORBIT"),
        "SCIENCE_IMPACT", LIST("SCIENCE_IMPACT"),
        "SURFACE_SCIENCE", LIST("SURFACE_SCIENCE"),
        "SURFACE_REVIEW", LIST("SURFACE_REVIEW"),
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
    ELSE IF phaseKey = "EXCURSION_READY" { phaseMapSet(phaseMap, phaseKey, phaseExcursionReady@). }
    ELSE IF phaseKey = "SCIENCE_OPS_LOW" { phaseMapSet(phaseMap, phaseKey, phaseScienceOpsLow@). }
    ELSE IF phaseKey = "SCIENCE_ENTRY" { phaseMapSet(phaseMap, phaseKey, phaseScienceEntry@). }
    ELSE IF phaseKey = "LANDING_REVIEW" { phaseMapSet(phaseMap, phaseKey, phaseLandingReview@). }
    ELSE IF phaseKey = "ATMO_DEORBIT" { phaseMapSet(phaseMap, phaseKey, phaseAtmoDeorbit@). }
    ELSE IF phaseKey = "SCIENCE_IMPACT" { phaseMapSet(phaseMap, phaseKey, phaseScienceImpact@). }
    ELSE IF phaseKey = "SURFACE_SCIENCE" { phaseMapSet(phaseMap, phaseKey, phaseSurfaceScience@). }
    ELSE IF phaseKey = "SURFACE_REVIEW" { phaseMapSet(phaseMap, phaseKey, phaseSurfaceReview@). }
    ELSE IF phaseKey = "MOLNIYA_PAIR" { phaseMapSet(phaseMap, phaseKey, phaseMolniyaPair@). }
    ELSE IF phaseKey = "ORBITAL_SURVEY" { phaseMapSet(phaseMap, phaseKey, phaseOrbitalSurvey@). }
    ELSE IF phaseKey = "LAUNCH" { phaseMapSet(phaseMap, phaseKey, phaseLaunch@). }
    ELSE IF phaseKey = "HOP" { phaseMapSet(phaseMap, phaseKey, phaseHop@). }
    ELSE IF phaseKey = "HOP_REVIEW" { phaseMapSet(phaseMap, phaseKey, phaseHopReview@). }
    ELSE IF phaseKey = "HOP_ROUTE_SETUP" { phaseMapSet(phaseMap, phaseKey, phaseHopRouteSetup@). }
    ELSE IF phaseKey = "HOP_AUTO_REVIEW" { phaseMapSet(phaseMap, phaseKey, phaseHopAutoReview@). }
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
    // The atmospheric handler was removed when the vacuum solver replaced
    // deorbit_targeting. Let runPhases report/hold a missing handler rather
    // than crashing while evaluating an undefined delegate.
    ELSE IF phaseKey = "KSC_DEORBIT" {
        IF DEFINED phaseKscDeorbit { phaseMapSet(phaseMap, phaseKey, phaseKscDeorbit@). }
    }
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
    ELSE IF phaseKey = "RETURN_SETUP" {
        IF DEFINED RETURN_SETUP_LOADED AND RETURN_SETUP_LOADED { phaseMapSet(phaseMap, phaseKey, phaseReturnSetup@). }
        ELSE IF stateGet("phase", "") = phaseKey { mLogError("RETURN_SETUP library unavailable; obtain a link and reboot to cache return_setup."). }
    }
    ELSE IF phaseKey = "SURFACE_RETURN_SETUP" {
        IF DEFINED RETURN_SETUP_LOADED AND RETURN_SETUP_LOADED { phaseMapSet(phaseMap, phaseKey, phaseSurfaceReturnSetup@). }
        ELSE IF stateGet("phase", "") = phaseKey { mLogError("SURFACE_RETURN_SETUP library unavailable; obtain a link and reboot to cache return_setup."). }
    }
    ELSE IF phaseKey = "LAND_DEORBIT" { phaseMapSet(phaseMap, phaseKey, phaseLandDeorbit@). }
    ELSE IF phaseKey = "LAND_PREP" { phaseMapSet(phaseMap, phaseKey, phaseLandPrep@). }
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
    ELSE IF phaseKey = "ASSIST" { phaseMapSet(phaseMap, phaseKey, phaseAssist@). }
    ELSE IF phaseKey = "ASSIST_COAST" { phaseMapSet(phaseMap, phaseKey, phaseAssistCoast@). }
    ELSE IF phaseKey = "REFINE_BPLANE" { phaseMapSet(phaseMap, phaseKey, phaseRefineBplane@). }
    ELSE IF phaseKey = "FREE_RT_BPLANE" { phaseMapSet(phaseMap, phaseKey, phaseFreeRtBplane@). }
    ELSE IF phaseKey = "RETURN_TRIM" { phaseMapSet(phaseMap, phaseKey, phaseReturnTrim@). }
    ELSE IF phaseKey = "GOTO" { phaseMapSet(phaseMap, phaseKey, phaseGoto@). }
    ELSE IF phaseKey = "AIRCLIMB" { phaseMapSet(phaseMap, phaseKey, phaseAirclimb@). }
    ELSE IF phaseKey = "ROCKETCLIMB" { phaseMapSet(phaseMap, phaseKey, phaseRocketclimb@). }
    ELSE IF phaseKey = "SSTO_DEORBIT" { phaseMapSet(phaseMap, phaseKey, phaseSstoDeorbit@). }
    ELSE IF phaseKey = "REENTRY" { phaseMapSet(phaseMap, phaseKey, phaseReentry@). }
    ELSE IF phaseKey = "APPROACH" { phaseMapSet(phaseMap, phaseKey, phaseApproach@). }
    ELSE IF phaseKey = "ARM" { phaseMapSet(phaseMap, phaseKey, phaseArm@). }
    ELSE IF phaseKey = "FLY" { phaseMapSet(phaseMap, phaseKey, phaseFly@). }
}
