// ============================================================
// scansat.ks - Primary SCANsat mission CPU role (0:/roles/scansat.ks)
//
// Set CORE:TAG = "scansat" on the mapper probe core. This core
// flies the FR3C mission through ascent, orbit shaping, release,
// mapping, and end-of-life impact disposal.
//
// A secondary stage-return core should use CORE:TAG =
// "stage2_deorbit"; that role stays quiet until separation, then
// brings the sustainer stage home.
// ============================================================

SET DESCENT_DECOUPLER_TAG TO "none".

applyKnownMissionState().

LOCAL FUNCTION _fr3PrintConfig {
    LOCAL seq IS fr3BuildPhaseSequence().
    flightPlanTitle("FR3C SCANSAT FLIGHT PLAN", SHIP:NAME).
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
        "SCANSAT", LIST("SCANSAT_OPS")
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
    "vehicle", "FR3C"
).

GLOBAL FUNCTION main {
    rocketMain(fr3BuildPhaseSequence@, fr3BuildPhaseMap@).
}
