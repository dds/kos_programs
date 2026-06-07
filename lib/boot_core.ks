GLOBAL FUNCTION bootEnsureDirs {
    FOR p IN LIST("1:/lib","1:/boot","1:/logs","1:/state","1:/cmd","1:/craft","1:/roles","1:/missions") {
        IF NOT EXISTS(p) { CREATEDIR(p). }
    }
}

GLOBAL FUNCTION bootVehicleInfo {
    LOCAL isEVA IS SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA").
    LOCAL vehicleName IS "".
    LOCAL targetName IS "".
    LOCAL payloadTypes IS LIST().
    LOCAL sourceName IS SHIP:NAME.
    IF isEVA {
        SET vehicleName TO "EVA".
        SET targetName TO SHIP:BODY:NAME:TOUPPER.
        PRINT "  EVA KERBAL DETECTED".
    } ELSE IF stateGet("vehicle", "") <> ""
            AND NOT stateGet("vehicle", ""):CONTAINS(" ")
            AND SHIP:STATUS <> "PRELAUNCH" {
        SET vehicleName TO stateGet("vehicle", "").
        SET targetName TO stateGet("target", "KERBIN"):TOUPPER.
        LOCAL rawPayloads IS stateGet("payloads", "").
        IF rawPayloads <> "" {
            FOR p IN rawPayloads:SPLIT(",") {
                LOCAL trimmedPayload IS p:TRIM:TOUPPER.
                IF trimmedPayload <> "" { payloadTypes:ADD(trimmedPayload). }
            }
        }
    } ELSE {
        IF stateGet("vessel_name", "") = "" OR SHIP:STATUS = "PRELAUNCH" {
            stateSet("vessel_name", SHIP:NAME).
        } ELSE {
            SET sourceName TO stateGet("vessel_name", SHIP:NAME).
        }
        LOCAL structuredName IS sourceName:CONTAINS("-").
        LOCAL rawTokens IS sourceName:SPLIT("-").
        IF NOT structuredName { SET rawTokens TO sourceName:SPLIT(" "). }
        LOCAL tokens IS LIST().
        FOR t IN rawTokens {
            LOCAL trimmed IS t:TRIM.
            IF trimmed <> "" { tokens:ADD(trimmed). }
        }
        IF tokens:LENGTH > 0 {
            SET vehicleName TO tokens[0].
        } ELSE {
            SET vehicleName TO "UNKNOWN".
        }
        IF structuredName AND tokens:LENGTH >= 2 {
            SET targetName TO tokens[1]:TOUPPER.
            FROM { LOCAL i IS 2. } UNTIL i >= tokens:LENGTH STEP { SET i TO i + 1. } DO {
                payloadTypes:ADD(tokens[i]:TOUPPER).
            }
        } ELSE {
            SET targetName TO "KERBIN".
        }
    }
    IF stateGet("vessel_name", "") = "" OR SHIP:STATUS = "PRELAUNCH" {
        stateSet("vessel_name", SHIP:NAME).
    }
    RETURN LEXICON(
        "IS_EVA", isEVA,
        "VEHICLE", vehicleName,
        "TARGET", targetName,
        "PAYLOADS", payloadTypes
    ).
}

GLOBAL FUNCTION bootResolveScript {
    PARAMETER name.
    PARAMETER dirs.
    PARAMETER hasLink.
    IF hasLink {
        FOR d IN dirs {
            IF EXISTS("0:/" + d + "/" + name + ".ks") { RETURN d + "/" + name. }
        }
        IF EXISTS("0:/" + name + ".ks") { RETURN name. }
    }
    FOR d IN dirs {
        IF EXISTS("1:/" + d + "/" + name + ".ks")
                OR EXISTS("1:/" + d + "/" + name + ".ksm") {
            RETURN d + "/" + name.
        }
    }
    IF EXISTS("1:/" + name + ".ks") OR EXISTS("1:/" + name + ".ksm") { RETURN name. }
    RETURN "".
}

GLOBAL FUNCTION bootCompiledPath {
    PARAMETER scriptPath_.
    IF scriptPath_:CONTAINS("/") {
        LOCAL parts IS scriptPath_:SPLIT("/").
        RETURN "1:/" + parts[0] + "/" + parts[1] + ".ksm".
    }
    RETURN "1:/" + scriptPath_ + ".ksm".
}

GLOBAL FUNCTION bootSourcePath {
    PARAMETER scriptPath_.
    RETURN "1:/" + scriptPath_ + ".ks".
}

