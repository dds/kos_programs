// cmd/landingrescue.ks - One-shot powered landing rescue.
// Usage: RUNPATH("0:/cmd/landingrescue.ks").
// Legacy phase prep: RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").

PARAMETER mode IS "AUTO".

LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
PRINT "Landing rescue: free before " + beforeFree + " bytes.".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL vehicleInfo IS bootVehicleInfo().
LOCAL keepCrafts IS LIST(vehicleInfo["VEHICLE"]).
LOCAL keepRoles IS LIST().
IF CORE:TAG <> "" { keepRoles:ADD(CORE:TAG). }

LOCAL autoMode IS mode = "AUTO" OR mode = "auto" OR mode = "".
LOCAL phaseName IS mode.
LOCAL sequence IS LIST().
LOCAL rescuePlan IS "legacy".
LOCAL profilePath IS "".

LOCAL FUNCTION _addUnique {
    PARAMETER items.
    PARAMETER item.
    IF NOT items:CONTAINS(item) { items:ADD(item). }
}

LOCAL FUNCTION _addMany {
    PARAMETER items.
    PARAMETER moreItems.
    FOR item IN moreItems {
        _addUnique(items, item).
    }
}

LOCAL FUNCTION _keepLibsForSequence {
    PARAMETER seq.
    LOCAL keep IS LIST(
        "state", "logs", "files", "boot_lib", "resume", "recovery",
        "phases", "utils", "ui", "core", "dependencies", "config",
        "mission_type", "fr3_payload", "fr3_profile", "fr3_sequence"
    ).
    FOR ph IN seq {
        IF ph = "LAND_DEORBIT" {
            _addMany(keep, LIST(
                "payload_landing", "landing_deorbit", "landing_config",
                "landing_math", "deorbit_burn", "deorbit_targeting",
                "maneuver", "countdown", "solar", "orbit_nodes", "orbit"
            )).
        } ELSE IF ph = "LAND_ASSIST" OR ph = "LAND" {
            _addMany(keep, LIST(
                "payload_landing", "landing_main", "landing_config",
                "landing_math", "vessel_hardware", "landing_coast",
                "landing_brake", "landing_terminal", "landing_carrier"
            )).
        } ELSE IF ph = "AEROBRAKE" {
            _addMany(keep, LIST(
                "aerobrake", "maneuver", "countdown", "solar",
                "orbit_nodes", "orbit", "utils"
            )).
        } ELSE IF ph = "DESCENT" {
            _addMany(keep, LIST("descent")).
        }
    }
    RETURN keep.
}

LOCAL FUNCTION _atmHeight {
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN 0. }
    RETURN SHIP:BODY:ATM:HEIGHT.
}

LOCAL FUNCTION _atmoEntryUseful {
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN FALSE. }
    LOCAL atmTop IS _atmHeight().
    IF SHIP:ALTITUDE >= atmTop { RETURN TRUE. }
    RETURN SHIP:ALTITUDE >= atmTop * 0.9.
}

LOCAL FUNCTION _atmoEntryAlreadySet {
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN FALSE. }
    LOCAL atmTop IS _atmHeight().
    IF SHIP:ALTITUDE < atmTop { RETURN TRUE. }
    RETURN SHIP:PERIAPSIS < atmTop.
}

LOCAL FUNCTION _impactTrajectory {
    IF SHIP:STATUS = "SUB_ORBITAL" { RETURN TRUE. }
    IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT { RETURN TRUE. }
    IF SHIP:BODY:ATM:EXISTS { RETURN SHIP:PERIAPSIS < _atmHeight(). }
    RETURN SHIP:PERIAPSIS < 0.
}

