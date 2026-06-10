GLOBAL FUNCTION dependencyBindPhase {
    PARAMETER phaseMap.
    PARAMETER phaseName.
    LOCAL phaseKey IS phaseName.
    IF phaseKey = "PREFLIGHT" { phaseMapSet(phaseMap, "PREFLIGHT", phasePreflight@). }
    ELSE IF phaseKey = "FLIGHT" { phaseMapSet(phaseMap, "FLIGHT", phaseFlight@). }
    ELSE IF phaseKey = "POST_FLIGHT" { phaseMapSet(phaseMap, "POST_FLIGHT", phasePostFlight@). }
    ELSE IF phaseKey = "POSTFLIGHT" { phaseMapSet(phaseMap, "POSTFLIGHT", phasePostflight@). }
    ELSE IF phaseKey = "EVA_SCIENCE" { phaseMapSet(phaseMap, "EVA_SCIENCE", phaseEvaScience@). }
    ELSE IF phaseKey = "PRELAUNCH" { phaseMapSet(phaseMap, "PRELAUNCH", phasePrelaunch@). }
    ELSE IF phaseKey = "LAUNCH" { phaseMapSet(phaseMap, "LAUNCH", phaseLaunch@). }
    ELSE IF phaseKey = "FAIR" { phaseMapSet(phaseMap, "FAIR", phaseFair@). }
    ELSE IF phaseKey = "ANTS" { phaseMapSet(phaseMap, "ANTS", phaseAnts@). }
    ELSE IF phaseKey = "PARK" { phaseMapSet(phaseMap, "PARK", phasePark@). }
    ELSE IF phaseKey = "RDV" { phaseMapSet(phaseMap, "RDV", phaseRdv@). }
    ELSE IF phaseKey = "XING" { phaseMapSet(phaseMap, "XING", phaseXing@). }
    ELSE IF phaseKey = "ESCAPE" { phaseMapSet(phaseMap, "ESCAPE", phaseEscape@). }
    ELSE IF phaseKey = "MCC" { phaseMapSet(phaseMap, "MCC", phaseMcc@). }
    ELSE IF phaseKey = "AEROBRAKE" { phaseMapSet(phaseMap, "AEROBRAKE", phaseAerobrake@). }
    ELSE IF phaseKey = "DESCENT" { phaseMapSet(phaseMap, "DESCENT", phaseDescent@). }
    ELSE IF phaseKey = "KSC_DEORBIT" { phaseMapSet(phaseMap, "KSC_DEORBIT", phaseKscDeorbit@). }
    ELSE IF phaseKey = "COAST" { phaseMapSet(phaseMap, "COAST", phaseCoast@). }
    ELSE IF phaseKey = "CAPTURE" { phaseMapSet(phaseMap, "CAPTURE", phaseCapture@). }
    ELSE IF phaseKey = "CIRC" { phaseMapSet(phaseMap, "CIRC", phaseCirc@). }
    ELSE IF phaseKey = "RAISE" { phaseMapSet(phaseMap, "RAISE", phaseRaise@). }
    ELSE IF phaseKey = "INCLINE" { phaseMapSet(phaseMap, "INCLINE", phaseIncline@). }
    ELSE IF phaseKey = "ELLIPTICAL" { phaseMapSet(phaseMap, "ELLIPTICAL", phaseElliptical@). }
    ELSE IF phaseKey = "TARGETED_DEORBIT" { phaseMapSet(phaseMap, "TARGETED_DEORBIT", phaseTargetedDeorbit@). }
    ELSE IF phaseKey = "RELEASE_PROBE" { phaseMapSet(phaseMap, "RELEASE_PROBE", phaseReleaseProbe@). }
    ELSE IF phaseKey = "RELAY_OPS" { phaseMapSet(phaseMap, "RELAY_OPS", phaseRelayOps@). }
    ELSE IF phaseKey = "SCANSAT_OPS" { phaseMapSet(phaseMap, "SCANSAT_OPS", phaseScansatOps@). }
    ELSE IF phaseKey = "LAND_DEORBIT" { phaseMapSet(phaseMap, "LAND_DEORBIT", phaseLandDeorbit@). }
    ELSE IF phaseKey = "LAND" { phaseMapSet(phaseMap, "LAND", phaseLand@). }
    ELSE IF phaseKey = "LAND_ASSIST" { phaseMapSet(phaseMap, "LAND_ASSIST", phaseLandAssist@). }
    ELSE IF phaseKey = "ROVER" { phaseMapSet(phaseMap, "ROVER", phaseRover@). }
    ELSE IF phaseKey = "MOLNIYA" { phaseMapSet(phaseMap, "MOLNIYA", phaseMolniya@). }
    ELSE IF phaseKey = "MOLNIYA_INSERT" { phaseMapSet(phaseMap, "MOLNIYA_INSERT", phaseMolniyaInsert@). }
    ELSE IF phaseKey = "DROP_FOR_IMPACT_AND_RAISE_PE" { phaseMapSet(phaseMap, "DROP_FOR_IMPACT_AND_RAISE_PE", phaseDropForImpactAndRaisePe@). }
    ELSE IF phaseKey = "SHAPE" { phaseMapSet(phaseMap, "SHAPE", phaseShape@). }
    ELSE IF phaseKey = "BPLANE" { phaseMapSet(phaseMap, "BPLANE", phaseBplane@). }
    ELSE IF phaseKey = "GOTO" { phaseMapSet(phaseMap, "GOTO", phaseGoto@). }
    ELSE IF phaseKey = "AIRCLIMB" { phaseMapSet(phaseMap, "AIRCLIMB", phaseAirclimb@). }
    ELSE IF phaseKey = "ROCKETCLIMB" { phaseMapSet(phaseMap, "ROCKETCLIMB", phaseRocketclimb@). }
    ELSE IF phaseKey = "SSTO_DEORBIT" { phaseMapSet(phaseMap, "SSTO_DEORBIT", phaseSstoDeorbit@). }
    ELSE IF phaseKey = "REENTRY" { phaseMapSet(phaseMap, "REENTRY", phaseReentry@). }
    ELSE IF phaseKey = "APPROACH" { phaseMapSet(phaseMap, "APPROACH", phaseApproach@). }
    ELSE IF phaseKey = "ARM" { phaseMapSet(phaseMap, "ARM", phaseArm@). }
    ELSE IF phaseKey = "FLY" { phaseMapSet(phaseMap, "FLY", phaseFly@). }
}
