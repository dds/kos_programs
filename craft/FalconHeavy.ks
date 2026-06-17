// ============================================================
// FalconHeavy.ks  —  Falcon Heavy vehicle flight computer
// (0:/craft/FalconHeavy.ks)
//
// Falcon plumbing with extra solid boosters for heavier moon payloads.
// ============================================================

SET LAUNCH_SOLID_STAGE_FRAC TO 0.01.

GLOBAL BOOT_ARCHIVE_ONLY IS LIST(
    "xfer_plan",
    "maneuver_transfer",
    "maneuver_targeting"
).

applyKnownMissionState().

GLOBAL FUNCTION fhBuildPhaseSequence {
    IF SEQUENCE:LENGTH > 0 {
        RETURN phaseList(SEQUENCE).
    }

    LOCAL payloadPhases IS LEXICON(
        "SCISAT", LIST("SCIENCE_OPS"),
        "SCANSAT", LIST("SCANSAT_OPS"),
        "RELAY", LIST("RELAY_OPS"),
        "CREW", LIST("RELAY_OPS"),
        "TOURIST", LIST("RELAY_OPS"),
        "PASSENGER", LIST("RELAY_OPS")
    ).

    LOCAL seq IS LIST("PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK").
    IF getTarget() <> "KERBIN" {
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
    RETURN phaseSequenceEnsurePrelaunch(seq).
}

GLOBAL FUNCTION fhBuildPhaseMap {
    LOCAL phaseMap IS LEXICON().
    phaseMapSet(phaseMap, "PARK", phaseParkingReload@).
    RETURN phaseMap.
}

LOCAL FUNCTION _fhLibsForBand {
    PARAMETER band.
    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots, missionTypeConditionalRoots(band)).
    LOCAL extras IS missionExtraLibs().
    IF band <> "LAUNCH" {
        LOCAL filtered IS LIST().
        FOR libName IN extras {
            IF libName = "launch" {
                mLog("FalconHeavy extra lib launch skipped outside LAUNCH band.").
            } ELSE {
                filtered:ADD(libName).
            }
        }
        SET extras TO filtered.
    }
    missionAppendUnique(roots, extras).
    RETURN bootLibResolve(roots).
}

LOCAL FUNCTION _fhLibs {
    bootEnsureInitialPhase(fhBuildPhaseSequence()).
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
    LOCAL libs IS _fhLibsForBand(band).
    stateSet("lib_band_libs", libs).
    RETURN libs.
}

GLOBAL FUNCTION bootVehicleLibs {
    RETURN _fhLibs().
}

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FalconHeavy"
).

GLOBAL FUNCTION main {
    rocketMain(fhBuildPhaseSequence@, fhBuildPhaseMap@).
}
