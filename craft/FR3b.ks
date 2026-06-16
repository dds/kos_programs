// ============================================================
// FR3b.ks  —  FR3b vehicle flight computer  (0:/craft/FR3b.ks)
//
// Two-seat variant of the FR3: same lifter family, double-mass
// crew pod. Same contract and phase plumbing as FR3.
// Ship name:  FR3b-TARGET-TYPE1-...-NN
// ============================================================

GLOBAL CFG IS LEXICON(
    // Flight-found: decoupling the leftover transfer stage during
    // DESCENT exploded it next to the lander at touchdown. FR3
    // rides its stack all the way down; missions/cmd opts can
    // still override with a real tag.
    "DESCENT_DECOUPLER_TAG", "none"
).

applyKnownMissionState().

LOCAL FUNCTION _fr3PrintConfig {
    LOCAL seq IS fr3BuildPhaseSequence().
    flightPlanTitle("FR3B FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("MISSION").
    flightPlanRow("BAND", fr3PhaseBand()).
    flightPlanRow("TARGET", MISSION["target"]).
    flightPlanRow("PAYLOADS", MISSION["payloads"]).
    flightPlanConfig().
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

GLOBAL FUNCTION fr3BandForPhase {
    PARAMETER phaseName.
    LOCAL phase IS phaseName.
    LOCAL defaultBand IS "".
    IF phase = "" OR phase:CONTAINS("MAIN") {
        SET defaultBand TO "LAUNCH".
    }
    RETURN bootLibBandForPhase(phase, defaultBand).
}

GLOBAL FUNCTION fr3PhaseBand {
    RETURN fr3BandForPhase(stateGet("phase", "")).
}

GLOBAL FUNCTION fr3SaveReloadState {
    PARAMETER reason.
    PARAMETER nextPhaseName.
    stateSet("reload_required", "true").
    stateSet("reload_reason", reason).
    stateSet("reload_next_phase", nextPhaseName).
    stateSet("reload_next_band", fr3BandForPhase(nextPhaseName)).
}

LOCAL FUNCTION _fr3PhaseParkingReload {
    phaseParking().
    LOCAL nxt IS stateGet("phase", "").
    // Next phase already bound (libs aboard via LIBS_EXTRA or the
    // same band): keep flying — no checkpoint needed.
    IF phaseInLoadedBand(nxt) {
        mLog("Parking checkpoint: " + nxt + " already loaded — continuing.").
        RETURN.
    }
    fr3SaveReloadState("PARKING_ORBIT", nxt).
    mLog("Parking orbit reload point — auto-rebooting for " + nxt + ".").
    HUDTEXT("Parking orbit: rebooting for " + nxt + "...",
        5, 2, 15, CYAN, FALSE).
    WAIT 5.
    REBOOT.
}

GLOBAL FUNCTION fr3BuildPhaseSequence {
    IF CFG:HASKEY("SEQUENCE") {
        RETURN phaseListFromString(CFG["SEQUENCE"]).
    }

    LOCAL orbitPhases IS LIST("CIRC", "RAISE", "INCLINE").
    IF CFG:HASKEY("SCANSAT_RELEASE_AFTER_CAPTURE")
            AND CFG["SCANSAT_RELEASE_AFTER_CAPTURE"] > 0 {
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
    phaseMapSet(phaseMap, "PARK", _fr3PhaseParkingReload@).
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
    LOCAL band IS fr3PhaseBand().
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
    "vehicle", "FR3b"
).

GLOBAL FUNCTION main {
    LOCAL seq IS fr3BuildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR3B MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    bootEnsureInitialPhase(seq).

    IF fr3PhaseBand() = "LAUNCH" {
        IF NOT confirmLaunch(_fr3PrintConfig@) { RETURN. }
    }

    runPhases(fr3BuildPhaseMap()).
}
