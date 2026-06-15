// ============================================================
// Falcon.ks  —  Falcon crew/tourist vehicle flight computer
// (0:/craft/Falcon.ks)
//
// Falcon borrows the FR3C launch/phase plumbing, but is scoped for
// crew and tourist flights. Falcon-X is the experimental single-seat
// pathfinder; later Falcon profiles can add more seats and payload
// roles without changing the boot script.
//
// Ship names:
//   Falcon                   opens normal Kerbin mission selection.
//   Falcon-X                 experimental single-seat pathfinder.
//   Falcon-MINMUS-SCISAT-01 parsed-name fallback when no profile is picked.
//   Falcon Minmus SciSAT 1   space-delimited fallback also parses.
// ============================================================

GLOBAL CFG IS LEXICON(
    "DESCENT_DROGUE_CUT_ALT", 4800).

GLOBAL BOOT_ARCHIVE_ONLY IS LIST(
    "xfer_plan",
    "maneuver_transfer",
    "maneuver_targeting"
).

applyKnownMissionState().
IF stateGet("secondary_active", "false") = "true" {
    IF CFG:HASKEY("SECONDARY_SEQUENCE") { cfgSet("SEQUENCE", CFG["SECONDARY_SEQUENCE"]). }
    IF CFG:HASKEY("SECONDARY_SHAPE_PE") { cfgSet("SHAPE_PE", CFG["SECONDARY_SHAPE_PE"]). }
    IF CFG:HASKEY("SECONDARY_SHAPE_AP") { cfgSet("SHAPE_AP", CFG["SECONDARY_SHAPE_AP"]). }
    IF CFG:HASKEY("SECONDARY_SHAPE_INC") { cfgSet("SHAPE_INC", CFG["SECONDARY_SHAPE_INC"]). }
    IF CFG:HASKEY("SECONDARY_SHAPE_LAN") { cfgSet("SHAPE_LAN", CFG["SECONDARY_SHAPE_LAN"]). }
    IF CFG:HASKEY("SECONDARY_SHAPE_AOP") { cfgSet("SHAPE_AOP", CFG["SECONDARY_SHAPE_AOP"]). }
}
IF stateGet("mission_cfg_LIBS_EXTRA", "") = "" AND CFG:HASKEY("LIBS_EXTRA") {
    stateSet("mission_cfg_LIBS_EXTRA", CFG["LIBS_EXTRA"]).
}

LOCAL FUNCTION _falconPrintConfig {
    LOCAL seq IS falconBuildPhaseSequence().
    flightPlanTitle("FALCON FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("MISSION").
    flightPlanRow("BAND", falconPhaseBand()).
    flightPlanRow("TARGET", MISSION["target"]).
    flightPlanRow("PAYLOADS", MISSION["payloads"]).
    flightPlanConfig().
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

GLOBAL FUNCTION falconBandForPhase {
    PARAMETER phaseName.
    LOCAL phase IS phaseName.
    LOCAL defaultBand IS "".
    IF phase = "" OR phase:CONTAINS("MAIN") {
        SET defaultBand TO "LAUNCH".
    }
    RETURN bootLibBandForPhase(phase, defaultBand).
}

GLOBAL FUNCTION falconPhaseBand {
    RETURN falconBandForPhase(stateGet("phase", "")).
}

GLOBAL FUNCTION falconSaveReloadState {
    PARAMETER reason.
    PARAMETER nextPhaseName.
    stateSet("reload_required", "true").
    stateSet("reload_reason", reason).
    stateSet("reload_next_phase", nextPhaseName).
    stateSet("reload_next_band", falconBandForPhase(nextPhaseName)).
}

LOCAL FUNCTION _falconPhaseParkingReload {
    phaseParking().
    LOCAL nxt IS stateGet("phase", "").
    IF phaseHandlerMap():HASKEY(nxt) {
        mLog("Parking checkpoint: " + nxt + " already loaded — continuing.").
        RETURN.
    }
    falconSaveReloadState("PARKING_ORBIT", nxt).
    mLog("Parking orbit reload point — auto-rebooting for " + nxt + ".").
    HUDTEXT("Parking orbit: rebooting for " + nxt + "...",
        5, 2, 15, CYAN, FALSE).
    WAIT 5.
    REBOOT.
}

GLOBAL FUNCTION falconBuildPhaseSequence {
    IF stateGet("mission_cfg_SEQUENCE", "") <> "" AND CFG:HASKEY("SEQUENCE") {
        RETURN phaseListFromString(CFG["SEQUENCE"]).
    }

    LOCAL targetFromState IS stateGet("target", "KERBIN").
    LOCAL payloadsFromState IS stateGet("payloads", "").
    LOCAL nameHasMission IS targetFromState <> "KERBIN"
        OR payloadsFromState <> "".
    IF NOT nameHasMission AND CFG:HASKEY("SEQUENCE") {
        RETURN phaseListFromString(CFG["SEQUENCE"]).
    }

    LOCAL payloadPhases IS LEXICON(
        "SCISAT", LIST("SCIENCE_OPS"),
        "SCANSAT", LIST("SCANSAT_OPS"),
        "RELAY", LIST("RELAY_OPS"),
        "CREW", LIST("RELAY_OPS"),
        "TOURIST", LIST("RELAY_OPS"),
        "PASSENGER", LIST("RELAY_OPS")
    ).

    LOCAL seq IS LIST("LAUNCH", "FAIR", "ANTS", "PARK").
    IF targetFromState <> "KERBIN" {
        seq:ADD("XING").
        seq:ADD("BPLANE").
        seq:ADD("COAST_1HALF").
        seq:ADD("REFINE_BPLANE").
        seq:ADD("COAST_2HALF").
        seq:ADD("CAPTURE").
        seq:ADD("SHAPE").
    }
    FOR ptype IN missionPayloadsFromState() {
        LOCAL t IS missionNormalizePayloadType(ptype).
        IF payloadPhases:HASKEY(t) {
            FOR phaseName IN payloadPhases[t] { seq:ADD(phaseName). }
        }
    }
    seq:ADD("DONE").
    RETURN seq.
}

GLOBAL FUNCTION falconBuildPhaseMap {
    LOCAL phaseMap IS phaseHandlerMap().
    phaseMapSet(phaseMap, "PARK", _falconPhaseParkingReload@).
    RETURN phaseMap.
}

LOCAL FUNCTION _falconLibsForBand {
    PARAMETER band.
    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots, missionTypeConditionalRoots(band)).
    missionAppendUnique(roots, missionExtraLibs()).
    RETURN bootLibResolve(roots).
}

LOCAL FUNCTION _falconLibs {
    bootEnsureInitialPhase(falconBuildPhaseSequence()).
    LOCAL band IS falconPhaseBand().
    LOCAL phase IS stateGet("phase", "").
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").
    LOCAL libs IS _falconLibsForBand(band).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN _falconLibs().
}

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "Falcon",
    "keepCmds", LIST("DUMP", "SETPHASE")
).

GLOBAL FUNCTION main {
    LOCAL seq IS falconBuildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FALCON MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    bootEnsureInitialPhase(seq).

    IF falconPhaseBand() = "LAUNCH" {
        IF NOT confirmLaunch(_falconPrintConfig@) { RETURN. }
    }

    runPhases(falconBuildPhaseMap()).
}
