// ============================================================
// boot_lib.ks - boot helpers and dependency expansion
// ============================================================

GLOBAL FUNCTION bootEnsureDirs {
    FOR p IN LIST("1:/lib","1:/boot","1:/logs","1:/state","1:/cmd","1:/craft","1:/roles") {
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
    RETURN bootBaseName(fileName).
}

GLOBAL FUNCTION bootBaseName {
    PARAMETER fileName.
    LOCAL upper IS fileName:TOUPPER.
    IF upper:CONTAINS(".KSM") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF upper:CONTAINS(".KS") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    IF upper:CONTAINS(".CFG") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF upper:CONTAINS(".TXT") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    RETURN fileName.
}

GLOBAL FUNCTION bootPruneLibs {
    PARAMETER wantedLibs.
    LOCAL keep IS LIST(
        "STATE", "LOGS", "FILES", "MISSION_PLAN", "BOOT_LIB",
        "DEPENDENCIES",
        "CONFIG", "RESUME"
    ).
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
    LOCAL archiveDir IS "0:/missions/" + craftName.
    IF NOT hasLink OR NOT EXISTS(archiveDir) { RETURN ids. }
    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD(archiveDir).
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
    RETURN archivePath.
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
                    IF NOT missionConfigIsKnownKey(key) {
                        LOCAL warn IS "Unknown mission config key: " + key + " in " + path_.
                        PRINT "  WARN: " + warn.
                        mLogWarn(warn).
                    }
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
    IF DEFINED printStorageStatus { printStorageStatus(). }
    RETURN TRUE.
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

GLOBAL FUNCTION bootDefaultBandForVehicle {
    PARAMETER vehicleName.
    LOCAL vehicle IS vehicleName:TOUPPER.
    IF vehicle = "ROVER" { RETURN "ROVER". }
    IF vehicle = "FJ1A" OR vehicle = "FJ4B" OR vehicle = "FSP1"
            OR vehicle:CONTAINS("AIR") OR vehicle:CONTAINS("PLANE")
            OR vehicle:CONTAINS("SEA") {
        RETURN "PREFLIGHT".
    }
    RETURN "LAUNCH".
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

// ── Generalized cleanup ──────────────────────────────────────
// These functions replace craft-specific cleanup (e.g. FR3's
// _fr3EmergencyCleanup) with reusable boot-level utilities.
// Called from boot.ks when a craft script sets BOOT_CLEANUP.

GLOBAL FUNCTION bootDeleteIfExists {
    PARAMETER path_.
    IF EXISTS(path_) {
        DELETEPATH(path_).
        RETURN TRUE.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION bootPruneDir {
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
        IF item:ISFILE {
            LOCAL base IS bootBaseName(item:NAME):TOUPPER.
            IF NOT keepNames:CONTAINS(base) {
                IF bootDeleteIfExists(dirPath + "/" + item:NAME) {
                    SET removed TO removed + 1.
                }
            }
        }
    }
    RETURN removed.
}

GLOBAL FUNCTION bootPruneLogs {
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
    }
    LOCAL removed IS 0.
    IF EXISTS("1:/logs") {
        LOCAL startPath IS PATH().
        LOCAL items IS LIST().
        CD("1:/logs").
        LIST FILES IN items.
        CD(startPath).
        FOR item IN items {
            IF item:ISFILE {
                IF bootDeleteIfExists("1:/logs/" + item:NAME) {
                    SET removed TO removed + 1.
                }
            }
        }
    }
    IF bootDeleteIfExists("1:/state/log_path.state") {
        SET removed TO removed + 1.
    }
    RETURN removed.
}

GLOBAL FUNCTION bootCleanup {
    PARAMETER vehicleName.
    PARAMETER wantedLibs.
    PARAMETER keepCmds IS LIST().
    LOCAL keepLibs IS LIST(
        "STATE", "LOGS", "BOOT_LIB", "RESUME",
        "PHASES", "UTILS", "UI", "FR3_PAYLOAD", "FR3_PROFILE", "FR3_SEQUENCE",
        "CONFIG"
    ).
    FOR lib IN wantedLibs {
        LOCAL key IS lib:TOUPPER.
        IF NOT keepLibs:CONTAINS(key) { keepLibs:ADD(key). }
    }

    LOCAL keepRoles IS LIST().
    IF CORE:TAG <> "" { keepRoles:ADD(CORE:TAG:TOUPPER). }

    LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
    LOCAL removed IS 0.
    SET removed TO removed + bootPruneDir("1:/lib", keepLibs).
    SET removed TO removed + bootPruneDir("1:/craft", LIST(vehicleName:TOUPPER)).
    SET removed TO removed + bootPruneDir("1:/roles", keepRoles).
    SET removed TO removed + bootPruneDir("1:/cmd", keepCmds).
    SET removed TO removed + bootPruneDir("1:/missions/" + vehicleName, LIST()).
    IF bootDeleteIfExists("1:/zombie") { SET removed TO removed + 1. }
    SET removed TO removed + bootPruneLogs().

    IF removed > 0 {
        mLog("Cleanup removed " + removed + " files; free "
            + beforeFree + " -> " + CORE:VOLUME:FREESPACE + ".").
    }
}

// ============================================================
// boot_lib.ks - boot-time library dependency expansion
//
// This stays deliberately small: dependencies.txt is refreshed when
// available, parsed with OPEN(...):READALL:STRING, then cached in
// lexicons/lists for the rest of the boot.
// ============================================================

GLOBAL BOOT_LIB_DEPS IS LEXICON().
GLOBAL BOOT_LIB_BANDS IS LEXICON().
GLOBAL BOOT_LIB_PHASES IS LEXICON().
GLOBAL BOOT_LIB_PREAMBLE IS LIST().
GLOBAL BOOT_LIB_LOADED IS FALSE.
GLOBAL BOOT_LIB_RAN IS LIST().

GLOBAL FUNCTION bootLibSpecPath {
    LOCAL archivePath IS "0:/lib/dependencies.txt".
    LOCAL localPath IS "1:/lib/dependencies.txt".
    IF HOMECONNECTION:ISCONNECTED AND EXISTS(archivePath) {
        IF NOT EXISTS("1:/lib") { CREATEDIR("1:/lib"). }
        COPYPATH(archivePath, localPath).
    }
    RETURN localPath.
}

LOCAL FUNCTION _bootLibApplyValues {
    PARAMETER table.
    PARAMETER key.
    PARAMETER values.
    PARAMETER op.
    LOCAL current IS LIST().
    IF table:HASKEY(key) {
        FOR item IN table[key] { current:ADD(item). }
        table:REMOVE(key).
    }
    IF op = "=" {
        SET current TO LIST().
    }
    IF op = "-" {
        LOCAL kept IS LIST().
        FOR item IN current {
            IF NOT values:CONTAINS(item) { kept:ADD(item). }
        }
        SET current TO kept.
    } ELSE {
        FOR item IN values {
            IF NOT current:CONTAINS(item) { current:ADD(item). }
        }
    }
    table:ADD(key, current).
}

LOCAL FUNCTION _bootLibLineValues {
    PARAMETER raw.
    LOCAL values IS LIST().
    IF raw = "" { RETURN values. }
    FOR itemRaw IN raw:SPLIT(",") {
        LOCAL item IS itemRaw:TRIM.
        IF item <> "" { values:ADD(item). }
    }
    RETURN values.
}

LOCAL FUNCTION _bootLibBandKey {
    PARAMETER band.
    RETURN band:TOUPPER.
}

LOCAL FUNCTION _bootLibParseLines {
    PARAMETER raw.
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
                    LOCAL lhs IS parts[0]:TRIM.
                    LOCAL rhs IS parts[1]:TRIM.
                    LOCAL op IS "=".
                    IF lhs:LENGTH > 0 {
                        LOCAL opChar IS lhs:SUBSTRING(lhs:LENGTH - 1, 1).
                        IF opChar = "+" OR opChar = "-" {
                            SET op TO opChar.
                            SET lhs TO lhs:SUBSTRING(0, lhs:LENGTH - 1):TRIM.
                        }
                    }
                    LOCAL keys IS _bootLibLineValues(lhs:REPLACE(" ", ",")).
                    IF keys:LENGTH >= 2 AND keys[0]:TOUPPER = "LIB" {
                        LOCAL libName IS keys[1]:TRIM.
                        _bootLibApplyValues(BOOT_LIB_DEPS, libName, _bootLibLineValues(rhs), op).
                    } ELSE IF keys:LENGTH >= 1 AND keys[0]:TOUPPER = "PREAMBLE" {
                        LOCAL preambleTable IS LEXICON("PREAMBLE", BOOT_LIB_PREAMBLE).
                        _bootLibApplyValues(preambleTable, "PREAMBLE", _bootLibLineValues(rhs), op).
                        SET BOOT_LIB_PREAMBLE TO preambleTable["PREAMBLE"].
                    } ELSE IF keys:LENGTH >= 2 AND keys[0]:TOUPPER = "BAND" {
                        LOCAL bandKey IS _bootLibBandKey(keys[1]).
                        _bootLibApplyValues(BOOT_LIB_BANDS, bandKey, _bootLibLineValues(rhs), op).
                    } ELSE IF keys:LENGTH >= 2 AND keys[0]:TOUPPER = "PHASE" {
                        LOCAL phaseIx IS 1.
                        UNTIL phaseIx >= keys:LENGTH {
                            LOCAL phaseName IS keys[phaseIx]:TOUPPER.
                            _bootLibApplyValues(BOOT_LIB_PHASES, phaseName, _bootLibLineValues(rhs), op).
                            SET phaseIx TO phaseIx + 1.
                        }
                    }
                }
            }
        }
    }
}

