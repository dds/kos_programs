// ============================================================
// fr3_sequence.ks - FR3 sequence construction and phase map
// ============================================================

LOCAL FUNCTION _phaseListFromString {
    PARAMETER raw.
    LOCAL seq IS LIST().
    FOR phaseRaw IN raw:SPLIT(",") {
        LOCAL phaseName IS phaseRaw:TRIM:TOUPPER.
        IF phaseName <> "" { seq:ADD(phaseName). }
    }
    IF seq:LENGTH = 0 { seq:ADD("DONE"). }
    RETURN seq.
}

LOCAL FUNCTION _phaseParkingReload {
    phaseParking().
    IF CFG:HASKEY("RELOAD_AFTER_PARK") AND CFG["RELOAD_AFTER_PARK"] > 0 {
        fr3SaveReloadState("PARKING_ORBIT", stateGet("phase", "")).
        mLog("Reload point after parking orbit. Reboot to load transfer libraries.").
        PRINT " ".
        PRINT "  PARKING ORBIT READY".
        PRINT "  Reboot this CPU to load transfer code.".
        yieldToPrompt().
        RETURN.
    }
}

GLOBAL FUNCTION fr3BuildPhaseSequence {
    IF CFG:HASKEY("SEQUENCE") {
        RETURN _phaseListFromString(CFG["SEQUENCE"]).
    }

    LOCAL orbitPhases IS LIST("CIRC", "RAISE", "INCLINE").
    IF CFG:HASKEY("SCANSAT_RELEASE_AFTER_CAPTURE")
            AND CFG["SCANSAT_RELEASE_AFTER_CAPTURE"] > 0 {
        SET orbitPhases TO LIST("SCANSAT_IMPACT_RELEASE").
    }
    LOCAL payloadPhases IS LEXICON(
        "CRASHPROBE", LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "PROBE",      LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "RELAY",      LIST("RELAY_OPS"),
        "SCANSAT",    LIST("SCANSAT_OPS"),
        "SCISAT",     LIST("RELAY_OPS"),
        "ASSISTLANDER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND"),
        "LANDER",     LIST("LAND_DEORBIT", "LAND"),
        "ASSISTROVER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND", "ROVER"),
        "ROVER",      LIST("LAND_DEORBIT", "LAND", "ROVER")
    ).

    RETURN buildRocketSequence(orbitPhases, payloadPhases).
}

GLOBAL FUNCTION fr3BuildPhaseMap {
    LOCAL band IS fr3PhaseBand().
    LOCAL phaseMap IS LEXICON().

    IF band = "LAUNCH" {
        phaseMap:ADD("LUNCH", phaseLaunch@).
        phaseMap:ADD("FAIR", phaseFairing@).
        phaseMap:ADD("ANTS", phaseExtendAnts@).
        phaseMap:ADD("PARK", _phaseParkingReload@).
    }

    IF band = "TRANSFER" {
        phaseMap:ADD("RDV", phaseRendezvous@).
        phaseMap:ADD("XING", phaseTransfer@).
        phaseMap:ADD("MCC", phaseMidCourse@).
        phaseMap:ADD("COAST", phaseCoast@).
        phaseMap:ADD("CAPTURE", phaseCapture@).
        phaseMap:ADD("CIRC", phaseCirc@).
        phaseMap:ADD("RAISE", phaseRaiseAlt@).
        phaseMap:ADD("INCLINE", phaseInclCorrect@).
        phaseMap:ADD("SCANSAT_IMPACT_RELEASE", phaseScanSatImpactRelease@).
    }

    IF band = "PAYLOAD_OPS" AND (fr3HasPayload("PROBE") OR fr3HasPayload("CRASHPROBE")) {
        phaseMap:ADD("TARGETED_DEORBIT", phaseTargetedDeorbit@).
        phaseMap:ADD("RELEASE_PROBE", phaseReleaseProbe@).
    }
    IF band = "PAYLOAD_OPS" AND (fr3HasPayload("RELAY") OR fr3HasPayload("SCISAT")) {
        phaseMap:ADD("RELAY_OPS", phaseRelayOps@).
    }
    IF band = "PAYLOAD_OPS" AND fr3HasPayload("SCANSAT") {
        phaseMap:ADD("SCANSAT_OPS", phaseScanSatOps@).
    }
    IF band = "LAND_DEORBIT" {
        phaseMap:ADD("LAND_DEORBIT", phaseLandDeorbit@).
        phaseMap:ADD("LAND_ASSIST", phaseLandAssist@).
    }
    IF band = "LAND_ASSIST" {
        phaseMap:ADD("LAND_DEORBIT", phaseLandDeorbit@).
        phaseMap:ADD("LAND_ASSIST", phaseLandAssist@).
    }
    IF band = "LAND" {
        phaseMap:ADD("LAND", phaseLand@).
    }
    IF band = "ROVER" {
        phaseMap:ADD("ROVER", phaseRover@).
    }

    RETURN phaseMap.
}
