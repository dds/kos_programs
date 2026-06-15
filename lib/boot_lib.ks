// ============================================================
// boot_lib.ks - boot helpers and dependency expansion
// ============================================================

GLOBAL FUNCTION main {
    mLogWarn("Default empty main() called; no vehicle main loaded.").
    PRINT " ".
    PRINT "  DEFAULT MAIN".
    PRINT "  No vehicle main() was loaded.".
}

GLOBAL FUNCTION bootEnsureDirs {
    FOR p IN LIST("1:/lib","1:/boot","1:/run","1:/cmd","1:/craft","1:/roles") {
        IF NOT EXISTS(p) { CREATEDIR(p). }
    }
}

LOCAL FUNCTION _bootNormalizeTargetToken {
    PARAMETER raw.
    LOCAL t IS raw:TOUPPER.
    IF t = "MINIMUS" { RETURN "MINMUS". }
    RETURN t.
}

LOCAL FUNCTION _bootLooksLikeTargetToken {
    PARAMETER raw.
    LOCAL t IS _bootNormalizeTargetToken(raw).
    LOCAL knownTargets IS LIST("KERBIN", "MUN", "MINMUS", "MOHO", "EVE", "GILLY",
        "DUNA", "IKE", "DRES", "JOOL", "LAYTHE", "VALL", "TYLO",
        "BOP", "POL", "EELOO", "KERBOL").
    RETURN knownTargets:CONTAINS(t).
}

GLOBAL FUNCTION bootVehicleInfo {
    LOCAL isEVA IS SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA").
    LOCAL vehicleName IS "".
    LOCAL targetName IS "".
    LOCAL payloadTypes IS LIST().
    LOCAL sourceName IS SHIP:NAME.
    IF isEVA {
        SET vehicleName TO "EVA".
        SET targetName TO SHIP:BODY:NAME.
        PRINT "  EVA KERBAL DETECTED".
    } ELSE IF stateGet("vehicle", "") <> ""
            AND NOT stateGet("vehicle", ""):CONTAINS(" ")
            AND SHIP:STATUS <> "PRELAUNCH" {
        SET vehicleName TO stateGet("vehicle", "").
        SET targetName TO stateGet("target", "KERBIN").
        LOCAL rawPayloads IS stateGet("payloads", "").
        IF rawPayloads <> "" {
            FOR p IN rawPayloads:SPLIT(",") {
                LOCAL trimmedPayload IS p:TRIM.
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
            SET targetName TO _bootNormalizeTargetToken(tokens[1]).
            FROM { LOCAL i IS 2. } UNTIL i >= tokens:LENGTH STEP { SET i TO i + 1. } DO {
                payloadTypes:ADD(tokens[i]:TOUPPER).
            }
        } ELSE IF tokens:LENGTH >= 2 AND _bootLooksLikeTargetToken(tokens[1]) {
            SET targetName TO _bootNormalizeTargetToken(tokens[1]).
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

GLOBAL FUNCTION bootBaseName {
    PARAMETER fileName.
    IF fileName:CONTAINS(".ksm") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF fileName:CONTAINS(".ks") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 3). }
    IF fileName:CONTAINS(".cfg") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    IF fileName:CONTAINS(".txt") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 4). }
    RETURN fileName.
}

GLOBAL FUNCTION bootArchiveOnlyLibs {
    LOCAL out IS LIST().
    IF DEFINED BOOT_ARCHIVE_ONLY {
        FOR libName IN BOOT_ARCHIVE_ONLY {
            IF libName <> "" AND NOT out:CONTAINS(libName) {
                out:ADD(libName).
            }
        }
    }
    RETURN out.
}

GLOBAL FUNCTION bootLibArchiveOnly {
    PARAMETER libName.
    LOCAL archiveOnly IS bootArchiveOnlyLibs().
    RETURN archiveOnly:CONTAINS(libName).
}