GLOBAL FUNCTION bootLibLoadSpec {
    IF BOOT_LIB_LOADED { RETURN. }
    LOCAL path_ IS bootLibSpecPath().
    IF NOT EXISTS(path_) {
        PRINT "  WARN: dependencies.txt unavailable".
        SET BOOT_LIB_LOADED TO TRUE.
        RETURN.
    }

    _bootLibParseLines(OPEN(path_):READALL:STRING).
    SET BOOT_LIB_LOADED TO TRUE.
}

GLOBAL FUNCTION bootLibAddUnique {
    PARAMETER libs.
    PARAMETER libName.
    IF libName <> "" AND NOT libs:CONTAINS(libName) {
        libs:ADD(libName).
    }
}

GLOBAL FUNCTION bootLibAppendResolved {
    PARAMETER libs.
    PARAMETER libName.
    bootLibLoadSpec().
    IF BOOT_LIB_DEPS:HASKEY(libName) {
        FOR dep IN BOOT_LIB_DEPS[libName] {
            bootLibAppendResolved(libs, dep).
        }
    }
    bootLibAddUnique(libs, libName).
}

GLOBAL FUNCTION bootLibResolve {
    PARAMETER roots.
    LOCAL libs IS LIST().
    FOR libName IN roots {
        bootLibAppendResolved(libs, libName).
    }
    RETURN libs.
}

