// ============================================================
// mission_plan.ks — mission sequence, payload, and library planning
// (0:/lib/mission_plan.ks)
//
// Boot loads this before craft/role scripts so they can inspect
// payload state and derive LIBS without coupling that logic to craft scripts.
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
    LOCAL result IS payloadName:TOUPPER.
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
    LOCAL targetName IS payloadName:TOUPPER.
    FOR raw IN missionPayloadsFromState() {
        IF missionNormalizePayloadType(raw) = targetName { RETURN TRUE. }
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

    missionAppendUnique(libs, bootLibResolve(missionListFromCsv(stateGet("mission_cfg_LIBS_EXTRA", "")))).
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