GLOBAL FUNCTION bootSyncScript {
    PARAMETER scriptPath_.
    PARAMETER hasLink.
    IF NOT hasLink { RETURN. }
    LOCAL src IS "0:/" + scriptPath_ + ".ks".
    LOCAL dst IS bootSourcePath(scriptPath_).
    LOCAL dstKsm IS bootCompiledPath(scriptPath_).
    IF EXISTS(src) {
        COMPILE src TO dstKsm.
        IF EXISTS(dst) { DELETEPATH(dst). }
    }
}

GLOBAL FUNCTION bootRunScript {
    PARAMETER scriptPath_.
    LOCAL compiled IS bootCompiledPath(scriptPath_).
    IF EXISTS(compiled) {
        RUNPATH(compiled).
    } ELSE {
        RUNPATH(bootSourcePath(scriptPath_)).
    }
}

GLOBAL FUNCTION bootLibBaseName {
    PARAMETER fileName.
    LOCAL upper IS fileName:TOUPPER.
    IF upper:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF upper:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    RETURN fileName.
}

GLOBAL FUNCTION bootPruneLibs {
    PARAMETER wantedLibs.
    LOCAL keep IS LIST("STATE", "LOGS", "FILES", "BOOT_CORE", "RESUME", "RECOVERY").
    FOR lib IN wantedLibs {
        LOCAL libKey IS lib:TOUPPER.
        IF NOT keep:CONTAINS(libKey) { keep:ADD(libKey). }
    }
    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD("1:/lib").
    LIST FILES IN items.
    CD(startPath).
    FOR item IN items {
        IF item:ISFILE {
            LOCAL base IS bootLibBaseName(item:NAME).
            IF NOT keep:CONTAINS(base:TOUPPER) {
                DELETEPATH("1:/lib/" + item:NAME).
            }
        }
    }
}

GLOBAL FUNCTION bootMissionConfigIds {
    PARAMETER craftName.
    PARAMETER hasLink.
    LOCAL ids IS LIST().
    LOCAL cfgDir IS "1:/missions/" + craftName.
    LOCAL archiveDir IS "0:/missions/" + craftName.
    IF hasLink AND EXISTS(archiveDir) { SET cfgDir TO archiveDir. }
    IF NOT EXISTS(cfgDir) { RETURN ids. }
    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(cfgDir).
    LIST FILES IN items.
    CD(startPath).
    FOR item IN items {
        IF item:ISFILE {
            LOCAL nm IS item:NAME.
            IF nm:TOUPPER:CONTAINS(".CFG") {
                ids:ADD(nm:SUBSTRING(0, nm:LENGTH - 4)).
            }
        }
    }
    RETURN ids.
}

