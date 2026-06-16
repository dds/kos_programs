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

GLOBAL CFG IS LEXICON(
    "DESCENT_DECOUPLER_TAG", "none"
).

applyKnownMissionState().

LOCAL FUNCTION _fr3PrintConfig {
    LOCAL seq IS fr3BuildPhaseSequence().
    flightPlanTitle("FR3C SCANSAT FLIGHT PLAN", SHIP:NAME).
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
    IF phaseHandlerMap():HASKEY(nxt) {
        mLog("Parking checkpoint: " + nxt + " already loaded - continuing.").
        RETURN.
    }
    fr3SaveReloadState("PARKING_ORBIT", nxt).
    mLog("Parking orbit reload point - auto-rebooting for " + nxt + ".").
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
        "SCANSAT", LIST("SCANSAT_OPS")
    ).

    RETURN buildRocketSequence(orbitPhases, payloadPhases).
}

GLOBAL FUNCTION fr3BuildPhaseMap {
    LOCAL phaseMap IS phaseHandlerMap().
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
    "vehicle", "FR3C",
    "keepCmds", LIST("DUMP", "SETPHASE", "SCANSATDEORBIT")
).

GLOBAL FUNCTION main {
    LOCAL seq IS fr3BuildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR3C SCANSAT MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    bootEnsureInitialPhase(seq).

    IF fr3PhaseBand() = "LAUNCH" {
        IF NOT confirmLaunch(_fr3PrintConfig@) { RETURN. }
    }

    runPhases(fr3BuildPhaseMap()).
}
