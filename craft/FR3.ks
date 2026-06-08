// ============================================================
// FR3.ks  —  FR3 vehicle flight computer  (0:/craft/FR3.ks)
//
// Ship name:  FR3-TARGET-TYPE1-TYPE2-...-NN
// Payload tokens: RELAY, SCANSAT, SCISAT, LANDER, ASSISTLANDER,
//                 ROVER, ASSISTROVER, PROBE, CRASHPROBE
// ============================================================

GLOBAL CFG IS LEXICON().

applyKnownMissionState().
GLOBAL fr3Seq IS LIST().

LOCAL FUNCTION _fr3PrintConfig {
}

GLOBAL FUNCTION fr3BandForPhase {
    PARAMETER phaseName.
    LOCAL defaultBand IS "".
    IF phaseName:TOUPPER = "" { SET defaultBand TO "LAUNCH". }
    RETURN bootLibBandForPhase(phaseName, defaultBand).
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

GLOBAL FUNCTION fr3ApplyMissionProfile {
    IF MISSION["target"]:TOUPPER = "MUN" AND missionHasLandingPayload() {
        IF DEFINED LAND_CFG {
            SET LAND_CFG["DEORBIT_PE"] TO 5000.
            SET LAND_CFG["TARGET_TOLERANCE"] TO 2500.
            SET LAND_CFG["GUIDANCE_ALT"] TO 5000.
        }
    }

    IF DEFINED landingApplyMissionConfig { landingApplyMissionConfig(). }
}

LOCAL FUNCTION _fr3PhaseParkingReload {
    phaseParking().
    fr3SaveReloadState("PARKING_ORBIT", stateGet("phase", "")).
    mLog("Reload point after parking orbit. Reboot to load transfer libraries.").
    PRINT " ".
    PRINT "  PARKING ORBIT READY".
    PRINT "  Reboot this CPU to load transfer code.".
    yieldToPrompt().
    RETURN.
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
    LOCAL phaseMap IS phaseHandlerMap().
    IF DEFINED phaseMapSet {
        phaseMapSet(phaseMap, "PARK", _fr3PhaseParkingReload@).
    }
    RETURN phaseMap.
}

LOCAL FUNCTION _fr3ConditionalRoots {
    PARAMETER band.
    LOCAL roots IS LIST().
    IF band = "XFER_PLAN" AND stateGet("target", "KERBIN"):TOUPPER <> "MUN" {
        roots:ADD("maneuver_intersystem").
    }
    IF band = "XFER_PLAN" AND (CFG:HASKEY("RENDEZVOUS_TARGET") OR CFG:HASKEY("ASTEROID_TARGET")) {
        roots:ADD("maneuver_rendezvous").
    }
    IF band = "PAYLOAD_OPS" AND contains(stateGet("phase", ""):TOUPPER, LIST("TARGETED_DEORBIT")) {
        roots:ADD("deorbit_targeting").
    }
    IF band = "PAYLOAD_OPS"
            AND (missionHasPayload("SCANSAT") OR missionHasPayload("SCISAT")) {
        roots:ADD("science").
    }
    RETURN roots.
}

LOCAL FUNCTION _fr3LibsForBand {
    PARAMETER band.
    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots, _fr3ConditionalRoots(band)).
    missionAppendUnique(roots, missionListFromCsv(stateGet("mission_cfg_LIBS_EXTRA", ""))).
    RETURN bootLibResolve(roots).
}

LOCAL FUNCTION _fr3Libs {
    LOCAL band IS fr3PhaseBand().
    LOCAL phase IS stateGet("phase", ""):TOUPPER.
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").
    LOCAL libs IS _fr3LibsForBand(band).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL LIBS IS _fr3Libs().

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FR3",
    "keepCmds", LIST(
        "CLEANUP", "DUMP", "FILES", "LANDASSIST", "LANDINGCHECK",
        "LANDINGRESCUE", "LANDMIN", "SETLANDASSIST", "SETLANDINGDEORBIT",
        "SETLANDINGTAG", "SETSTATE", "SETUP_MUN_ROVER_LANDING_REAL",
        "SETUP_MUN_ROVER_LANDING_SIM", "SIMLANDHERE"
    )
).

GLOBAL FUNCTION main {
    fr3ApplyMissionProfile().
    LOCAL seq IS fr3BuildPhaseSequence().
    SET fr3Seq TO seq.
    IF DEFINED launchSeq { SET launchSeq TO seq. }
    IF DEFINED xferSeq { SET xferSeq TO seq. }

    mLogPhase("FR3 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    IF fr3PhaseBand() = "LAUNCH" {
        IF NOT confirmLaunch(_fr3PrintConfig@) { RETURN. }
    }

    runPhases(fr3BuildPhaseMap()).
}
