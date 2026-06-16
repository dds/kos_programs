// ============================================================
// preflight_planner.ks - mission sequence and library planning
// (0:/lib/preflight_planner.ks)
//
// Loaded only by craft/role scripts that need sequence-to-library
// planning. Keep this out of universal boot_lib.ks; it is bulky.
// ============================================================

// LIBS_EXTRA entries may be phase-scoped with lib@PHASE: the lib
// loads only while the mission has NOT yet passed PHASE in the
// sequence. A suborbital hop carries suborbit@SUBORBIT and sheds
// it (and its whole dependency chain) on any reboot after the
// arc — flight-found: unscoped extras made a DESCENT-phase boot
// load the union of every band at once, 433 bytes free, compile
// failed. Unknown phases keep the lib (safe).
GLOBAL FUNCTION missionExtraLibs {
    LOCAL out IS LIST().
    LOCAL seq IS missionListFromCsv(stateGet("mission_cfg_SEQUENCE", "")).
    LOCAL cur IS stateGet("phase", "").
    FOR entryRaw IN missionListFromCsv(stateGet("mission_cfg_LIBS_EXTRA", "")) {
        IF entryRaw:CONTAINS("@") {
            LOCAL parts IS entryRaw:SPLIT("@").
            LOCAL libName IS parts[0]:TRIM.
            LOCAL untilPhase IS parts[1]:TRIM.
            LOCAL curIdx IS -1.
            LOCAL phIdx IS -1.
            LOCAL i IS 0.
            UNTIL i >= seq:LENGTH {
                IF seq[i] = cur { SET curIdx TO i. }
                IF seq[i] = untilPhase { SET phIdx TO i. }
                SET i TO i + 1.
            }
            IF curIdx >= 0 AND phIdx >= 0 AND curIdx > phIdx {
                mLog("Extra lib " + libName + " dropped (past "
                    + untilPhase + ").").
            } ELSE {
                out:ADD(libName).
            }
        } ELSE {
            out:ADD(entryRaw).
        }
    }
    RETURN out.
}

GLOBAL FUNCTION missionLibs {
    PARAMETER fallbackLibs IS LIST().
    PARAMETER baseLibs IS LIST().
    LOCAL libs IS LIST().
    missionAppendUnique(libs, baseLibs).

    LOCAL configured IS missionListFromCsv(stateGet("mission_cfg_LIBS", "")).
    IF configured:LENGTH > 0 {
        missionAppendUnique(libs, bootLibResolve(configured)).
    } ELSE {
        missionAppendUnique(libs, bootLibResolve(fallbackLibs)).
    }

    missionAppendUnique(libs, bootLibResolve(missionExtraLibs())).
    RETURN libs.
}

GLOBAL FUNCTION missionSequenceLibs {
    PARAMETER fallbackLibs IS LIST().
    PARAMETER baseDeps IS LIST().
    LOCAL sequenceLibs IS fallbackLibs.
    LOCAL sequence IS missionListFromCsv(stateGet("mission_cfg_SEQUENCE", "")).
    IF sequence:LENGTH > 0 {
        SET sequenceLibs TO missionLibsForPhases(sequence, baseDeps).
    }
    RETURN missionLibs(sequenceLibs).
}

// ============================================================
// Aircraft boot helpers — shared by all airplane craft scripts.
// These live here (preamble) because bootVehicleLibs() runs
// before the airplane library itself is loaded.
// ============================================================

GLOBAL FUNCTION airplaneSequenceFromState {
    PARAMETER defaultSeq.
    LOCAL raw IS stateGet("mission_cfg_SEQUENCE", "").
    IF raw <> "" { RETURN phaseListFromString(raw). }
    RETURN defaultSeq.
}

GLOBAL FUNCTION airplaneVehicleLibs {
    PARAMETER defaultSeq.
    PARAMETER baseLibs IS LIST("orbit", "airplane").
    LOCAL seq IS airplaneSequenceFromState(defaultSeq).
    LOCAL libs IS missionLibsForPhases(seq, baseLibs).
    IF missionHasPayload("SCIENCE") AND NOT libs:CONTAINS("science") {
        libs:ADD("science").
    }
    SET libs TO missionSequenceLibs(libs, baseLibs).
    stateSet("lib_band", "AIR").
    stateSet("lib_band_phase", stateGet("phase", seq[0])).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

// ============================================================
// missionLibsForPhases — compute libraries from phase sequence.
//
// Mission profiles own phase order. Craft scripts map phase names
// to hardware-specific implementations. This function is the bridge
// boot uses to load only the code needed for the selected sequence.
// ============================================================
GLOBAL FUNCTION missionLibsForPhases {
    PARAMETER phases.
    PARAMETER baseDeps IS LIST().
    LOCAL roots IS LIST("phases").
    FOR lib IN baseDeps {
        missionAppendUnique(roots, LIST(lib)).
    }
    FOR phase IN phases {
        missionAppendUnique(roots, bootLibPhaseRoots(phase)).
    }
    RETURN bootLibResolve(roots).
}
