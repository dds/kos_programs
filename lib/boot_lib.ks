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
    FOR p IN LIST("1:/lib","1:/boot","1:/run","1:/craft","1:/roles") {
        IF NOT EXISTS(p) { CREATEDIR(p). }
    }
}

LOCAL FUNCTION _bootLooksLikeTargetToken {
    PARAMETER raw.
    RETURN BODYEXISTS(raw).
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
            SET targetName TO tokens[1].
            FROM { LOCAL i IS 2. } UNTIL i >= tokens:LENGTH STEP { SET i TO i + 1. } DO {
                payloadTypes:ADD(tokens[i]:TOUPPER).
            }
        } ELSE IF tokens:LENGTH >= 2 AND _bootLooksLikeTargetToken(tokens[1]) {
            SET targetName TO tokens[1].
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
    IF fileName:CONTAINS(".json") { RETURN fileName:SUBSTRING(0, fileName:LENGTH - 5). }
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
        "STATE", "LOGS", "FILES", "BOOT_LIB",
        "CONFIG", "RESUME", "dependencies"
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
            IF nm:CONTAINS(".json") {
                ids:ADD(nm:SUBSTRING(0, nm:LENGTH - 5)).
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
    LOCAL path_ IS "0:/missions/" + craftName + "/" + missionId + ".json".
    IF NOT EXISTS(path_) {
        PRINT "  Mission config not found: " + path_.
        RETURN FALSE.
    }
    LOCAL _cfg IS ADDONS:JSON:PARSE(OPEN(path_):READALL:STRING).
    FOR key IN _cfg:KEYS {
        LOCAL value IS _cfg[key].
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

GLOBAL FUNCTION bootIsLaunchStartPhase {
    PARAMETER phaseName.
    LOCAL phase IS phaseName.
    RETURN phase = "" OR phase = "PRELAUNCH" OR phase = "LAUNCH"
        OR phase = "FAIR" OR phase = "ANTS".
}

GLOBAL FUNCTION bootEnsureInitialPhase {
    PARAMETER seq.
    LOCAL phase IS stateGet("phase", "").
    IF (phase = "" OR phase:CONTAINS("MAIN")) AND seq:LENGTH > 0 {
        stateSet("phase", seq[0]).
    }
    RETURN stateGet("phase", "").
}

GLOBAL FUNCTION bootShouldResetMissionOnBoot {
    PARAMETER isEVA.
    IF isEVA { RETURN FALSE. }
    IF stateGet("reload_required", "false") = "true" { RETURN FALSE. }
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
        "reload_next_band", "secondary_active", "secondary_release_done",
        "zombie_scansat_active", "zombie_scansat_required_types"
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

GLOBAL FUNCTION bootCleanup {
    PARAMETER vehicleName.
    PARAMETER wantedLibs.
    LOCAL keepLibs IS LIST(
        "state", "logs", "boot_lib", "resume",
        "phases", "utils", "ui", "config", "dependencies"
    ).
    FOR lib IN wantedLibs {
        IF NOT bootLibArchiveOnly(lib)
                AND NOT keepLibs:CONTAINS(lib) { keepLibs:ADD(lib). }
    }

    LOCAL keepRoles IS LIST().
    IF CORE:TAG <> "" { keepRoles:ADD(CORE:TAG). }

    LOCAL beforeFree IS CORE:VOLUME:FREESPACE.
    LOCAL removed IS 0.
    SET removed TO removed + bootPruneDir("1:/lib", keepLibs).
    SET removed TO removed + bootPruneDir("1:/craft", LIST(vehicleName)).
    SET removed TO removed + bootPruneDir("1:/roles", keepRoles).
    SET removed TO removed + bootPruneDir("1:/cmd", LIST()).
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
// This stays deliberately small: dependencies.json is refreshed when
// available, then READJSON'd into lexicons/lists for the rest of the boot.
// ============================================================

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

GLOBAL FUNCTION bootLibSpec {
    RETURN ADDONS:JSON:PARSE(OPEN("1:/lib/dependencies.json"):READALL:STRING).
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
    PARAMETER deps.
    SET libName TO libName:TRIM.
    IF deps:HASKEY(libName) {
        FOR dep IN deps[libName] {
            bootLibAppendResolved(libs, dep, deps).
        }
    }
    bootLibAddUnique(libs, libName).
}

GLOBAL FUNCTION bootLibResolve {
    PARAMETER roots.
    LOCAL libs IS LIST().
    LOCAL spec IS bootLibSpec().
    LOCAL deps IS LEXICON().
    IF spec:HASKEY("libs") { SET deps TO spec["libs"]. }
    FOR libName IN roots {
        bootLibAppendResolved(libs, libName, deps).
    }
    RETURN libs.
}

GLOBAL FUNCTION bootLibRun {
    PARAMETER libName.
    IF BOOT_LIB_RAN:CONTAINS(libName) { RETURN. }
    bootLibSync(libName).
    RUNPATH("1:/lib/" + libName).
    PRINT("Loaded " + libName + "...").
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
    LOCAL spec IS bootLibSpec().
    bootLibLoadList(spec["preamble"]).
}

GLOBAL FUNCTION bootLibBandRoots {
    PARAMETER band.
    LOCAL spec IS bootLibSpec().
    LOCAL preamble IS LIST().
    LOCAL bands IS LEXICON().
    IF spec:HASKEY("preamble") { SET preamble TO spec["preamble"]. }
    IF spec:HASKEY("bands") { SET bands TO spec["bands"]. }
    LOCAL roots IS LIST().
    FOR libName IN preamble { bootLibAddUnique(roots, libName). }
    LOCAL bandKey IS band.
    IF bands:HASKEY(bandKey) {
        FOR phaseName IN bands[bandKey] {
            FOR libName IN bootLibPhaseRoots(phaseName, spec) { bootLibAddUnique(roots, libName). }
        }
    } ELSE {
        FOR libName IN bootLibPhaseRoots(bandKey, spec) { bootLibAddUnique(roots, libName). }
    }
    RETURN roots.
}

GLOBAL FUNCTION bootLibBand {
    PARAMETER band.
    RETURN bootLibResolve(bootLibBandRoots(band)).
}

GLOBAL FUNCTION bootLibBandPhases {
    PARAMETER band.
    LOCAL spec IS bootLibSpec().
    LOCAL bands IS LEXICON().
    IF spec:HASKEY("bands") { SET bands TO spec["bands"]. }
    LOCAL phases IS LIST().
    LOCAL bandKey IS band.
    IF bands:HASKEY(bandKey) {
        FOR phaseName IN bands[bandKey] {
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
    LOCAL spec IS bootLibSpec().
    LOCAL bands IS LEXICON().
    IF spec:HASKEY("bands") { SET bands TO spec["bands"]. }
    LOCAL phaseKey IS phaseName.
    IF phaseKey = "" { RETURN defaultBand. }
    FOR bandKey IN bands:KEYS {
        FOR bandPhase IN bands[bandKey] {
            IF bandPhase = phaseKey { RETURN bandKey. }
        }
    }
    IF defaultBand <> "" { RETURN defaultBand. }
    RETURN phaseKey.
}

GLOBAL FUNCTION bootLibPhaseRoots {
    PARAMETER phaseName.
    PARAMETER spec IS LEXICON().
    IF NOT spec:HASKEY("phases") AND NOT spec:HASKEY("preamble") {
        SET spec TO bootLibSpec().
    }
    LOCAL preamble IS LIST().
    LOCAL phases IS LEXICON().
    IF spec:HASKEY("preamble") { SET preamble TO spec["preamble"]. }
    IF spec:HASKEY("phases") { SET phases TO spec["phases"]. }
    LOCAL roots IS LIST().
    FOR libName IN preamble { bootLibAddUnique(roots, libName). }
    LOCAL phaseKey IS phaseName.
    IF phases:HASKEY(phaseKey) {
        FOR libName IN phases[phaseKey] { bootLibAddUnique(roots, libName). }
    }
    RETURN roots.
}

GLOBAL FUNCTION bootLibAllPhases {
    LOCAL spec IS bootLibSpec().
    IF spec:HASKEY("phases") { RETURN spec["phases"]:KEYS. }
    RETURN LIST().
}

// ============================================================
// Mission planning helpers
//
// The bulky sequence-to-library planner lives in preflight_planner.ks.
// Keep only tiny runtime helpers here.
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

GLOBAL FUNCTION bootCachedVehicleLibs {
    PARAMETER band IS "".
    IF SHIP:STATUS = "PRELAUNCH" { RETURN LIST(). }
    IF band <> "" AND stateGet("lib_band", "") <> band { RETURN LIST(). }
    RETURN missionListFromCsv(stateGet("lib_band_libs", "")).
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

GLOBAL FUNCTION missionPayloadsFromState {
    LOCAL raw IS stateGet("payloads", "").
    IF raw = "" { RETURN LIST(). }
    RETURN raw:SPLIT(",").
}

GLOBAL FUNCTION missionNormalizePayloadType {
    PARAMETER payloadName.
    LOCAL result IS payloadName.
    UNTIL result:LENGTH = 0 {
        LOCAL last IS result:SUBSTRING(result:LENGTH - 1, 1).
        IF last:MATCHESPATTERN("[0-9]") OR last = "-" {
            SET result TO result:SUBSTRING(0, result:LENGTH - 1).
        } ELSE {
            BREAK.
        }
    }
    RETURN result.
}

GLOBAL FUNCTION missionHasPayload {
    PARAMETER payloadName.
    FOR raw IN missionPayloadsFromState() {
        IF missionNormalizePayloadType(raw) = payloadName { RETURN TRUE. }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION missionHasLandingPayload {
    FOR raw IN missionPayloadsFromState() {
        LOCAL payloadType IS missionNormalizePayloadType(raw).
        IF payloadType = "LANDER" OR payloadType = "ASSISTLANDER"
                OR payloadType = "ROVER" OR payloadType = "ASSISTROVER" {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}


GLOBAL FUNCTION evaluate {
    PARAMETER expression.

    EXECUTE("global _evaluate_result is " + expression + ".").
    LOCAL result IS _evaluate_result.
    IF DEFINED _evaluate_result {
        UNSET _evaluate_result.
    }
    RETURN result.
}

GLOBAL FUNCTION evaluate_function {
    PARAMETER function_name.
    PARAMETER parameter_list.

    GLOBAL _exec__param_list IS parameter_list.
    LOCAL expression IS "".
    LOCAL separator IS "".
    LOCAL index IS 0.
    UNTIL index = parameter_list:LENGTH {
        SET expression TO expression + separator + "_exec__param_list[" + index + "]".
        SET separator TO ", ".
        SET index TO index + 1.
    }
    SET expression TO function_name + "(" + expression + ")".
    LOCAL result IS evaluate(expression).
    IF DEFINED _exec__param_list {
        UNSET _exec__param_list.
    }
    RETURN result.
}

// LIBS_EXTRA entries may be phase-scoped with lib@PHASE: the lib
// loads only while the mission has NOT yet passed PHASE in the
// sequence. A suborbital hop carries suborbit@SUBORBIT and sheds
// it (and its whole dependency chain) on any reboot after the
// arc — flight-found: unscoped extras made a DESCENT-phase boot
// load the union of every band at once, 433 bytes free, compile
// failed. Unknown phases keep the lib (safe).
GLOBAL FUNCTION missionExtraLibs {
    LOCAL out IS LIST().
    LOCAL seq IS missionListFromCsv(stateGet("mission_cfg_SEQUENCE", "")).
    LOCAL cur IS stateGet("phase", "").
    FOR entryRaw IN missionListFromCsv(stateGet("mission_cfg_LIBS_EXTRA", "")) {
        IF entryRaw:CONTAINS("@") {
            LOCAL parts IS entryRaw:SPLIT("@").
            LOCAL libName IS parts[0]:TRIM.
            LOCAL untilPhase IS parts[1]:TRIM.
            LOCAL curIdx IS -1.
            LOCAL phIdx IS -1.
            LOCAL i IS 0.
            UNTIL i >= seq:LENGTH {
                IF seq[i] = cur { SET curIdx TO i. }
                IF seq[i] = untilPhase { SET phIdx TO i. }
                SET i TO i + 1.
            }
            IF curIdx >= 0 AND phIdx >= 0 AND curIdx > phIdx {
                mLog("Extra lib " + libName + " dropped (past "
                    + untilPhase + ").").
            } ELSE {
                out:ADD(libName).
            }
        } ELSE {
            out:ADD(entryRaw).
        }
    }
    RETURN out.
}

GLOBAL FUNCTION missionLibs {
    PARAMETER fallbackLibs IS LIST().
    PARAMETER baseLibs IS LIST().
    LOCAL libs IS LIST().
    missionAppendUnique(libs, baseLibs).

    LOCAL configured IS missionListFromCsv(stateGet("mission_cfg_LIBS", "")).
    IF configured:LENGTH > 0 {
        missionAppendUnique(libs, bootLibResolve(configured)).
    } ELSE {
        missionAppendUnique(libs, bootLibResolve(fallbackLibs)).
    }

    missionAppendUnique(libs, bootLibResolve(missionExtraLibs())).
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
// Aircraft boot helpers — shared by all airplane craft scripts.
// These live here (preamble) because bootVehicleLibs() runs
// before the airplane library itself is loaded.
// ============================================================

GLOBAL FUNCTION airplaneSequenceFromState {
    PARAMETER defaultSeq.
    LOCAL raw IS stateGet("mission_cfg_SEQUENCE", "").
    IF raw <> "" { RETURN phaseListFromString(raw). }
    RETURN defaultSeq.
}

GLOBAL FUNCTION airplaneVehicleLibs {
    PARAMETER defaultSeq.
    PARAMETER baseLibs IS LIST("orbit", "airplane").
    LOCAL seq IS airplaneSequenceFromState(defaultSeq).
    LOCAL libs IS missionLibsForPhases(seq, baseLibs).
    IF missionHasPayload("SCIENCE") AND NOT libs:CONTAINS("science") {
        libs:ADD("science").
    }
    SET libs TO missionSequenceLibs(libs, baseLibs).
    stateSet("lib_band", "AIR").
    stateSet("lib_band_phase", stateGet("phase", seq[0])).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
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
    LOCAL roots IS LIST("phases").
    FOR lib IN baseDeps {
        missionAppendUnique(roots, LIST(lib)).
    }
    FOR phase IN phases {
        missionAppendUnique(roots, bootLibPhaseRoots(phase)).
    }
    RETURN bootLibResolve(roots).
}
