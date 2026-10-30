// ============================================================
// mission_type.ks — mission type detection and conditional roots
// (0:/lib/mission_type.ks)
//
// Shared logic for detecting mission type from state and
// returning conditional library roots per band. Used by craft
// scripts to avoid hardcoding body-name checks and payload
// logic in each vehicle.
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL MISSION_TYPE IS "".
GLOBAL TARGET_ IS "".
GLOBAL RENDEZVOUS_TARGET IS "".
GLOBAL ASTEROID_TARGET IS "".
// Opt-in disk-only prefetch of the next two distinct phase bands.
GLOBAL MISSION_CACHE_NEXT_BAND IS 0.
// Initial phase bands of a profile rewrite, retained before that boot.
GLOBAL MISSION_CACHE_HANDOFF_PHASES IS LIST().
// Optional ordered native-assist route and its terminal mission continuation.
GLOBAL MISSION_ASSIST_ROUTE IS LIST().
GLOBAL MISSION_ASSIST_SEQUENCE IS LIST().
GLOBAL MISSION_ASSIST_SETTINGS IS LEXICON().
GLOBAL MISSION_ASSIST_SCIENCE IS 0.
// Loader decisions happen before optional landing libraries execute.
GLOBAL LANDING_AUTO_TARGET IS 0.
GLOBAL LANDING_REQUIRE_SITE IS 0.
GLOBAL LANDING_SITE_SCAN_ENABLE IS 0.

// Detect mission type from effective globals plus runtime state.
// Returns "kerbin_moon", "kerbin_return", or "interplanetary".
GLOBAL FUNCTION missionTypeDetect {
    LOCAL explicit IS MISSION_TYPE.
    IF explicit <> "" { RETURN explicit. }
    LOCAL target IS getTarget().
    IF target = "MUN" OR target = "MINMUS" { RETURN "kerbin_moon". }
    IF target = "KERBIN" { RETURN "kerbin_return". }
    RETURN "interplanetary".
}

// Return extra library roots needed for a given band key,
// based on mission type, sequence, and payload state.
// These are additive on top of the band roots from dependencies.ks.
GLOBAL FUNCTION missionTypeConditionalRoots {
    PARAMETER bandKey.
    LOCAL roots IS LIST().
    IF bandKey = "ASSIST_COAST" AND MISSION_ASSIST_SCIENCE > 0 { roots:ADD("science_entry"). }
    IF bandKey = "LAND_DEORBIT" {
        IF LANDING_AUTO_TARGET > 0 { roots:ADD("landing_light_wait"). }
        IF LANDING_SITE_SCAN_ENABLE > 0 OR LANDING_REQUIRE_SITE > 0 { roots:ADD("landing_site"). }
    }
    IF bandKey = "LANDING" {
        // Both dynamic tracks must survive connected cleanup and an offline
        // reboot; descent must never compile/fetch its next braking state.
        roots:ADD("landing_coast").
        roots:ADD("landing_brake").
        // Small landed science provider survives touchdown with no archive
        // link. Other landing missions do not pay for this optional phase.
        IF SEQUENCE:CONTAINS("SURFACE_SCIENCE") { roots:ADD("science_surface"). }
        IF SEQUENCE:CONTAINS("SURFACE_RETURN_SETUP")
                AND NOT SEQUENCE:CONTAINS("HOP_ROUTE_SETUP")
                AND NOT SEQUENCE:CONTAINS("HOP_AUTO_REVIEW") { roots:ADD("return_setup"). }
    }
    // The surface-ascent leg reboots into RETURN_SETUP after PARK, possibly
    // out of radio view. Keep its small provider through prelaunch, ascent
    // optional post-ascent shaping and orbital review. Surface science
    // review before relaunch needs the same provider. Other missions do not.
    IF ((bandKey = "PRELAUNCH" OR bandKey = "LAUNCH" OR bandKey = "SHAPE" OR bandKey = "PAYLOAD_OPS")
            AND SEQUENCE:CONTAINS("RETURN_SETUP"))
            OR (bandKey = "PAYLOAD_OPS" AND SEQUENCE:CONTAINS("SURFACE_RETURN_SETUP")) {
        roots:ADD("return_setup").
    }
    IF bandKey = "XFER_PLAN" {
        LOCAL mType IS missionTypeDetect().
        LOCAL seq IS "".
        SET seq TO SEQUENCE.
        IF mType = "interplanetary" AND seq:CONTAINS("XING") {
            roots:ADD("maneuver_intersystem").
        }
        LOCAL needsRdv IS FALSE.
        IF RENDEZVOUS_TARGET <> "" { SET needsRdv TO TRUE. }
        IF ASTEROID_TARGET <> "" { SET needsRdv TO TRUE. }
        IF needsRdv {
            roots:ADD("maneuver_rendezvous").
        }
    }
    IF bandKey = "PAYLOAD_OPS" {
        LOCAL seq IS "".
        SET seq TO SEQUENCE.
        IF seq:CONTAINS("TARGETED_DEORBIT") {
            roots:ADD("deorbit_targeting").
        }
        IF missionHasPayload("SCANSAT") OR missionHasPayload("SCISAT") {
            roots:ADD("science").
        }
    }
    RETURN roots.
}

