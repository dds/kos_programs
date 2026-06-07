// ============================================================
// FR3.ks  —  FR3 vehicle flight computer  (0:/craft/FR3.ks)
//
// Ship name:  FR3-TARGET-TYPE1-TYPE2-...-NN
// Payload tokens: RELAY, SCANSAT, SCISAT, LANDER, ASSISTLANDER,
//                 ROVER, ASSISTROVER, PROBE, CRASHPROBE
// ============================================================

GLOBAL CFG IS LEXICON(
    "PARKING_ALT",          80000,
    "LAUNCH_INCLINATION",       0,
    "LAUNCH_AZIMUTH",           0,
    "LAUNCH_STAGE_LIMIT",       0,
    "FAIRING_ALT",          71500,
    "EXTEND_ALT",           73000,
    "CAPTURE_PE",            15000,
    "CAPTURE_INC",              90,
    "CAPTURE_DIR",          "POLAR",
    "TARGET_PE",             15000,
    "CIRC_ECC_TOL",          0.005,
    "TARGET_INCLINATION",      90,
    "TARGET_AP",             20000,
    "INCL_MATCH_TARGET",       "",
    "INCL_TOLERANCE",         0.01,
    "MAX_INCL_CHANGE_DV",     200,
    "PROBE_TARGET_LAT",       50,
    "PROBE_TARGET_LNG",        30, 
    "PROBE_ENTRY_PE",         5000,
    "PROBE_TARGET_TOL",        2500,
    "SCANSAT_DECOUPLER_TAG", "scansat_decoupler"
).

// --- Example: rendezvous + Duna rover lander ---
// Ship name: FR3-DUNA-LANDER-01
// Mission: launch to LKO, rendezvous with Jeb's wreck in Kerbin
// orbit (e.g. to pick up crew or recover parts), then transfer
// to Duna and land a rover probe.
//
// CFG overrides:
//   SET CFG["PARKING_ALT"]       TO 100000.
//   SET CFG["CAPTURE_PE"]        TO 30000.
//   SET CFG["CAPTURE_DIR"]       TO "POLAR".
//   SET CFG["TARGET_PE"]         TO 30000.
//   SET CFG["TARGET_AP"]         TO 30000.
//   SET CFG["TARGET_INCLINATION"] TO 90.
//   SET CFG["RENDEZVOUS_TARGET"] TO "Jeb's Wreck".
//
// Sequence: LUNCH → FAIR → ANTS → PARK → RDV → XING → MCC →
//           COAST → CAPTURE → CIRC → RAISE → INCLINE →
//           LAND_DEORBIT → LAND → DONE
//
// The RDV phase runs planRendezvous() + executeManeuver() when
// RENDEZVOUS_TARGET or ASTEROID_TARGET is configured.

LOCAL FUNCTION _bootPayloads {
    LOCAL raw IS stateGet("payloads", "").
    IF raw = "" { RETURN LIST(). }
    RETURN raw:SPLIT(",").
}

