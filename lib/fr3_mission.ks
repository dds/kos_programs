// ============================================================
// fr3_mission.ks - FR3 mission profile, sequence, and phase map
// ============================================================

LOCAL FUNCTION _fr3HasLandingPayload {
    FOR ptype IN missionPayloads() {
        LOCAL t IS normalizePayloadType(ptype).
        IF t = "LANDER" OR t = "ASSISTLANDER"
                OR t = "ROVER" OR t = "ASSISTROVER" {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _fr3HasPayload {
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

LOCAL FUNCTION _landingCfgMappings {
    RETURN LIST(
        LIST("LANDING_TARGET_LAT", "TARGET_LAT"),
        LIST("LANDING_TARGET_LNG", "TARGET_LNG"),
        LIST("LANDING_TARGET_WAYPOINT", "TARGET_WAYPOINT"),
        LIST("LANDING_DEORBIT_PE", "DEORBIT_PE"),
        LIST("LANDING_TARGET_TOLERANCE", "TARGET_TOLERANCE"),
        LIST("LANDING_GUIDANCE_ALT", "GUIDANCE_ALT"),
        LIST("LANDING_ASSIST_RELEASE_ALT", "ASSIST_RELEASE_ALT"),
        LIST("LANDING_ASSIST_RELEASE_HSPEED", "ASSIST_RELEASE_HSPEED"),
        LIST("LANDING_ASSIST_RELEASE_VSPEED", "ASSIST_RELEASE_VSPEED"),
        LIST("LANDING_ASSIST_RELEASE_ON_SURFACE", "ASSIST_RELEASE_ON_SURFACE"),
        LIST("LANDING_ASSIST_SURFACE_FINAL_SPEED", "ASSIST_SURFACE_FINAL_SPEED"),
        LIST("LANDING_ASSIST_SURFACE_SETTLE_TIME", "ASSIST_SURFACE_SETTLE_TIME"),
        LIST("LANDING_ASSIST_SURFACE_TIPOVER", "ASSIST_SURFACE_TIPOVER"),
        LIST("LANDING_ASSIST_SURFACE_TIP_TIME", "ASSIST_SURFACE_TIP_TIME")
    ).
}

LOCAL FUNCTION _copyLandingCfg {
    IF DEFINED LANDING_CFG {
        FOR mapping IN _landingCfgMappings() {
            LOCAL cfgKey IS mapping[0].
            LOCAL landingKey IS mapping[1].
            IF CFG:HASKEY(cfgKey) {
                SET LANDING_CFG[landingKey] TO CFG[cfgKey].
            }
        }
    }
}

GLOBAL FUNCTION fr3ApplyMissionProfile {
    IF MISSION["target"]:TOUPPER = "MUN" AND _fr3HasLandingPayload() {
        IF DEFINED LANDING_CFG {
            SET LANDING_CFG["DEORBIT_PE"] TO 5000.
            SET LANDING_CFG["TARGET_TOLERANCE"] TO 2500.
            SET LANDING_CFG["GUIDANCE_ALT"] TO 5000.
        }

        IF _fr3HasPayload("ASSISTROVER") OR _fr3HasPayload("ASSISTLANDER") {
            IF DEFINED LANDING_CFG {
                SET LANDING_CFG["ASSIST_RELEASE_ALT"] TO 100.
                SET LANDING_CFG["ASSIST_RELEASE_HSPEED"] TO 0.5.
                SET LANDING_CFG["ASSIST_RELEASE_VSPEED"] TO 0.
            }
            cfgSet("RELOAD_AFTER_LAND_ASSIST", 1).
        }
        IF _fr3HasPayload("ROVER") OR _fr3HasPayload("ASSISTROVER") {
            cfgSet("RELOAD_AFTER_LAND", 1).
        }
    }

    _copyLandingCfg().

    IF MISSION["target"]:TOUPPER = "MUN"
            AND _fr3HasPayload("SCANSAT")
            AND _fr3HasLandingPayload() {
        // Mun mapper + rover stack: deploy mapper in a useful polar orbit,
        // then spend the remaining vehicle on targeted rover landing.
        SET CFG["CAPTURE_PE"] TO 15000.
        SET CFG["CAPTURE_INC"] TO 90.
        SET CFG["TARGET_PE"] TO 250000.
        SET CFG["TARGET_AP"] TO 250000.
        SET CFG["TARGET_INCLINATION"] TO 90.
        SET CFG["MAX_INCL_CHANGE_DV"] TO 300.
    }
}

LOCAL FUNCTION _phaseParkingReload {
    phaseParking().
    IF CFG:HASKEY("RELOAD_AFTER_PARK") AND CFG["RELOAD_AFTER_PARK"] > 0 {
        fr3SaveReloadState("PARKING_ORBIT", stateGet("phase", "")).
        mLog("Reload point after parking orbit. Reboot to load transfer libraries.").
        PRINT " ".
        PRINT "  PARKING ORBIT READY".
        PRINT "  Reboot this CPU to load transfer code.".
        WAIT UNTIL FALSE.
    }
}

GLOBAL FUNCTION fr3BuildPhaseSequence {
    IF CFG:HASKEY("SEQUENCE") {
        RETURN _phaseListFromString(CFG["SEQUENCE"]).
    }

    LOCAL orbitPhases IS LIST("CIRC", "RAISE", "INCLINE").
    LOCAL payloadPhases IS LEXICON(
        "CRASHPROBE", LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "PROBE",      LIST("TARGETED_DEORBIT", "RELEASE_PROBE"),
        "RELAY",      LIST("RELAY_OPS"),
        "SCANSAT",    LIST("SCANSAT_OPS"),
        "SCISAT",     LIST("RELAY_OPS"),
        "ASSISTLANDER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND"),
        "LANDER",     LIST("LAND_DEORBIT", "LAND"),
        "ASSISTROVER", LIST("LAND_DEORBIT", "LAND_ASSIST", "LAND", "ROVER"),
        "ROVER",      LIST("LAND_DEORBIT", "LAND", "ROVER")
    ).

    RETURN buildRocketSequence(orbitPhases, payloadPhases).
}

GLOBAL FUNCTION fr3BuildPhaseMap {
    LOCAL band IS fr3PhaseBand().
    LOCAL phaseMap IS LEXICON().

    IF band = "LAUNCH" {
        phaseMap:ADD("LUNCH", phaseLaunch@).
        phaseMap:ADD("FAIR", phaseFairing@).
        phaseMap:ADD("ANTS", phaseExtendAnts@).
        phaseMap:ADD("PARK", _phaseParkingReload@).
    }

    IF band = "TRANSFER" {
        phaseMap:ADD("RDV", phaseRendezvous@).
        phaseMap:ADD("XING", phaseTransfer@).
        phaseMap:ADD("MCC", phaseMidCourse@).
        phaseMap:ADD("COAST", phaseCoast@).
        phaseMap:ADD("CAPTURE", phaseCapture@).
        phaseMap:ADD("CIRC", phaseCirc@).
        phaseMap:ADD("RAISE", phaseRaiseAlt@).
        phaseMap:ADD("INCLINE", phaseInclCorrect@).
    }

    IF band = "PAYLOAD_OPS" AND (_fr3HasPayload("PROBE") OR _fr3HasPayload("CRASHPROBE")) {
        phaseMap:ADD("TARGETED_DEORBIT", phaseTargetedDeorbit@).
        phaseMap:ADD("RELEASE_PROBE", phaseReleaseProbe@).
    }
    IF band = "PAYLOAD_OPS" AND (_fr3HasPayload("RELAY") OR _fr3HasPayload("SCISAT")) {
        phaseMap:ADD("RELAY_OPS", phaseRelayOps@).
    }
    IF band = "PAYLOAD_OPS" AND _fr3HasPayload("SCANSAT") {
        phaseMap:ADD("SCANSAT_OPS", phaseScanSatOps@).
    }
    IF band = "LAND_ASSIST" {
        phaseMap:ADD("LAND_DEORBIT", phaseLandDeorbit@).
        phaseMap:ADD("LAND_ASSIST", phaseLandAssist@).
    }
    IF band = "LAND" {
        phaseMap:ADD("LAND", phaseLand@).
    }
    IF band = "ROVER" {
        phaseMap:ADD("ROVER", phaseRover@).
    }

    RETURN phaseMap.
}

GLOBAL FUNCTION fr3PrintConfig {
    LOCAL seq IS fr3BuildPhaseSequence().
    LOCAL hasScanSat IS _fr3HasPayload("SCANSAT").
    LOCAL hasLander IS _fr3HasLandingPayload().

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
        IF LANDING_CFG["TARGET_WAYPOINT"] <> "" {
            SET targetText TO "waypoint " + LANDING_CFG["TARGET_WAYPOINT"].
        } ELSE IF LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0 {
            SET targetText TO ROUND(LANDING_CFG["TARGET_LAT"],4)
                + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng".
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
