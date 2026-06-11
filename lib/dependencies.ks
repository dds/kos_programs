LOCAL FUNCTION _depLoaded {
    PARAMETER libsCsv.
    FOR libName IN libsCsv:SPLIT(",") {
        IF libName <> "" {
            IF NOT EXISTS("1:/lib/" + libName + ".ksm")
                    AND NOT EXISTS("1:/lib/" + libName + ".ks") {
                RETURN FALSE.
            }
        }
    }
    RETURN TRUE.
}

GLOBAL FUNCTION dependencyBindPhase {
    PARAMETER phaseMap.
    PARAMETER phaseName.
    LOCAL phaseKey IS phaseName.
    IF phaseKey = "PREFLIGHT" { IF _depLoaded("airplane") { phaseMapSet(phaseMap, "PREFLIGHT", phasePreflight@). } }
    ELSE IF phaseKey = "FLIGHT" { IF _depLoaded("airplane") { phaseMapSet(phaseMap, "FLIGHT", phaseFlight@). } }
    ELSE IF phaseKey = "POST_FLIGHT" { IF _depLoaded("airplane") { phaseMapSet(phaseMap, "POST_FLIGHT", phasePostFlight@). } }
    ELSE IF phaseKey = "POSTFLIGHT" { IF _depLoaded("airplane") { phaseMapSet(phaseMap, "POSTFLIGHT", phasePostflight@). } }
    ELSE IF phaseKey = "EVA_SCIENCE" { IF _depLoaded("science,orbit") { phaseMapSet(phaseMap, "EVA_SCIENCE", phaseEvaScience@). } }
    ELSE IF phaseKey = "PRELAUNCH" { IF _depLoaded("launch") { phaseMapSet(phaseMap, "PRELAUNCH", phasePrelaunch@). } }
    ELSE IF phaseKey = "LAUNCH" { IF _depLoaded("launch") { phaseMapSet(phaseMap, "LAUNCH", phaseLaunch@). } }
    ELSE IF phaseKey = "FAIR" { IF _depLoaded("launch") { phaseMapSet(phaseMap, "FAIR", phaseFair@). } }
    ELSE IF phaseKey = "ANTS" { IF _depLoaded("launch") { phaseMapSet(phaseMap, "ANTS", phaseAnts@). } }
    ELSE IF phaseKey = "PARK" { IF _depLoaded("launch") { phaseMapSet(phaseMap, "PARK", phasePark@). } }
    ELSE IF phaseKey = "SUBORBIT" { IF _depLoaded("launch") { phaseMapSet(phaseMap, "SUBORBIT", phaseSuborbit@). } }
    ELSE IF phaseKey = "ABORT" { IF _depLoaded("launch") { phaseMapSet(phaseMap, "ABORT", phaseAbort@). } }
    ELSE IF phaseKey = "RDV" { IF _depLoaded("xfer_plan,maneuver_rendezvous") { phaseMapSet(phaseMap, "RDV", phaseRdv@). } }
    ELSE IF phaseKey = "MATCH" { IF _depLoaded("maneuver_rendezvous") { phaseMapSet(phaseMap, "MATCH", phaseMatch@). } }
    ELSE IF phaseKey = "CREW_XFER" { IF _depLoaded("maneuver_rendezvous") { phaseMapSet(phaseMap, "CREW_XFER", phaseCrewXfer@). } }
    ELSE IF phaseKey = "XING" { IF _depLoaded("xfer_plan") { phaseMapSet(phaseMap, "XING", phaseXing@). } }
    ELSE IF phaseKey = "ESCAPE" { IF _depLoaded("xfer_plan") { phaseMapSet(phaseMap, "ESCAPE", phaseEscape@). } }
    ELSE IF phaseKey = "MCC" { IF _depLoaded("maneuver_mcc") { phaseMapSet(phaseMap, "MCC", phaseMcc@). } }
    ELSE IF phaseKey = "AEROBRAKE" { IF _depLoaded("aerobrake") { phaseMapSet(phaseMap, "AEROBRAKE", phaseAerobrake@). } }
    ELSE IF phaseKey = "DESCENT" { IF _depLoaded("descent") { phaseMapSet(phaseMap, "DESCENT", phaseDescent@). } }
    ELSE IF phaseKey = "KSC_DEORBIT" { IF _depLoaded("deorbit_targeting,maneuver") { phaseMapSet(phaseMap, "KSC_DEORBIT", phaseKscDeorbit@). } }
    ELSE IF phaseKey = "COAST" { IF _depLoaded("capture") { phaseMapSet(phaseMap, "COAST", phaseCoast@). } }
    ELSE IF phaseKey = "CAPTURE" { IF _depLoaded("capture") { phaseMapSet(phaseMap, "CAPTURE", phaseCapture@). } }
    ELSE IF phaseKey = "CIRC" { IF _depLoaded("maneuver_orbit") { phaseMapSet(phaseMap, "CIRC", phaseCirc@). } }
    ELSE IF phaseKey = "RAISE" { IF _depLoaded("maneuver_orbit") { phaseMapSet(phaseMap, "RAISE", phaseRaise@). } }
    ELSE IF phaseKey = "INCLINE" { IF _depLoaded("maneuver_orbit") { phaseMapSet(phaseMap, "INCLINE", phaseIncline@). } }
    ELSE IF phaseKey = "ELLIPTICAL" { IF _depLoaded("maneuver_orbit") { phaseMapSet(phaseMap, "ELLIPTICAL", phaseElliptical@). } }
    ELSE IF phaseKey = "TARGETED_DEORBIT" { IF _depLoaded("payload_ops,deorbit_targeting") { phaseMapSet(phaseMap, "TARGETED_DEORBIT", phaseTargetedDeorbit@). } }
    ELSE IF phaseKey = "RELEASE_PROBE" { IF _depLoaded("payload_ops") { phaseMapSet(phaseMap, "RELEASE_PROBE", phaseReleaseProbe@). } }
    ELSE IF phaseKey = "RELAY_OPS" { IF _depLoaded("payload_ops") { phaseMapSet(phaseMap, "RELAY_OPS", phaseRelayOps@). } }
    ELSE IF phaseKey = "SCANSAT_OPS" { IF _depLoaded("payload_ops,science") { phaseMapSet(phaseMap, "SCANSAT_OPS", phaseScansatOps@). } }
    ELSE IF phaseKey = "LAND_DEORBIT" { IF _depLoaded("payload_landing") { phaseMapSet(phaseMap, "LAND_DEORBIT", phaseLandDeorbit@). } }
    ELSE IF phaseKey = "LAND" { IF _depLoaded("payload_landing") { phaseMapSet(phaseMap, "LAND", phaseLand@). } }
    ELSE IF phaseKey = "LAND_ASSIST" { IF _depLoaded("payload_landing") { phaseMapSet(phaseMap, "LAND_ASSIST", phaseLandAssist@). } }
    ELSE IF phaseKey = "ROVER" { IF _depLoaded("rover") { phaseMapSet(phaseMap, "ROVER", phaseRover@). } }
    ELSE IF phaseKey = "MOLNIYA" { IF _depLoaded("molniya") { phaseMapSet(phaseMap, "MOLNIYA", phaseMolniya@). } }
    ELSE IF phaseKey = "MOLNIYA_INSERT" { IF _depLoaded("molniya") { phaseMapSet(phaseMap, "MOLNIYA_INSERT", phaseMolniyaInsert@). } }
    ELSE IF phaseKey = "DROP_FOR_IMPACT_AND_RAISE_PE" { IF _depLoaded("payload_release") { phaseMapSet(phaseMap, "DROP_FOR_IMPACT_AND_RAISE_PE", phaseDropForImpactAndRaisePe@). } }
    ELSE IF phaseKey = "SHAPE" { IF _depLoaded("orbit_shape") { phaseMapSet(phaseMap, "SHAPE", phaseShape@). } }
    ELSE IF phaseKey = "BPLANE" { IF _depLoaded("arrival_bplane") { phaseMapSet(phaseMap, "BPLANE", phaseBplane@). } }
    ELSE IF phaseKey = "GOTO" { IF _depLoaded("goto_plan") { phaseMapSet(phaseMap, "GOTO", phaseGoto@). } }
    ELSE IF phaseKey = "AIRCLIMB" { IF _depLoaded("ssto") { phaseMapSet(phaseMap, "AIRCLIMB", phaseAirclimb@). } }
    ELSE IF phaseKey = "ROCKETCLIMB" { IF _depLoaded("ssto") { phaseMapSet(phaseMap, "ROCKETCLIMB", phaseRocketclimb@). } }
    ELSE IF phaseKey = "SSTO_DEORBIT" { IF _depLoaded("ssto") { phaseMapSet(phaseMap, "SSTO_DEORBIT", phaseSstoDeorbit@). } }
    ELSE IF phaseKey = "REENTRY" { IF _depLoaded("ssto") { phaseMapSet(phaseMap, "REENTRY", phaseReentry@). } }
    ELSE IF phaseKey = "APPROACH" { IF _depLoaded("ssto") { phaseMapSet(phaseMap, "APPROACH", phaseApproach@). } }
    ELSE IF phaseKey = "ARM" { IF _depLoaded("drone") { phaseMapSet(phaseMap, "ARM", phaseArm@). } }
    ELSE IF phaseKey = "FLY" { IF _depLoaded("drone") { phaseMapSet(phaseMap, "FLY", phaseFly@). } }
}
