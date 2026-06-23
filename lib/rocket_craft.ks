// ============================================================
// rocket_craft.ks — shared Falcon-family rocket flight-computer
// plumbing  (0:/lib/rocket_craft.ks)
//
// The Falcon-family craft scripts (FalconHeavy, FTSV, ...) each
// carried the same phase-sequence builder, phase map, and band-lib
// resolver. They now reduce to config + delegation:
//
//   bootLibLoad("rocket_craft").
//   GLOBAL BOOT_CLEANUP IS LEXICON("vehicle", "FTSV").
//   GLOBAL FUNCTION bootVehicleLibs { RETURN rocketVehicleLibs(). }
//   GLOBAL FUNCTION main { rocketMain(rocketBuildPhaseSequence@,
//                                     rocketBuildPhaseMap@). }
//
// rocketMain + phaseParkingReload live in phases.ks (the phase
// machine); this lib is loaded by the craft script itself (so only
// rocket craft pay for it), before boot calls bootVehicleLibs().
// ============================================================

// Default phase sequence when a mission profile doesn't supply one:
// launch to a parking orbit, the transfer/capture/shape chain for any
// non-Kerbin target, then payload-type ops, then DONE.
GLOBAL FUNCTION rocketBuildPhaseSequence {
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

GLOBAL FUNCTION rocketBuildPhaseMap {
    LOCAL phaseMap IS LEXICON().
    phaseMapSet(phaseMap, "PARK", phaseParkingReload@).
    RETURN phaseMap.
}

// Band lib roots + solar (every rocket carries it for coast charging)
// + mission-type conditional roots + mission LIBS_EXTRA (the `launch`
// extra is LAUNCH-band only).
GLOBAL FUNCTION rocketVehicleLibsForBand {
    PARAMETER band.
    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots, LIST("solar")).
    missionAppendUnique(roots, missionTypeConditionalRoots(band)).
    LOCAL extras IS missionExtraLibs().
    IF band <> "LAUNCH" {
        LOCAL filtered IS LIST().
        FOR libName IN extras {
            IF libName = "launch" {
                mLog("Extra lib 'launch' skipped outside LAUNCH band.").
            } ELSE {
                filtered:ADD(libName).
            }
        }
        SET extras TO filtered.
    }
    missionAppendUnique(roots, extras).
    RETURN bootLibResolve(roots).
}

GLOBAL FUNCTION rocketVehicleLibs {
    bootEnsureInitialPhase(rocketBuildPhaseSequence()).
    LOCAL band IS phaseBand().
    LOCAL phase IS stateGet("phase", "").
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").
    RETURN rocketVehicleLibsForBand(band).
}