GLOBAL FUNCTION bootPruneLibs {
    PARAMETER wantedLibs.
    LOCAL keep IS LIST(
        "STATE", "LOGS", "FILES", "MISSION_PLAN", "BOOT_LIB",
        "DEPENDENCIES",
        "CONFIG", "RESUME"
    ).
    FOR lib IN wantedLibs {
        IF NOT bootLibArchiveOnly(lib)
                AND NOT keep:CONTAINS(lib) { keep:ADD(lib). }
    }
    LOCAL startPath IS PATH().
    LOCAL items IS LIST().
    CD("1:/lib").
    LIST FILES IN items.
    CD(startPath).
    FOR item IN items {
        IF item:ISFILE {
            LOCAL base IS bootBaseName(item:NAME).
            IF NOT keep:CONTAINS(base) {
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
            IF nm:CONTAINS(".cfg") {
                ids:ADD(nm:SUBSTRING(0, nm:LENGTH - 4)).
            }
        }
    }
    RETURN ids.
}

GLOBAL FUNCTION bootApplyMissionConfig {
    PARAMETER craftName.
    PARAMETER missionId.
    PARAMETER hasLink.
    IF missionId = "" { RETURN FALSE. }
    LOCAL path_ IS "0:/missions/" + craftName + "/" + missionId + ".cfg".
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
                    LOCAL key IS parts[0]:TRIM.
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
                        stateSet("target", value).
                    } ELSE IF key = "PAYLOADS" {
                        stateSet("payloads", value).
                    } ELSE IF key = "MISSION_TYPE" {
                        stateSet("mission_type", value).
                    }
                }
            }
        }
    }
    IF stateGet("mission_id", "") = "" { stateSet("mission_id", missionId). }
    PRINT "  Mission: " + stateGet("mission_name", missionId).
    PRINT "  Target:  " + stateGet("target", "KERBIN").
    PRINT "  Payload: " + stateGet("payloads", "").
    printStorageStatus().
    RETURN TRUE.
}

GLOBAL FUNCTION bootMissionConfig {
    PARAMETER craftName.
    PARAMETER hasLink.
    LOCAL missionId IS stateGet("mission_id", "").
    IF missionId = "" AND hasLink {
        LOCAL ids IS bootMissionConfigIds(craftName, hasLink).
        IF ids:LENGTH > 0 {
            IF NOT bootCheckManualKey() {
                PRINT " ".
                PRINT "  >> Press any key for MANUAL mode (2s)".
                LOCAL manualStart IS TIME:SECONDS.
                WAIT UNTIL TIME:SECONDS > manualStart + 2
                    OR TERMINAL:INPUT:HASCHAR.
                bootCheckManualKey().
            }
            IF bootCheckManualKey() {
                PRINT "  Mission selection skipped (manual mode).".
            } ELSE {
                // The picker is its own lib — only fresh pad boots
                // pay for it (no link = no profiles to list anyway).
                bootLibRun("boot_picker").
                SET missionId TO bootSelectMissionId(craftName, hasLink).
            }
        }
    }
    IF missionId <> "" {
        bootApplyMissionConfig(craftName, missionId, hasLink).
    }
}

GLOBAL FUNCTION bootNormalizePhaseName {
    PARAMETER phaseName.
    RETURN phaseName.
}

GLOBAL FUNCTION bootIsLaunchStartPhase {
    PARAMETER phaseName.
    LOCAL phase IS bootNormalizePhaseName(phaseName).
    RETURN phase = "" OR phase = "PRELAUNCH" OR phase = "LAUNCH"
        OR phase = "FAIR" OR phase = "ANTS".
}

GLOBAL FUNCTION bootEnsureInitialPhase {
    PARAMETER seq.
    LOCAL phase IS bootNormalizePhaseName(stateGet("phase", "")).
    IF (phase = "" OR phase:CONTAINS("MAIN")) AND seq:LENGTH > 0 {
        stateSet("phase", bootNormalizePhaseName(seq[0])).
    }
    RETURN stateGet("phase", "").
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
    LOCAL manualMode IS bootCheckManualKey().
    IF NOT manualMode {
        PRINT " ".
        PRINT "  >> Press any key for MANUAL mode (2s)".
        LOCAL overrideStart IS TIME:SECONDS.
        WAIT UNTIL TIME:SECONDS > overrideStart + 2 OR TERMINAL:INPUT:HASCHAR.
        IF TERMINAL:INPUT:HASCHAR {
            TERMINAL:INPUT:GETCHAR().
            SET manualMode TO TRUE.
        }
    }
    IF NOT manualMode {
        LOCAL phase IS stateGet("phase", "").
        IF phase = "DONE" {
            PRINT " ".
            PRINT "  MISSION COMPLETE. MANUAL MODE.".
            mLog("Reboot after DONE - manual mode.").
            // Returning to a parked ship from the tracking
            // station: re-acquire the solar attitude and hold
            // (cached axis — quick aim, no search).
            IF SHIP:STATUS = "ORBITING" AND BOOT_LIB_RAN:CONTAINS("solar") {
                orientForSolar().
            }
        } ELSE IF phase = "ABORT" {
            IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
                PRINT "  ABORT DETECTED - entering recovery mode.".
                mLog("Abort detected at reboot - loading recovery.").
                recoveryMode().
            } ELSE {
                // Still falling: resume the phase machine so the
                // ABORT phase re-verifies chutes and monitors the
                // descent (recoveryMode is the landed/idle half).
                PRINT "  ABORT IN PROGRESS - resuming abort descent.".
                mLog("Abort in progress at reboot - resuming ABORT phase.").
                resumeMission().
            }
        } ELSE {
            PRINT "  RESUMING >> " + phase.
            mLog("Resuming mission from phase: " + phase).
            resumeMission().
        }
    }
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
    }
}

