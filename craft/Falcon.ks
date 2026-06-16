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

SET DESCENT_DROGUE_CUT_ALT TO 4800.

GLOBAL BOOT_ARCHIVE_ONLY IS LIST(
    "xfer_plan",
    "maneuver_transfer",
    "maneuver_targeting"
).

applyKnownMissionState().

LOCAL FUNCTION _falconPrintConfig {
    LOCAL seq IS falconBuildPhaseSequence().
    flightPlanTitle("FALCON FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("MISSION").
    flightPlanRow("BAND", phaseBand()).
    flightPlanRow("TARGET", MISSION["target"]).
    flightPlanRow("PAYLOADS", MISSION["payloads"]).
    flightPlanConfig().
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
}

GLOBAL FUNCTION falconBuildPhaseSequence {
    IF SEQUENCE <> "" {
        RETURN phaseListFromString(SEQUENCE).
    }

    LOCAL targetFromState IS stateGet("target", "KERBIN").
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
    LOCAL phaseMap IS LEXICON().
    phaseMapSet(phaseMap, "PARK", phaseParkingReload@).
    RETURN phaseMap.
}

LOCAL FUNCTION _falconLibsForBand {
    PARAMETER band.
    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots, missionTypeConditionalRoots(band)).
    LOCAL extras IS missionExtraLibs().
    IF band <> "LAUNCH" {
        LOCAL filtered IS LIST().
        FOR libName IN extras {
            IF libName = "launch" {
                mLog("Falcon extra lib launch skipped outside LAUNCH band.").
            } ELSE {
                filtered:ADD(libName).
            }
        }
        SET extras TO filtered.
    }
    missionAppendUnique(roots, extras).
    RETURN bootLibResolve(roots).
}

LOCAL FUNCTION _falconLibs {
    bootEnsureInitialPhase(falconBuildPhaseSequence()).
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
    LOCAL libs IS _falconLibsForBand(band).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN _falconLibs().
}

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "Falcon"
).

GLOBAL FUNCTION main {
    LOCAL seq IS falconBuildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FALCON MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    bootEnsureInitialPhase(seq).

    IF phaseBand() = "LAUNCH" {
        IF NOT confirmLaunch(_falconPrintConfig@) { RETURN. }
    }

    runPhases(falconBuildPhaseMap()).
}