LOCAL FUNCTION _lockRescueTarget {
    LOCAL lat IS 0.
    LOCAL lng IS 0.
    IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
        SET lat TO ADDONS:TR:IMPACTPOS:LAT.
        SET lng TO ADDONS:TR:IMPACTPOS:LNG.
    } ELSE {
        LOCAL lead IS 300.
        IF SHIP:ORBIT:ECCENTRICITY < 1 AND ETA:PERIAPSIS > 0 {
            SET lead TO MAX(300, MIN(ETA:PERIAPSIS, 1800)).
        }
        LOCAL geo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, TIME:SECONDS + lead)).
        SET lat TO geo:LAT.
        SET lng TO geo:LNG.
    }
    LOG "SET TARGET_LAT TO " + configLiteral(lat) + "." TO profilePath.
    LOG "SET TARGET_LNG TO " + configLiteral(lng) + "." TO profilePath.
    LOG "SET TARGET_LOCK TO " + configLiteral(1) + "." TO profilePath.
    LOG "SET TARGET_WAYPOINT TO " + configLiteral("") + "." TO profilePath.
}

LOCAL FUNCTION _chooseAutoPlan {
    LOCAL seq IS LIST().
    LOCAL firstPhase IS "LAND_ASSIST".
    LOCAL planName IS "powered-assist".
    LOCAL impact IS _impactTrajectory().
    LOCAL aeroUseful IS _atmoEntryUseful().
    LOCAL aeroReady IS _atmoEntryAlreadySet().

    IF SHIP:BODY:ATM:EXISTS AND aeroUseful {
        IF aeroReady {
            SET seq TO LIST("AEROBRAKE", "LAND_ASSIST", "DONE").
            SET firstPhase TO "AEROBRAKE".
            SET planName TO "aerobrake-powered-assist".
        } ELSE {
            SET seq TO LIST("LAND_DEORBIT", "AEROBRAKE", "LAND_ASSIST", "DONE").
            SET firstPhase TO "LAND_DEORBIT".
            SET planName TO "cheap-deorbit-aerobrake-powered-assist".
        }
    } ELSE IF impact {
        SET seq TO LIST("LAND_ASSIST", "DONE").
        SET firstPhase TO "LAND_ASSIST".
        SET planName TO "powered-assist".
    } ELSE {
        SET seq TO LIST("LAND_DEORBIT", "LAND_ASSIST", "DONE").
        SET firstPhase TO "LAND_DEORBIT".
        SET planName TO "cheap-deorbit-powered-assist".
    }

    RETURN LEXICON("PHASE", firstPhase, "SEQUENCE", seq, "PLAN", planName).
}

IF autoMode {
    LOCAL picked IS _chooseAutoPlan().
    SET phaseName TO picked["PHASE"].
    SET sequence TO picked["SEQUENCE"].
    SET rescuePlan TO picked["PLAN"].

    SET profilePath TO missionProfileBegin(vehicleInfo["VEHICLE"], "landing_rescue_auto").
    missionOverrideClear().
    stateSet("target", SHIP:BODY:NAME:TOUPPER).
    stateSet("mission_type", "landing_rescue").
    stateSet("mission_id", "landing_rescue_auto").
    stateSet("mission_name", "Landing Rescue").
    stateSet("payloads", LIST("RESCUE")).

    LOG "SET MISSION_ID TO " + configLiteral("landing_rescue_auto") + "." TO profilePath.
    LOG "SET MISSION_NAME TO " + configLiteral("Landing Rescue") + "." TO profilePath.
    LOG "SET TARGET_ TO " + configLiteral(SHIP:BODY:NAME:TOUPPER) + "." TO profilePath.
    LOG "SET PAYLOADS TO " + configLiteral(LIST("RESCUE")) + "." TO profilePath.
    LOG "SET SEQUENCE TO " + configLiteral(sequence) + "." TO profilePath.
    LOG "SET LANDING_SKIP_TARGET_SEARCH TO " + configLiteral(1) + "." TO profilePath.
    LOG "SET RELOAD_AFTER_LAND_ASSIST TO " + configLiteral(0) + "." TO profilePath.
    LOG "SET RELOAD_AFTER_LAND TO " + configLiteral(0) + "." TO profilePath.
    LOG "SET LANDING_DEORBIT_LEAD_MINUTES TO " + configLiteral(MAX(0.5, ETA:APOAPSIS / 60)) + "." TO profilePath.
    LOG "SET LANDING_AUTO_TARGET TO " + configLiteral(0) + "." TO profilePath.
    LOG "SET LANDING_CONFIRM_TARGET TO " + configLiteral(0) + "." TO profilePath.
    LOG "SET AEROBRAKE_REENTRY_DIR TO " + configLiteral("RETROGRADE") + "." TO profilePath.
    LOG "SET AEROBRAKE_ARM_CHUTES TO " + configLiteral(0) + "." TO profilePath.
    LOG "SET DESCENT_ENGINE_ASSIST TO " + configLiteral(1) + "." TO profilePath.
    _lockRescueTarget().
} ELSE {
    SET phaseName TO mode.
    SET sequence TO LIST(phaseName, "DONE").
    SET profilePath TO missionProfileBegin(vehicleInfo["VEHICLE"], "landing_rescue_manual").
    missionOverrideClear().
    stateSet("mission_id", "landing_rescue_manual").
    LOG "SET MISSION_ID TO " + configLiteral("landing_rescue_manual") + "." TO profilePath.
    LOG "SET MISSION_NAME TO " + configLiteral("Landing Rescue Manual") + "." TO profilePath.
    LOG "SET TARGET_ TO " + configLiteral(SHIP:BODY:NAME:TOUPPER) + "." TO profilePath.
    LOG "SET SEQUENCE TO " + configLiteral(sequence) + "." TO profilePath.
}