// Next-band files are cached without executing them in the current program.
// Retain two distinct bands so coast/refine loops do not hide capture, plus
// an explicit profile-rewrite handoff. Boot reserves progress/log space; failure is
// diagnostic, never a new blackout/deorbit admission gate.
GLOBAL FUNCTION missionTypeCacheRoots {
    PARAMETER bandKey.
    PARAMETER currentPhase IS "".
    LOCAL roots IS LIST().
    IF currentPhase <> "" {
        IF MISSION_CACHE_NEXT_BAND > 0 {
            LOCAL seen IS FALSE.
            LOCAL futureBands IS LIST().
            FOR phaseName IN SEQUENCE {
                IF seen {
                    LOCAL nextBand IS bootLibBandForPhase(phaseName,phaseName).
                    IF nextBand <> bandKey AND NOT futureBands:CONTAINS(nextBand) {
                        missionAppendUnique(roots,bootLibBandRoots(nextBand)).
                        missionAppendUnique(roots,missionTypeConditionalRoots(nextBand)).
                        futureBands:ADD(nextBand).
                        IF futureBands:LENGTH >= 2 { BREAK. }
                    }
                }
                IF phaseName = currentPhase { SET seen TO TRUE. }
            }
            FOR handoffPhase IN MISSION_CACHE_HANDOFF_PHASES {
                LOCAL handoffBand IS bootLibBandForPhase(handoffPhase,handoffPhase).
                missionAppendUnique(roots,bootLibBandRoots(handoffBand)).
                missionAppendUnique(roots,missionTypeConditionalRoots(handoffBand)).
            }
            LOCAL assistAhead IS FALSE.
            FOR phaseName IN SEQUENCE {
                IF phaseName = currentPhase { SET assistAhead TO TRUE. }
                IF phaseName = "ASSIST_COAST" { BREAK. }
            }
            IF assistAhead AND MISSION_ASSIST_ROUTE:LENGTH > 0 {
                LOCAL afterAssist IS FALSE.
                FOR fallbackPhase IN SEQUENCE {
                    IF afterAssist {
                        LOCAL fallbackBand IS bootLibBandForPhase(fallbackPhase,fallbackPhase).
                        missionAppendUnique(roots,bootLibBandRoots(fallbackBand)).
                        missionAppendUnique(roots,missionTypeConditionalRoots(fallbackBand)).
                        BREAK.
                    }
                    IF fallbackPhase = "ASSIST_COAST" { SET afterAssist TO TRUE. }
                }
                // Either branch can be taken offline: keep the terminal
                // capture/science provider before committing to an assist.
                FOR terminalPhase IN MISSION_ASSIST_SEQUENCE {
                    IF terminalPhase = "CAPTURE" OR terminalPhase = "SCIENCE_ENTRY" {
                        LOCAL terminalBand IS bootLibBandForPhase(terminalPhase,terminalPhase).
                        missionAppendUnique(roots,bootLibBandRoots(terminalBand)).
                        missionAppendUnique(roots,missionTypeConditionalRoots(terminalBand)).
                        BREAK.
                    }
                }
            }
        }
    }
    // Disk-only entry code prefetch before Duna/SOI handoff. No executing
    // a second band here and no mandatory new blackout/cache admission gate.
    IF SEQUENCE:CONTAINS("SCIENCE_ENTRY")
            AND (bandKey = "XFER_BPLANE" OR bandKey = "XFER_ARRIVE") {
        roots:ADD("science_entry").
    }
    LOCAL automatic IS SEQUENCE:CONTAINS("HOP_ROUTE_SETUP") OR SEQUENCE:CONTAINS("HOP_AUTO_REVIEW").
    LOCAL manualRoute IS SEQUENCE:CONTAINS("HOP_REVIEW").
    IF NOT automatic AND NOT manualRoute { RETURN roots. }
    IF bandKey = "HOP_ROUTE" {
        RETURN LIST("hop_control","return_setup").
    }
    IF bandKey = "HOP" {
        RETURN LIST("landing_main","landing_coast","landing_brake").
    }
    IF bandKey = "LANDING" {
        IF automatic { RETURN LIST("hop_route"). }
        RETURN LIST("hop").
    }
    RETURN roots.
}