LOCAL FUNCTION _bootHasPayload {
    PARAMETER payloadName.
    LOCAL targetName IS payloadName:TOUPPER.
    FOR raw IN _bootPayloads() {
        LOCAL result IS raw:TOUPPER.
        UNTIL result:LENGTH = 0 {
            LOCAL last IS result:SUBSTRING(result:LENGTH - 1, 1).
            IF last:MATCHESPATTERN("[0-9]") OR last = "-" {
                SET result TO result:SUBSTRING(0, result:LENGTH - 1).
            } ELSE {
                BREAK.
            }
        }
        IF result = targetName { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _fr3Libs {
    LOCAL libs IS LIST(
        "phases", "launch", "xfer",
        "lib_navigation", "countdown", "maneuver", "inclination",
        "orbit", "targeting", "landing",
        "utils"
    ).

    IF _bootHasPayload("PROBE") OR _bootHasPayload("CRASHPROBE")
            OR _bootHasPayload("RELAY") OR _bootHasPayload("SCANSAT")
            OR _bootHasPayload("SCISAT") {
        libs:ADD("payload_ops").
    } ELSE {
        libs:ADD("payload_landing").
    }
    IF stateGet("target", "KERBIN"):TOUPPER <> "MUN" {
        libs:ADD("lambert").
        libs:ADD("maneuver_intersystem").
    }
    IF CFG:HASKEY("RENDEZVOUS_TARGET") OR CFG:HASKEY("ASTEROID_TARGET") {
        IF NOT libs:CONTAINS("lambert") { libs:ADD("lambert"). }
        libs:ADD("maneuver_rendezvous").
    }
    IF _bootHasPayload("SCANSAT") OR _bootHasPayload("SCISAT") {
        libs:ADD("science").
    }
    RETURN libs.
}

GLOBAL LIBS IS _fr3Libs().

LOCAL FUNCTION _hasLandingPayload {
    FOR ptype IN missionPayloads() {
        LOCAL t IS normalizePayloadType(ptype).
        IF t = "LANDER" OR t = "ASSISTLANDER"
                OR t = "ROVER" OR t = "ASSISTROVER" {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _hasPayload {
    PARAMETER payloadName.
    FOR ptype IN missionPayloads() {
        IF normalizePayloadType(ptype) = payloadName:TOUPPER { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _applyMissionProfile {
    IF MISSION["target"]:TOUPPER = "MUN" AND _hasLandingPayload() {
        SET LANDING_CFG["DEORBIT_PE"] TO 5000.
        SET LANDING_CFG["TARGET_TOLERANCE"] TO 2500.
        SET LANDING_CFG["GUIDANCE_ALT"] TO 5000.

        IF _hasPayload("ASSISTROVER") OR _hasPayload("ASSISTLANDER") {
            SET LANDING_CFG["ASSIST_RELEASE_ALT"] TO 100.
            SET LANDING_CFG["ASSIST_RELEASE_HSPEED"] TO 0.5.
            SET LANDING_CFG["ASSIST_RELEASE_VSPEED"] TO 0.
        }
    }

    IF MISSION["target"]:TOUPPER = "MUN"
            AND _hasPayload("SCANSAT")
            AND _hasLandingPayload() {
        // Mun mapper + rover stack: deploy mapper in a useful polar orbit,
        // then spend the remaining vehicle on targeted rover landing.
        SET CFG["CAPTURE_PE"] TO 20000.
        SET CFG["CAPTURE_INC"] TO 90.
        SET CFG["TARGET_PE"] TO 250000.
        SET CFG["TARGET_AP"] TO 250000.
        SET CFG["TARGET_INCLINATION"] TO 90.
        SET CFG["MAX_INCL_CHANGE_DV"] TO 300.

    }
}

LOCAL FUNCTION buildPhaseSequence {
    // Orbit phases prepare the shared carrier in the orbit required by the
    // first payload. For mapper-rover Mun missions, _applyMissionProfile()
    // changes this to a 250 km polar SCANsat orbit before landing begins.
    LOCAL orbitPhases IS LIST("CIRC", "RAISE", "INCLINE").

    LOCAL payloadPhases IS LEXICON(
        "CRASHPROBE", LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "PROBE",      LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "RELAY",      LIST("RELAY_OPS"),
        "SCANSAT",    LIST("SCANSAT_OPS"),
        "SCISAT",     LIST("RELAY_OPS"),
        "ASSISTLANDER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND"),
        "LANDER",     LIST("LAND_DEORBIT", "LAND"),
        "ASSISTROVER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND"),
        "ROVER",      LIST("LAND_DEORBIT", "LAND")
    ).

    RETURN buildRocketSequence(orbitPhases, payloadPhases).
}

LOCAL FUNCTION _buildPhaseMap {
    LOCAL phaseMap IS LEXICON(
        "LUNCH", phaseLaunch@,
        "FAIR", phaseFairing@,
        "ANTS",             phaseExtendAnts@,
        "PARK",          phaseParking@,
        "RDV",              phaseRendezvous@,
        "XING",         phaseTransfer@,
        "COAST",            phaseCoast@,
        "CAPTURE",          phaseCapture@,
        "CIRC",             phaseCirc@,
        "RAISE",        phaseRaiseAlt@,
        "INCLINE",     phaseInclCorrect@,
        "MCC", phaseMidCourse@
    ).

    IF _hasPayload("PROBE") OR _hasPayload("CRASHPROBE") {
        phaseMap:ADD("TARGETED_DEORBIT", phaseTargetedDeorbit@).
        phaseMap:ADD("RELEASE_PROBE", phaseReleaseProbe@).
    }
    IF _hasPayload("RELAY") OR _hasPayload("SCISAT") {
        phaseMap:ADD("RELAY_OPS", phaseRelayOps@).
    }
    IF _hasPayload("SCANSAT") {
        phaseMap:ADD("SCANSAT_OPS", phaseScanSatOps@).
    }
    IF _hasLandingPayload() {
        phaseMap:ADD("LAND_DEORBIT", phaseLandDeorbit@).
        phaseMap:ADD("LAND_ASSIST", phaseLandAssist@).
        phaseMap:ADD("LAND", phaseLand@).
    }

    RETURN phaseMap.
}

LOCAL FUNCTION _printConfig {
    LOCAL seq IS buildPhaseSequence().
    LOCAL hasScanSat IS _hasPayload("SCANSAT").
    LOCAL hasLander IS _hasLandingPayload().

    PRINT "  ========================================".
    PRINT "    FR3 FLIGHT PLAN    " + SHIP:NAME.
    PRINT "  ========================================".
    PRINT " ".
    PRINT "  TARGET ..... " + MISSION["target"].
    PRINT "  PAYLOADS ... " + MISSION["payloads"].
    PRINT " ".
    PRINT "  -- ASCENT --".
    PRINT "  PARK ALT ... " + ROUND(CFG["PARKING_ALT"]/1000,0) + " km".
    LOCAL incStr IS CFG["LAUNCH_INCLINATION"] + " deg".
    IF CFG["LAUNCH_INCLINATION"] = 0 { SET incStr TO "0 deg  (equatorial)". }
    PRINT "  INCL ...... " + incStr.
    PRINT "  FAIRING ... " + ROUND(CFG["FAIRING_ALT"]/1000,0) + " km".
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        PRINT " ".
        PRINT "  -- TRANSFER --".
        PRINT "  CAPTURE PE . " + ROUND(CFG["CAPTURE_PE"]/1000,0) + " km".
        IF CFG:HASKEY("CAPTURE_INC") {
            PRINT "  CAPTURE INC  " + ROUND(CFG["CAPTURE_INC"],1) + " deg".
        }
        IF CFG:HASKEY("CAPTURE_LAN") {
            PRINT "  CAPTURE LAN  " + ROUND(CFG["CAPTURE_LAN"],1) + " deg".
        }
        IF CFG:HASKEY("CAPTURE_AOP") {
            PRINT "  CAPTURE AoP  " + ROUND(CFG["CAPTURE_AOP"],1) + " deg".
        }
    }
    PRINT " ".
    PRINT "  -- ORBIT --".
    PRINT "  FINAL ALT .. " + ROUND(CFG["TARGET_AP"]/1000,0) + " km".
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    PRINT "  FINAL INCL . " + tincStr.
    PRINT "  CIRC TOL ... ecc < " + CFG["CIRC_ECC_TOL"].
    IF hasScanSat {
        PRINT " ".
        PRINT "  -- SCANSAT --".
        PRINT "  DEPLOY TAG . " + CFG["SCANSAT_DECOUPLER_TAG"].
    }
    IF hasLander {
        PRINT " ".
        PRINT "  -- LANDING --".
        LOCAL targetText IS "map-selected waypoint".
        IF LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0 {
            SET targetText TO ROUND(LANDING_CFG["TARGET_LAT"],4)
                + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng".
        } ELSE IF LANDING_CFG["TARGET_WAYPOINT"] <> "" {
            SET targetText TO "waypoint " + LANDING_CFG["TARGET_WAYPOINT"].
        }
        PRINT "  TARGET ..... " + targetText.
        PRINT "  DEORBIT PE . " + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + " km".
        PRINT "  TOLERANCE .. " + ROUND(LANDING_CFG["TARGET_TOLERANCE"]/1000,1) + " km".
    }
    PRINT " ".
    PRINT "  -- SEQUENCE --".
    printSequence(seq).
    PRINT " ".
    PRINT "  ========================================".
}

GLOBAL FUNCTION main {
    _applyMissionProfile().
    LOCAL seq IS buildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR3 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    confirmLaunch(_printConfig@).

    runPhases(_buildPhaseMap()).
}
