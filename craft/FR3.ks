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

LOCAL FR3_MISSION_DIR IS "1:/missions/FR3".

LOCAL FUNCTION _missionConfigIds {
    LOCAL ids IS LIST().
    IF NOT EXISTS(FR3_MISSION_DIR) { RETURN ids. }

    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(FR3_MISSION_DIR).
    LIST FILES IN items.
    CD(startPath).

    FOR item IN items {
        IF item:ISFILE {
            LOCAL nm IS item:NAME.
            LOCAL upper IS nm:TOUPPER.
            IF upper:CONTAINS(".CFG") {
                ids:ADD(nm:SUBSTRING(0, nm:LENGTH - 4)).
            }
        }
    }
    RETURN ids.
}

LOCAL FUNCTION _selectMissionId {
    LOCAL configured IS stateGet("mission_id", "").
    IF configured <> "" { RETURN configured. }

    LOCAL ids IS _missionConfigIds().
    IF ids:LENGTH = 0 { RETURN "". }
    IF ids:LENGTH = 1 { RETURN ids[0]. }

    PRINT " ".
    PRINT "  FR3 MISSION SELECT".
    PRINT "  ------------------".
    LOCAL maxShown IS MIN(ids:LENGTH, 9).
    FROM { LOCAL i IS 0. } UNTIL i >= maxShown STEP { SET i TO i + 1. } DO {
        PRINT "  " + (i + 1) + ") " + ids[i].
    }
    PRINT " ".
    PRINT "  Press 1-" + maxShown + " to choose, or ENTER for " + ids[0] + ".".

    LOCAL choice IS 0.
    LOCAL picked IS FALSE.
    UNTIL picked {
        WAIT UNTIL TERMINAL:INPUT:HASCHAR.
        LOCAL ch IS TERMINAL:INPUT:GETCHAR().
        IF ch = CHAR(13) OR ch = CHAR(10) {
            SET picked TO TRUE.
        } ELSE {
            FROM { LOCAL i IS 0. } UNTIL i >= maxShown STEP { SET i TO i + 1. } DO {
                IF ch = "" + (i + 1) {
                    SET choice TO i.
                    SET picked TO TRUE.
                }
            }
        }
    }
    RETURN ids[choice].
}

LOCAL FUNCTION _setCfgNum {
    PARAMETER key.
    PARAMETER rawValue.
    IF CFG:HASKEY(key) { CFG:REMOVE(key). }
    CFG:ADD(key, rawValue:TONUMBER(0)).
}

LOCAL FUNCTION _setCfgString {
    PARAMETER key.
    PARAMETER rawValue.
    IF CFG:HASKEY(key) { CFG:REMOVE(key). }
    CFG:ADD(key, rawValue).
}

LOCAL FUNCTION _applyMissionSetting {
    PARAMETER key.
    PARAMETER value.

    IF key = "MISSION_ID" {
        stateSet("mission_id", value).
    } ELSE IF key = "MISSION_NAME" {
        stateSet("mission_name", value).
    } ELSE IF key = "TARGET" {
        stateSet("target", value:TOUPPER).
    } ELSE IF key = "PAYLOADS" {
        stateSet("payloads", value:TOUPPER).
    } ELSE IF key = "SEQUENCE" {
        _setCfgString("SEQUENCE", value:TOUPPER).

    } ELSE IF key = "CAPTURE_DIR" OR key = "RENDEZVOUS_TARGET"
            OR key = "ASTEROID_TARGET" OR key = "INCL_MATCH_TARGET"
            OR key = "SCANSAT_DECOUPLER_TAG"
            OR key = "PROBE_TARGET_WAYPOINT"
            OR key = "LANDING_TARGET_WAYPOINT" {
        _setCfgString(key, value).

    } ELSE IF key = "PARKING_ALT" OR key = "LAUNCH_INCLINATION"
            OR key = "LAUNCH_AZIMUTH" OR key = "LAUNCH_STAGE_LIMIT"
            OR key = "FAIRING_ALT" OR key = "EXTEND_ALT"
            OR key = "CAPTURE_PE" OR key = "CAPTURE_INC"
            OR key = "CAPTURE_LAN" OR key = "CAPTURE_AOP"
            OR key = "TARGET_PE" OR key = "TARGET_AP"
            OR key = "TARGET_INCLINATION" OR key = "CIRC_ECC_TOL"
            OR key = "INCL_TOLERANCE" OR key = "MAX_INCL_CHANGE_DV"
            OR key = "PROBE_TARGET_LAT" OR key = "PROBE_TARGET_LNG"
            OR key = "PROBE_ENTRY_PE" OR key = "PROBE_TARGET_TOL"
            OR key = "TARGET_DEORBIT_SCAN_ORBITS"
            OR key = "TARGET_DEORBIT_SCAN_SAMPLES"
            OR key = "ASTEROID_MAX_DEPART_ORBITS"
            OR key = "ASTEROID_DEPART_SAMPLES"
            OR key = "ASTEROID_TOF_SAMPLES"
            OR key = "ASTEROID_MIN_TOF"
            OR key = "ASTEROID_MAX_TOF"
            OR key = "ASTEROID_ARRIVAL_WEIGHT"
            OR key = "ASTEROID_REFINE_ITERS"
            OR key = "LANDING_TARGET_LAT"
            OR key = "LANDING_TARGET_LNG"
            OR key = "LANDING_DEORBIT_PE"
            OR key = "LANDING_TARGET_TOLERANCE"
            OR key = "LANDING_GUIDANCE_ALT"
            OR key = "LANDING_ASSIST_RELEASE_ALT"
            OR key = "LANDING_ASSIST_RELEASE_HSPEED"
            OR key = "LANDING_ASSIST_RELEASE_VSPEED" {
        _setCfgNum(key, value).
    }
}