GLOBAL FUNCTION bootLibRun {
    PARAMETER libName.
    IF BOOT_LIB_RAN:CONTAINS(libName) { RETURN. }
    bootLibSync(libName).
    LOCAL compiled IS "1:/lib/" + libName + ".ksm".
    LOCAL cached IS "1:/lib/" + libName + ".ks".
    LOCAL archive_ IS "0:/lib/" + libName + ".ks".
    IF EXISTS(compiled) OR EXISTS(cached) {
        RUNPATH("1:/lib/" + libName).
        BOOT_LIB_RAN:ADD(libName).
    } ELSE IF EXISTS(archive_) {
        RUNPATH("0:/lib/" + libName).
        BOOT_LIB_RAN:ADD(libName).
    } ELSE {
        PRINT "  WARN: " + libName + " unavailable".
    }
}

GLOBAL FUNCTION bootLibSync {
    PARAMETER libName.
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN. }
    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dst IS "1:/lib/" + libName + ".ks".
    LOCAL dstKsm IS "1:/lib/" + libName + ".ksm".
    IF EXISTS(src) {
        LOCAL skipKsm IS FALSE.
        IF DEFINED KSM_SKIP {
            IF KSM_SKIP:CONTAINS(libName) { SET skipKsm TO TRUE. }
        }
        IF skipKsm {
            COPYPATH(src, dst).
        } ELSE {
            COMPILE src TO dstKsm.
            IF EXISTS(dst) { DELETEPATH(dst). }
        }
    }
}

GLOBAL FUNCTION bootLibLoadList {
    PARAMETER roots.
    FOR libName IN bootLibResolve(roots) {
        bootLibRun(libName).
    }
}

GLOBAL FUNCTION bootLibLoad {
    PARAMETER libName.
    bootLibLoadList(LIST(libName)).
}

GLOBAL FUNCTION bootPreamble {
    bootLibLoadSpec().
    bootLibLoadList(BOOT_LIB_PREAMBLE).
}

GLOBAL FUNCTION bootLibBandRoots {
    PARAMETER band.
    bootLibLoadSpec().
    LOCAL roots IS LIST().
    FOR libName IN BOOT_LIB_PREAMBLE { bootLibAddUnique(roots, libName). }
    LOCAL bandKey IS _bootLibBandKey(band).
    IF BOOT_LIB_BANDS:HASKEY(bandKey) {
        FOR phaseName IN BOOT_LIB_BANDS[bandKey] {
            FOR libName IN bootLibPhaseRoots(phaseName) { bootLibAddUnique(roots, libName). }
        }
    } ELSE {
        FOR libName IN bootLibPhaseRoots(bandKey) { bootLibAddUnique(roots, libName). }
    }
    RETURN roots.
}

GLOBAL FUNCTION bootLibBand {
    PARAMETER band.
    RETURN bootLibResolve(bootLibBandRoots(band)).
}

GLOBAL FUNCTION bootLibBandForPhase {
    PARAMETER phaseName.
    PARAMETER defaultBand IS "".
    bootLibLoadSpec().
    LOCAL phaseKey IS phaseName:TOUPPER.
    IF phaseKey = "" { RETURN defaultBand. }
    FOR bandKey IN BOOT_LIB_BANDS:KEYS {
        FOR bandPhase IN BOOT_LIB_BANDS[bandKey] {
            IF bandPhase:TOUPPER = phaseKey { RETURN bandKey. }
        }
    }
    IF defaultBand <> "" { RETURN defaultBand. }
    RETURN phaseKey.
}

GLOBAL FUNCTION bootLibPhaseRoots {
    PARAMETER phaseName.
    bootLibLoadSpec().
    LOCAL roots IS LIST().
    FOR libName IN BOOT_LIB_PREAMBLE { bootLibAddUnique(roots, libName). }
    LOCAL phaseKey IS phaseName:TOUPPER.
    IF BOOT_LIB_PHASES:HASKEY(phaseKey) {
        FOR libName IN BOOT_LIB_PHASES[phaseKey] { bootLibAddUnique(roots, libName). }
    }
    RETURN roots.
}