LOCAL keepLibs IS _keepLibsForSequence(sequence).

LOCAL FUNCTION _deleteIfExists {
    PARAMETER path_.
    IF EXISTS(path_) {
        DELETEPATH(path_).
        RETURN TRUE.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _baseName {
    PARAMETER fileName.
    IF fileName:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF fileName:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    RETURN fileName.
}

LOCAL FUNCTION _pruneDir {
    PARAMETER dirPath.
    PARAMETER keepNames.

    LOCAL removed IS 0.
    IF NOT EXISTS(dirPath) { RETURN removed. }
    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(dirPath).
    LIST FILES IN items.
    CD(startPath).
    FOR item IN items {
        LOCAL path_ IS dirPath + "/" + item:NAME.
        IF item:ISFILE {
            LOCAL base IS _baseName(item:NAME).
            IF NOT keepNames:CONTAINS(base) {
                IF _deleteIfExists(path_) { SET removed TO removed + 1. }
            }
        }
    }
    RETURN removed.
}

LOCAL removed IS 0.

SET removed TO removed + _pruneDir("1:/lib", keepLibs).
SET removed TO removed + _pruneDir("1:/craft", keepCrafts).
SET removed TO removed + _pruneDir("1:/roles", keepRoles).
SET removed TO removed + _pruneDir("1:/cmd", LIST()).
IF _deleteIfExists("1:/zombie") { SET removed TO removed + 1. }

IF EXISTS("1:/run") {
    SET removed TO removed + bootDeleteLogFiles("1:/run").
}

RUNPATH("1:/lib/boot_lib").
bootLibLoad("state").
stateSet("phase", phaseName).
stateSet("reload_required", "false").
stateSet("reload_reason", "").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").
stateRemove("lib_band_libs").
stateRemove("lib_band_phase").
IF phaseName = "LAND_DEORBIT" {
    stateSet("lib_band", "LAND_DEORBIT").
} ELSE IF phaseName = "LAND_ASSIST" {
    stateSet("lib_band", "LANDING").
} ELSE IF phaseName = "AEROBRAKE" {
    stateSet("lib_band", "AEROBRAKE").
} ELSE IF phaseName = "DESCENT" {
    stateSet("lib_band", "DESCENT").
} ELSE {
    stateSet("lib_band", "LANDING").
}

PRINT "Landing rescue: removed " + removed + " files.".
PRINT "Landing rescue: plan -> " + rescuePlan + ".".
PRINT "Landing rescue: sequence -> " + sequence:JOIN(" -> ") + ".".
PRINT "Landing rescue: phase -> " + phaseName + ".".
PRINT "Landing rescue: free after  " + CORE:VOLUME:FREESPACE + " bytes.".
IF autoMode {
    PRINT "Landing rescue: rebooting.".
    REBOOT.
} ELSE {
    PRINT "Run: REBOOT.".
}
