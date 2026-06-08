GLOBAL FUNCTION dependencyPhaseHandlers {
    LOCAL phaseMap IS LEXICON().
    IF DEFINED phasePreflight { phaseMap:ADD("PREFLIGHT", phasePreflight@). }
    IF DEFINED phaseFlight { phaseMap:ADD("FLIGHT", phaseFlight@). }
    IF DEFINED phasePostFlight { phaseMap:ADD("POST_FLIGHT", phasePostFlight@). }
    IF DEFINED phasePostflight { phaseMap:ADD("POSTFLIGHT", phasePostflight@). }
    IF DEFINED phaseEvaScience { phaseMap:ADD("EVA_SCIENCE", phaseEvaScience@). }
    IF DEFINED phaseLaunch { phaseMap:ADD("LAUNCH", phaseLaunch@). }
    IF DEFINED phaseFair { phaseMap:ADD("FAIR", phaseFair@). }
    IF DEFINED phaseAnts { phaseMap:ADD("ANTS", phaseAnts@). }
    IF DEFINED phasePark { phaseMap:ADD("PARK", phasePark@). }
    IF DEFINED phaseRdv { phaseMap:ADD("RDV", phaseRdv@). }
    IF DEFINED phaseXing { phaseMap:ADD("XING", phaseXing@). }
    IF DEFINED phaseMcc { phaseMap:ADD("MCC", phaseMcc@). }
    IF DEFINED phaseCoast { phaseMap:ADD("COAST", phaseCoast@). }
    IF DEFINED phaseCapture { phaseMap:ADD("CAPTURE", phaseCapture@). }
    IF DEFINED phaseCirc { phaseMap:ADD("CIRC", phaseCirc@). }
    IF DEFINED phaseRaise { phaseMap:ADD("RAISE", phaseRaise@). }
    IF DEFINED phaseIncline { phaseMap:ADD("INCLINE", phaseIncline@). }
    IF DEFINED phaseElliptical { phaseMap:ADD("ELLIPTICAL", phaseElliptical@). }
    IF DEFINED phaseTargetedDeorbit { phaseMap:ADD("TARGETED_DEORBIT", phaseTargetedDeorbit@). }
    IF DEFINED phaseReleaseProbe { phaseMap:ADD("RELEASE_PROBE", phaseReleaseProbe@). }
    IF DEFINED phaseRelayOps { phaseMap:ADD("RELAY_OPS", phaseRelayOps@). }
    IF DEFINED phaseScansatOps { phaseMap:ADD("SCANSAT_OPS", phaseScansatOps@). }
    IF DEFINED phaseLandDeorbit { phaseMap:ADD("LAND_DEORBIT", phaseLandDeorbit@). }
    IF DEFINED phaseLand { phaseMap:ADD("LAND", phaseLand@). }
    IF DEFINED phaseLandAssist { phaseMap:ADD("LAND_ASSIST", phaseLandAssist@). }
    IF DEFINED phaseRover { phaseMap:ADD("ROVER", phaseRover@). }
    IF DEFINED phaseMolniya { phaseMap:ADD("MOLNIYA", phaseMolniya@). }
    IF DEFINED phaseMolniyaInsert { phaseMap:ADD("MOLNIYA_INSERT", phaseMolniyaInsert@). }
    IF DEFINED phaseDropForImpactAndRaisePe { phaseMap:ADD("DROP_FOR_IMPACT_AND_RAISE_PE", phaseDropForImpactAndRaisePe@). }
    RETURN phaseMap.
}
