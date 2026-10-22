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
    // The surface-ascent leg reboots into RETURN_SETUP after PARK, possibly
    // out of radio view. Cache its small provider during the connected ascent
    // boot, and include it in cleanup's keep set. Other ascent missions pay
    // no storage/runtime cost for this future transition.
    IF bandKey = "LAUNCH" AND SEQUENCE:CONTAINS("RETURN_SETUP") {
        roots:ADD("return_setup").
    }
    IF SEQUENCE:CONTAINS("HOP_REVIEW") AND (bandKey = "HOP" OR bandKey = "LANDING") {
        // Keep both halves through cleanup: a ballistic hop can lose radio
        // between launch and landing, and review/next launch must work offline.
        FOR ln IN LIST("hop","landing_main","landing_coast","landing_brake") { roots:ADD(ln). }
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
