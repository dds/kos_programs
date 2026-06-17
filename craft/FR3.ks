// ============================================================
// FR3.ks  —  FR3 vehicle flight computer  (0:/craft/FR3.ks)
//
// Ship name:  FR3-TARGET-TYPE1-TYPE2-...-NN
// Payload tokens: RELAY, SCANSAT, SCISAT, LANDER, ASSISTLANDER,
//                 ROVER, ASSISTROVER, PROBE, CRASHPROBE
// ============================================================

SET DESCENT_DECOUPLER_TAG TO "none".

applyKnownMissionState().

LOCAL FUNCTION _fr3PrintConfig {
    LOCAL seq IS fr3BuildPhaseSequence().
    flightPlanTitle("FR3 FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("MISSION").
    flightPlanRow("BAND", phaseBand()).
    flightPlanRow("TARGET", getTarget()).
    flightPlanRow("PAYLOADS", PAYLOADS).
    flightPlanConfig().
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

GLOBAL FUNCTION fr3BuildPhaseSequence {
    IF SEQUENCE <> "" {
        RETURN phaseListFromString(SEQUENCE).
    }

    LOCAL orbitPhases IS LIST("CIRC", "RAISE", "INCLINE").
    IF SCANSAT_RELEASE_AFTER_CAPTURE > 0 {
        SET orbitPhases TO LIST("DROP_FOR_IMPACT_AND_RAISE_PE").
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
    LOCAL phaseMap IS LEXICON().
    phaseMapSet(phaseMap, "PARK", phaseParkingReload@).
    RETURN phaseMap.
}

LOCAL FUNCTION _fr3LibsForBand {
    PARAMETER band.
    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots, missionTypeConditionalRoots(band)).
    missionAppendUnique(roots, missionExtraLibs()).
    RETURN bootLibResolve(roots).
}

LOCAL FUNCTION _fr3Libs {
    bootEnsureInitialPhase(fr3BuildPhaseSequence()).
    LOCAL band IS phaseBand().
    LOCAL phase IS stateGet("phase", "").
    LOCAL cachedLibs IS bootCachedVehicleLibs(band).
    IF cachedLibs:LENGTH > 0 {
        stateSet("lib_band_phase", phase).
        stateSet("reload_required", "false").
        RETURN cachedLibs.
    }
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").
    LOCAL libs IS _fr3LibsForBand(band).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN _fr3Libs().
}

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FR3"
).

GLOBAL FUNCTION main {
    LOCAL seq IS fr3BuildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR3 MAIN").
    mLog("Sequence: " + seq:JOIN(" -> ")).
    bootEnsureInitialPhase(seq).

    IF phaseBand() = "LAUNCH" {
        IF NOT confirmLaunch(_fr3PrintConfig@) { RETURN. }
    }

    runPhases(fr3BuildPhaseMap()).
}