GLOBAL FUNCTION bootSelectMissionId {
    PARAMETER craftName.
    PARAMETER hasLink.
    LOCAL configured IS stateGet("mission_id", "").
    IF configured <> "" { RETURN configured. }
    LOCAL ids IS bootMissionConfigIds(craftName, hasLink).
    IF ids:LENGTH = 0 { RETURN "". }
    IF ids:LENGTH = 1 { RETURN ids[0]. }
    PRINT " ".
    PRINT "  ========================================".
    PRINT "  " + craftName + " MISSION SELECT".
    PRINT "  Pick your poison. Confirm your glory.".
    PRINT "  ========================================".
    LOCAL maxShown IS MIN(ids:LENGTH, 9).
    FROM { LOCAL i IS 0. } UNTIL i >= maxShown STEP { SET i TO i + 1. } DO {
        PRINT "  [" + (i + 1) + "] " + ids[i].
    }
    PRINT "  ----------------------------------------".
    PRINT "  Press 1-" + maxShown + " to choose, ENTER for " + ids[0] + ".".
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

GLOBAL FUNCTION bootMissionConfigPath {
    PARAMETER craftName.
    PARAMETER missionId.
    PARAMETER hasLink.
    LOCAL archivePath IS "0:/missions/" + craftName + "/" + missionId + ".cfg".
    IF hasLink AND EXISTS(archivePath) { RETURN archivePath. }
    RETURN "1:/missions/" + craftName + "/" + missionId + ".cfg".
}

GLOBAL FUNCTION bootApplyMissionConfig {
    PARAMETER craftName.
    PARAMETER missionId.
    PARAMETER hasLink.
    IF missionId = "" { RETURN FALSE. }
    LOCAL path_ IS bootMissionConfigPath(craftName, missionId, hasLink).
    IF NOT EXISTS(path_) {
        PRINT "  Mission config not found: " + path_.
        RETURN FALSE.
    }
    LOCAL raw IS OPEN(path_):READALL:STRING.
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
                    stateSet("mission_cfg_" + key, value).
                    IF key = "MISSION_ID" {
                        stateSet("mission_id", value).
                    } ELSE IF key = "MISSION_NAME" {
                        stateSet("mission_name", value).
                    } ELSE IF key = "TARGET" {
                        stateSet("target", value:TOUPPER).
                    } ELSE IF key = "PAYLOADS" {
                        stateSet("payloads", value:TOUPPER).
                    }
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

GLOBAL FUNCTION bootPruneMissionConfigs {
    PARAMETER craftName.
    LOCAL cfgDir IS "1:/missions/" + craftName.
    IF NOT EXISTS(cfgDir) { RETURN. }
    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(cfgDir).
    LIST FILES IN items.
    CD(startPath).
    FOR item IN items {
        IF item:ISFILE { DELETEPATH(cfgDir + "/" + item:NAME). }
    }
}

GLOBAL FUNCTION bootMissionConfig {
    PARAMETER craftName.
    PARAMETER hasLink.
    LOCAL targetFromName IS stateGet("target", "KERBIN"):TOUPPER.
    LOCAL payloadsFromName IS stateGet("payloads", "").
    LOCAL hasNameMission IS targetFromName <> "KERBIN" OR payloadsFromName <> "".
    LOCAL missionId IS stateGet("mission_id", "").
    IF missionId = "" AND NOT hasNameMission {
        SET missionId TO bootSelectMissionId(craftName, hasLink).
    }
    IF missionId <> "" {
        bootApplyMissionConfig(craftName, missionId, hasLink).
    }
}

GLOBAL FUNCTION bootIsLaunchStartPhase {
    PARAMETER phaseName.
    LOCAL phase IS phaseName:TOUPPER.
    RETURN phase = "" OR phase = "LUNCH" OR phase = "FAIR" OR phase = "ANTS".
}

GLOBAL FUNCTION bootShouldResetMissionOnBoot {
    PARAMETER isEVA.
    IF isEVA { RETURN FALSE. }
    IF SHIP:STATUS = "PRELAUNCH" { RETURN TRUE. }
    LOCAL phase IS stateGet("phase", "").
    IF SHIP:BODY:NAME = "Kerbin"
            AND SHIP:STATUS = "LANDED"
            AND stateGetNum("launch_time", 0) = 0
            AND bootIsLaunchStartPhase(phase) {
        RETURN TRUE.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION bootResetMissionSelection {
    PARAMETER vehicleName.
    PARAMETER targetName.
    PARAMETER payloadTypes.
    LOCAL removed IS stateRemovePrefix("mission_cfg_").
    FOR key IN LIST(
        "mission_id", "mission_name", "phase", "fairing_deployed",
        "lib_band", "lib_band_phase", "lib_band_libs",
        "reload_required", "reload_reason", "reload_next_phase",
        "reload_next_band"
    ) {
        stateRemove(key).
    }
    stateSet("vehicle", vehicleName).
    stateSet("target", targetName).
    stateSet("payloads", payloadTypes:JOIN(",")).
    PRINT "  Mission selection reset for prelaunch.".
    mLog("Mission selection reset before launch; cleared " + removed + " config keys.").
}

GLOBAL FUNCTION bootResumeOrManual {
    PARAMETER hasLink.
    PRINT " ".
    PRINT "  >> Press any key for MANUAL mode (5s)".
    LOCAL overrideStart IS TIME:SECONDS.
    LOCAL manualMode IS FALSE.
    WAIT UNTIL TIME:SECONDS > overrideStart + 5 OR TERMINAL:INPUT:HASCHAR.
    IF TERMINAL:INPUT:HASCHAR {
        TERMINAL:INPUT:GETCHAR().
        SET manualMode TO TRUE.
    }
    IF NOT manualMode {
        LOCAL phase IS stateGet("phase", "").
        IF phase = "DONE" {
            PRINT " ".
            PRINT "  MISSION COMPLETE. MANUAL MODE.".
            mLog("Reboot after DONE - manual mode.").
        } ELSE IF phase = "ABORT" {
            PRINT "  ABORT DETECTED - entering recovery mode.".
            mLog("Abort detected at reboot - loading recovery.").
            recoveryMode().
        } ELSE {
            PRINT "  RESUMING >> " + phase.
            mLog("Resuming mission from phase: " + phase).
            resumeMission().
        }
    }
    IF hasLink {
        archiveLog().
    }
}
