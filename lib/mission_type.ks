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
    IF bandKey = "LANDING" {
        // Both dynamic tracks must survive connected cleanup and an offline
        // reboot; descent must never compile/fetch its next braking state.
        roots:ADD("landing_coast").
        roots:ADD("landing_brake").
        IF SEQUENCE:CONTAINS("SURFACE_RETURN_SETUP")
                AND NOT SEQUENCE:CONTAINS("HOP_ROUTE_SETUP")
                AND NOT SEQUENCE:CONTAINS("HOP_AUTO_REVIEW") { roots:ADD("return_setup"). }
    }
    // The surface-ascent leg reboots into RETURN_SETUP after PARK, possibly
    // out of radio view. Keep its small provider through prelaunch, ascent
    // and optional post-ascent shaping. Other missions pay no extra cost.
    IF (bandKey = "PRELAUNCH" OR bandKey = "LAUNCH" OR bandKey = "SHAPE")
            AND SEQUENCE:CONTAINS("RETURN_SETUP") {
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
// Retain one transition, rather than every flight/science/return provider at
// once. Boot's cache sync reserves space for progress and logs; failure is
// diagnostic, never a new blackout/deorbit admission gate.
GLOBAL FUNCTION missionTypeCacheRoots {
    PARAMETER bandKey.
    LOCAL roots IS LIST().
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
