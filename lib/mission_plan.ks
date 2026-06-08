// ============================================================
// mission_plan.ks — mission sequence and library planning
// (0:/lib/mission_plan.ks)
//
// Boot loads this before craft/role scripts so they can derive
// LIBS from a selected mission profile without bloating boot_core.
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

GLOBAL FUNCTION missionLibs {
    PARAMETER fallbackLibs IS LIST().
    PARAMETER baseLibs IS LIST().
    LOCAL libs IS LIST().
    missionAppendUnique(libs, baseLibs).

    LOCAL configured IS missionListFromCsv(stateGet("mission_cfg_LIBS", "")).
    IF configured:LENGTH > 0 {
        missionAppendUnique(libs, configured).
    } ELSE {
        missionAppendUnique(libs, fallbackLibs).
    }

    missionAppendUnique(libs, missionListFromCsv(stateGet("mission_cfg_LIBS_EXTRA", ""))).
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
    LOCAL libs IS LIST().
    IF NOT libs:CONTAINS("phases") { libs:ADD("phases"). }
    FOR lib IN baseDeps {
        IF NOT libs:CONTAINS(lib) { libs:ADD(lib). }
    }
    FOR phase IN phases {
        FOR lib IN _missionPhaseDeps(phase) {
            IF NOT libs:CONTAINS(lib) { libs:ADD(lib). }
        }
    }
    RETURN libs.
}

LOCAL FUNCTION _missionPhaseDeps {
    PARAMETER phaseName.
    LOCAL p IS phaseName:TOUPPER.
    // Aircraft
    IF p = "PREFLIGHT" OR p = "FLIGHT" OR p = "POST_FLIGHT"
            OR p = "POSTFLIGHT" OR p = "SPLASHDOWN" OR p = "SURFACE_OPS"
        { RETURN LIST("flightplan", "plane", "observe"). }
    // Roles / surface ops
    IF p = "DESCEND" OR p = "LANDED" OR p = "EVA_SCIENCE"
        { RETURN LIST("science", "orbit"). }
    // Launch
    IF p = "LUNCH" OR p = "FAIR" OR p = "ANTS"
        { RETURN LIST("launch", "countdown", "flightplan"). }
    IF p = "PARK"
        { RETURN LIST("launch", "orbit"). }
    // Transfer departure
    IF p = "XING"
        { RETURN LIST("xfer_plan", "maneuver", "maneuver_targeting",
                       "lib_navigation", "inclination", "countdown"). }
    // Mid-course correction (uses maneuver.ks phaseMidCourse)
    IF p = "MCC"
        { RETURN LIST("maneuver", "maneuver_targeting", "countdown"). }
    // Coast + capture
    IF p = "COAST" OR p = "CAPTURE"
        { RETURN LIST("capture", "maneuver", "maneuver_targeting",
                       "countdown", "orbit"). }
    // Post-capture orbit adjustment
    IF p = "CIRC" OR p = "RAISE"
        { RETURN LIST("maneuver_orbit", "maneuver", "maneuver_targeting",
                       "inclination", "orbit"). }
    IF p = "INCLINE" OR p = "ELLIPTICAL"
        { RETURN LIST("maneuver_orbit", "maneuver", "maneuver_targeting",
                       "inclination", "orbit"). }
    // Deorbit / probes
    IF p = "TARGETED_DEORBIT" OR p = "RELEASE_PROBE"
        { RETURN LIST("payload_ops", "deorbit_targeting",
                       "maneuver", "countdown", "utils"). }
    IF p = "RELAY_OPS"
        { RETURN LIST("payload_ops", "orbit"). }
    IF p = "SCANSAT_OPS"
        { RETURN LIST("payload_ops", "orbit", "science", "utils"). }
    // Landing
    IF p = "LAND_DEORBIT"
        { RETURN LIST("payload_landing", "landing", "deorbit_targeting"). }
    IF p = "LAND" OR p = "LAND_ASSIST"
        { RETURN LIST("payload_landing", "landing", "deorbit_targeting"). }
    // Rover
    IF p = "ROVER" { RETURN LIST("rover"). }
    // Rendezvous
    IF p = "RDV"
        { RETURN LIST("xfer_plan", "maneuver", "maneuver_targeting",
                       "maneuver_rendezvous", "lambert",
                       "lib_navigation", "inclination"). }
    // Molniya
    IF p = "MOLNIYA"
        { RETURN LIST("molniya", "maneuver", "maneuver_targeting",
                       "inclination"). }
    IF p = "MOLNIYA_INSERT"
        { RETURN LIST("molniya", "maneuver", "maneuver_targeting",
                       "inclination"). }
    // ScanSat
    IF p = "SCANSAT_IMPACT_RELEASE" OR p = "PAYLOAD_IMPACT_RELEASE"
        { RETURN LIST("maneuver_orbit", "orbit", "maneuver", "maneuver_targeting",
                       "inclination", "countdown"). }
    RETURN LIST().
}