LOCAL FUNCTION _applyMissionConfig {
    PARAMETER missionId.
    IF missionId = "" { RETURN FALSE. }

    LOCAL path IS FR3_MISSION_DIR + "/" + missionId + ".cfg".
    IF NOT EXISTS(path) {
        PRINT "  Mission config not found: " + path.
        RETURN FALSE.
    }

    LOCAL raw IS OPEN(path):READALL:STRING.
    LOCAL lines IS raw:SPLIT(CHAR(10)).
    FOR lineRaw IN lines {
        LOCAL line IS lineRaw:REPLACE(CHAR(13), ""):TRIM.
        IF line <> "" {
            LOCAL skipLine IS FALSE.
            IF line:SUBSTRING(0, 1) = "#" { SET skipLine TO TRUE. }
            IF line:LENGTH >= 2 AND line:SUBSTRING(0, 2) = "//" { SET skipLine TO TRUE. }
            IF NOT skipLine {
                LOCAL parts IS line:SPLIT("=").
                IF parts:LENGTH >= 2 {
                    LOCAL key IS parts[0]:TRIM:TOUPPER.
                    LOCAL value IS parts[1]:TRIM.
                    _applyMissionSetting(key, value).
                }
            }
        }
    }

    IF stateGet("mission_id", "") = "" { stateSet("mission_id", missionId). }
    PRINT "  Mission: " + stateGet("mission_name", missionId).
    PRINT "  Target:  " + stateGet("target", "KERBIN").
    PRINT "  Payload: " + stateGet("payloads", "").
    RETURN TRUE.
}

LOCAL FUNCTION _bootMission {
    LOCAL targetFromName IS stateGet("target", "KERBIN"):TOUPPER.
    LOCAL payloadsFromName IS stateGet("payloads", "").
    LOCAL hasNameMission IS targetFromName <> "KERBIN" OR payloadsFromName <> "".
    LOCAL missionId IS stateGet("mission_id", "").

    IF missionId = "" AND NOT hasNameMission {
        SET missionId TO _selectMissionId().
    }
    IF missionId <> "" {
        IF _applyMissionConfig(missionId) {
            stateSet("mission_id", missionId).
        }
    }
}

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

_bootMission().

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

LOCAL FUNCTION _phaseListFromString {
    PARAMETER raw.
    LOCAL seq IS LIST().
    FOR phaseRaw IN raw:SPLIT(",") {
        LOCAL phaseName IS phaseRaw:TRIM:TOUPPER.
        IF phaseName <> "" { seq:ADD(phaseName). }
    }
    IF seq:LENGTH = 0 { seq:ADD("DONE"). }
    RETURN seq.
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

    IF CFG:HASKEY("LANDING_TARGET_LAT") {
        SET LANDING_CFG["TARGET_LAT"] TO CFG["LANDING_TARGET_LAT"].
    }
    IF CFG:HASKEY("LANDING_TARGET_LNG") {
        SET LANDING_CFG["TARGET_LNG"] TO CFG["LANDING_TARGET_LNG"].
    }
    IF CFG:HASKEY("LANDING_TARGET_WAYPOINT") {
        SET LANDING_CFG["TARGET_WAYPOINT"] TO CFG["LANDING_TARGET_WAYPOINT"].
    }
    IF CFG:HASKEY("LANDING_DEORBIT_PE") {
        SET LANDING_CFG["DEORBIT_PE"] TO CFG["LANDING_DEORBIT_PE"].
    }
    IF CFG:HASKEY("LANDING_TARGET_TOLERANCE") {
        SET LANDING_CFG["TARGET_TOLERANCE"] TO CFG["LANDING_TARGET_TOLERANCE"].
    }
    IF CFG:HASKEY("LANDING_GUIDANCE_ALT") {
        SET LANDING_CFG["GUIDANCE_ALT"] TO CFG["LANDING_GUIDANCE_ALT"].
    }
    IF CFG:HASKEY("LANDING_ASSIST_RELEASE_ALT") {
        SET LANDING_CFG["ASSIST_RELEASE_ALT"] TO CFG["LANDING_ASSIST_RELEASE_ALT"].
    }
    IF CFG:HASKEY("LANDING_ASSIST_RELEASE_HSPEED") {
        SET LANDING_CFG["ASSIST_RELEASE_HSPEED"] TO CFG["LANDING_ASSIST_RELEASE_HSPEED"].
    }
    IF CFG:HASKEY("LANDING_ASSIST_RELEASE_VSPEED") {
        SET LANDING_CFG["ASSIST_RELEASE_VSPEED"] TO CFG["LANDING_ASSIST_RELEASE_VSPEED"].
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
    IF CFG:HASKEY("SEQUENCE") {
        RETURN _phaseListFromString(CFG["SEQUENCE"]).
    }

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
    IF stateGet("mission_id", "") <> "" {
        PRINT "  MISSION .... " + stateGet("mission_name", stateGet("mission_id", "")).
        PRINT "  PROFILE .... " + stateGet("mission_id", "").
    }
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
