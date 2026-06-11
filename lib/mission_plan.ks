// ============================================================
// mission_plan.ks — mission sequence, payload, and library planning
// (0:/lib/mission_plan.ks)
//
// Boot loads this before craft/role scripts so they can inspect
// payload state and derive boot library roots without coupling that logic to craft scripts.
// ============================================================

GLOBAL FUNCTION missionListFromCsv {
    PARAMETER raw.
    LOCAL values IS LIST().
    IF raw = "" { RETURN values. }
    FOR itemRaw IN raw:SPLIT(",") {
        LOCAL item IS itemRaw:TRIM.
        IF item <> "" { values:ADD(item). }
    }
    RETURN values.
}

GLOBAL FUNCTION missionAppendUnique {
    PARAMETER dest.
    PARAMETER src.
    FOR itemRaw IN src {
        LOCAL item IS itemRaw:TRIM.
        IF item <> "" AND NOT dest:CONTAINS(item) {
            dest:ADD(item).
        }
    }
}

GLOBAL FUNCTION missionPayloadsFromState {
    LOCAL raw IS stateGet("payloads", "").
    IF raw = "" { RETURN LIST(). }
    RETURN raw:SPLIT(",").
}

GLOBAL FUNCTION missionNormalizePayloadType {
    PARAMETER payloadName.
    LOCAL result IS payloadName.
    UNTIL result:LENGTH = 0 {
        LOCAL last IS result:SUBSTRING(result:LENGTH - 1, 1).
        IF last:MATCHESPATTERN("[0-9]") OR last = "-" {
            SET result TO result:SUBSTRING(0, result:LENGTH - 1).
        } ELSE {
            BREAK.
        }
    }
    RETURN result.
}

GLOBAL FUNCTION missionHasPayload {
    PARAMETER payloadName.
    FOR raw IN missionPayloadsFromState() {
        IF missionNormalizePayloadType(raw) = payloadName { RETURN TRUE. }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION missionHasLandingPayload {
    FOR raw IN missionPayloadsFromState() {
        LOCAL payloadType IS missionNormalizePayloadType(raw).
        IF payloadType = "LANDER" OR payloadType = "ASSISTLANDER"
                OR payloadType = "ROVER" OR payloadType = "ASSISTROVER" {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

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