// ── Generalized cleanup ──────────────────────────────────────
// These functions replace craft-specific cleanup (e.g. FR3's
// _fr3EmergencyCleanup) with reusable boot-level utilities.
// Called from boot.ks when a craft script sets BOOT_CLEANUP.

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
            LOCAL base IS bootBaseName(item:NAME).
            IF NOT keepNames:CONTAINS(base) {
                DELETEPATH(dirPath + "/" + item:NAME).
                SET removed TO removed + 1.
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
    IF EXISTS("1:/run") {
        LOCAL startPath IS PATH().
        LOCAL items IS LIST().
        CD("1:/run").
        LIST FILES IN items.
        CD(startPath).
        FOR item IN items {
            IF item:ISFILE AND (item:NAME:CONTAINS(".LOG") OR item:NAME:CONTAINS(".log")) {
                DELETEPATH("1:/run/" + item:NAME).
                SET removed TO removed + 1.
            }
        }
    }
    IF EXISTS("1:/run/log_path.state") {
        DELETEPATH("1:/run/log_path.state").
        SET removed TO removed + 1.
    }
    RETURN removed.
}

// ============================================================
// Offline operator commands (CMD rows in dependencies.txt)
// ============================================================

// bootCmdsForSequence — union of the offline commands declared
// for every phase of the current mission sequence. Falls back to
// the current phase when no sequence is configured.
GLOBAL FUNCTION bootCmdsForSequence {
    bootLibLoadSpec().
    LOCAL cmds IS LIST().
    LOCAL seqRaw IS stateGet("mission_cfg_SEQUENCE", "").
    LOCAL phases IS LIST().
    IF seqRaw <> "" {
        FOR p IN seqRaw:SPLIT(",") {
            IF p:TRIM <> "" { phases:ADD(p:TRIM). }
        }
    } ELSE {
        phases:ADD(stateGet("phase", "")).
    }
    FOR phaseName IN phases {
        IF BOOT_LIB_CMDS:HASKEY(phaseName) {
            FOR cmdName IN BOOT_LIB_CMDS[phaseName] {
                IF NOT cmds:CONTAINS(cmdName) { cmds:ADD(cmdName). }
            }
        }
    }
    RETURN cmds.
}

// bootCmdSync — install the mission's offline commands on the
// local volume (compiled, so PARAMETER blocks still work). Run
// with: RUNPATH("1:/cmd/<name>").  No-op without a KSC link.
GLOBAL FUNCTION bootCmdSync {
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN. }
    LOCAL cmds IS bootCmdsForSequence().
    IF cmds:LENGTH = 0 { RETURN. }
    IF NOT EXISTS("1:/cmd") { CREATEDIR("1:/cmd"). }
    FOR cmdName IN cmds {
        LOCAL src IS "0:/cmd/" + cmdName + ".ks".
        IF EXISTS(src) {
            COMPILE src TO "1:/cmd/" + cmdName + ".ksm".
        } ELSE {
            PRINT "  WARN: offline cmd " + cmdName + " missing in 0:/cmd".
        }
    }
    PRINT "  CMDS local: " + cmds:JOIN(", ") + " (RUNPATH 1:/cmd/<name>)".
}

GLOBAL FUNCTION bootCleanup {
    PARAMETER vehicleName.
    PARAMETER wantedLibs.
    PARAMETER keepCmds IS LIST().
    LOCAL keepLibs IS LIST(
        "state", "logs", "boot_lib", "resume", "dependencies",
        "phases", "utils", "ui", "config"
    ).
    FOR lib IN wantedLibs {
        IF NOT bootLibArchiveOnly(lib)
                AND NOT keepLibs:CONTAINS(lib) { keepLibs:ADD(lib). }
    }

    // Never prune the mission's offline commands — at a field
    // strip with no radio they are the only way to retask.
    FOR cmdName IN bootCmdsForSequence() {
        IF NOT keepCmds:CONTAINS(cmdName) { keepCmds:ADD(cmdName). }
    }

    LOCAL keepRoles IS LIST().
    IF CORE:TAG <> "" { keepRoles:ADD(CORE:TAG). }

    LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
    LOCAL removed IS 0.
    SET removed TO removed + bootPruneDir("1:/lib", keepLibs).
    SET removed TO removed + bootPruneDir("1:/craft", LIST(vehicleName)).
    SET removed TO removed + bootPruneDir("1:/roles", keepRoles).
    SET removed TO removed + bootPruneDir("1:/cmd", keepCmds).
    SET removed TO removed + bootPruneDir("1:/missions/" + vehicleName, LIST()).
    IF EXISTS("1:/zombie") {
        DELETEPATH("1:/zombie").
        SET removed TO removed + 1.
    }
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
GLOBAL BOOT_LIB_CMDS IS LEXICON().
GLOBAL BOOT_LIB_PREAMBLE IS LIST().
GLOBAL BOOT_LIB_LOADED IS FALSE.
GLOBAL BOOT_LIB_RAN IS LIST().

// Manual-mode request: any keypress noticed at ANY boot stage
// (usually queued before boot even starts) flags manual mode —
// checked before the mission picker so the menu never draws,
// and again at the resume gate.
GLOBAL BOOT_MANUAL_REQUESTED IS FALSE.

GLOBAL FUNCTION bootCheckManualKey {
    IF NOT BOOT_MANUAL_REQUESTED AND TERMINAL:INPUT:HASCHAR {
        TERMINAL:INPUT:GETCHAR().
        SET BOOT_MANUAL_REQUESTED TO TRUE.
        PRINT "  MANUAL MODE queued (keypress).".
    }
    RETURN BOOT_MANUAL_REQUESTED.
}

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
                    IF keys:LENGTH >= 2 AND keys[0] = "LIB" {
                        LOCAL libName IS keys[1]:TRIM.
                        _bootLibApplyValues(BOOT_LIB_DEPS, libName, _bootLibLineValues(rhs), op).
                    } ELSE IF keys:LENGTH >= 1 AND keys[0] = "PREAMBLE" {
                        LOCAL preambleTable IS LEXICON("PREAMBLE", BOOT_LIB_PREAMBLE).
                        _bootLibApplyValues(preambleTable, "PREAMBLE", _bootLibLineValues(rhs), op).
                        SET BOOT_LIB_PREAMBLE TO preambleTable["PREAMBLE"].
                    } ELSE IF keys:LENGTH >= 2 AND keys[0] = "BAND" {
                        LOCAL bandKey IS keys[1].
                        _bootLibApplyValues(BOOT_LIB_BANDS, bandKey, _bootLibLineValues(rhs), op).
                    } ELSE IF keys:LENGTH >= 2 AND keys[0] = "PHASE" {
                        LOCAL phaseIx IS 1.
                        UNTIL phaseIx >= keys:LENGTH {
                            LOCAL phaseName IS keys[phaseIx].
                            _bootLibApplyValues(BOOT_LIB_PHASES, phaseName, _bootLibLineValues(rhs), op).
                            SET phaseIx TO phaseIx + 1.
                        }
                    } ELSE IF keys:LENGTH >= 2 AND keys[0] = "CMD" {
                        // CMD <phase>[, <phase>...] = <cmd>[, <cmd>...]
                        // Operator commands a phase may need OFFLINE (no
                        // KSC link), installed to 1:/cmd at boot.
                        LOCAL cmdIx IS 1.
                        UNTIL cmdIx >= keys:LENGTH {
                            LOCAL cmdPhase IS keys[cmdIx].
                            _bootLibApplyValues(BOOT_LIB_CMDS, cmdPhase, _bootLibLineValues(rhs), op).
                            SET cmdIx TO cmdIx + 1.
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
    SET libName TO libName:TRIM.
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
    } ELSE IF HOMECONNECTION:ISCONNECTED AND EXISTS(archive_) {
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
        IF bootLibArchiveOnly(libName) {
            IF EXISTS(dstKsm) { DELETEPATH(dstKsm). }
            IF EXISTS(dst) { DELETEPATH(dst). }
            RETURN.
        }
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
    LOCAL bandKey IS band.
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

GLOBAL FUNCTION bootLibBandPhases {
    PARAMETER band.
    bootLibLoadSpec().
    LOCAL phases IS LIST().
    LOCAL bandKey IS band.
    IF BOOT_LIB_BANDS:HASKEY(bandKey) {
        FOR phaseName IN BOOT_LIB_BANDS[bandKey] {
            phases:ADD(phaseName).
        }
    } ELSE IF bandKey <> "" {
        phases:ADD(bandKey).
    }
    RETURN phases.
}

GLOBAL FUNCTION bootLibBandForPhase {
    PARAMETER phaseName.
    PARAMETER defaultBand IS "".
    bootLibLoadSpec().
    LOCAL phaseKey IS bootNormalizePhaseName(phaseName).
    IF phaseKey = "" { RETURN defaultBand. }
    FOR bandKey IN BOOT_LIB_BANDS:KEYS {
        FOR bandPhase IN BOOT_LIB_BANDS[bandKey] {
            IF bandPhase = phaseKey { RETURN bandKey. }
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
    LOCAL phaseKey IS bootNormalizePhaseName(phaseName).
    IF BOOT_LIB_PHASES:HASKEY(phaseKey) {
        FOR libName IN BOOT_LIB_PHASES[phaseKey] { bootLibAddUnique(roots, libName). }
    }
    RETURN roots.
}
