// ============================================================
// boot_lib.ks - boot helpers and dependency expansion
// ============================================================

@CLOBBERBUILTINS ON.

// --- Config defaults owned by this file ---
GLOBAL MISSION_ID IS "".
GLOBAL MISSION_NAME IS "".
GLOBAL MISSION_TYPE IS "".
GLOBAL TARGET_ IS "".
GLOBAL PAYLOADS IS LIST().
GLOBAL SEQUENCE IS LIST().
GLOBAL LIBS IS LIST().
GLOBAL LIBS_EXTRA IS LIST().
GLOBAL PROGRESSIVE_RELOAD IS 0.
GLOBAL RENDEZVOUS_TARGET IS "".
GLOBAL ASTEROID_TARGET IS "".
GLOBAL SCANSAT_RELEASE_AFTER_CAPTURE IS 0.
GLOBAL REENTRY_PE IS 30000.

GLOBAL FUNCTION main {
    mLogWarn("Default empty main() called; no vehicle main loaded.").
    PRINT " ".
    PRINT "  DEFAULT MAIN".
    PRINT "  No vehicle main() was loaded.".
}

GLOBAL FUNCTION bootEnsureDirs {
    FOR p IN LIST("1:/lib","1:/boot","1:/run","1:/craft","1:/roles","1:/missions","1:/configs") {
        IF NOT EXISTS(p) { CREATEDIR(p). }
    }
}

LOCAL FUNCTION _bltt {
    PARAMETER raw.
    RETURN BODYEXISTS(raw).
}

GLOBAL FUNCTION bootVehicleInfo {
    LOCAL isEVA IS SHIP:ROOTPART:NAME:CONTAINS("kerbalEVA").
    LOCAL vn IS "".
    LOCAL tn IS "".
    LOCAL pts IS LIST().
    LOCAL sn IS SHIP:NAME.
    IF isEVA {
        SET vn TO "EVA".
        SET tn TO SHIP:BODY:NAME.
        PRINT "  EVA KERBAL DETECTED".
    } ELSE IF stateGet("vehicle", "") <> ""
            AND NOT stateGet("vehicle", ""):CONTAINS(" ")
            AND SHIP:STATUS <> "PRELAUNCH" {
        SET vn TO stateGet("vehicle", "").
        SET tn TO getTarget().
        LOCAL rps IS stateGet("payloads", LIST()).
        IF rps:LENGTH > 0 {
            FOR p IN rps {
                LOCAL tp IS p:TRIM.
                IF tp <> "" { pts:ADD(tp). }
            }
        }
    } ELSE {
        IF stateGet("vessel_name", "") = "" OR SHIP:STATUS = "PRELAUNCH" {
            stateSet("vessel_name", SHIP:NAME).
        } ELSE {
            SET sn TO stateGet("vessel_name", SHIP:NAME).
        }
        LOCAL stn IS sn:CONTAINS("-").
        LOCAL rts IS sn:SPLIT("-").
        IF NOT stn { SET rts TO sn:SPLIT(" "). }
        LOCAL tks IS LIST().
        FOR t IN rts {
            LOCAL trimmed IS t:TRIM.
            IF trimmed <> "" { tks:ADD(trimmed). }
        }
        IF tks:LENGTH > 0 {
            SET vn TO tks[0].
        } ELSE {
            SET vn TO "UNKNOWN".
        }
        IF stn AND tks:LENGTH >= 2 {
            SET tn TO tks[1].
            FROM { LOCAL i IS 2. } UNTIL i >= tks:LENGTH STEP { SET i TO i + 1. } DO {
                pts:ADD(tks[i]:TOUPPER).
            }
        } ELSE IF tks:LENGTH >= 2 AND _bltt(tks[1]) {
            SET tn TO tks[1].
            FROM { LOCAL i IS 2. } UNTIL i >= tks:LENGTH STEP { SET i TO i + 1. } DO {
                pts:ADD(tks[i]:TOUPPER).
            }
        } ELSE {
            SET tn TO "KERBIN".
        }
    }
    IF stateGet("vessel_name", "") = "" OR SHIP:STATUS = "PRELAUNCH" {
        stateSet("vessel_name", SHIP:NAME).
    }
    RETURN LEXICON(
        "IS_EVA", isEVA,
        "VEHICLE", vn,
        "TARGET", tn,
        "PAYLOADS", pts
    ).
}

GLOBAL FUNCTION bootResolveScript {
    PARAMETER name.
    PARAMETER dirs.
    PARAMETER hl.
    IF hl {
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

GLOBAL FUNCTION bootArchivePath {
    PARAMETER sp_.
    IF sp_:CONTAINS("/") {
        RETURN "0:/" + sp_ + ".ks".
    }
    RETURN "0:/lib/" + sp_ + ".ks".
}

GLOBAL FUNCTION bootCorePath {
    PARAMETER sp_.
    IF sp_:CONTAINS("/") {
        RETURN "1:/" + sp_.
    }
    RETURN "1:/lib/" + sp_.
}

GLOBAL FUNCTION bootEnsureScriptDir {
    PARAMETER sp_.
    IF NOT sp_:CONTAINS("/") { RETURN. }
    LOCAL parts IS sp_:SPLIT("/").
    LOCAL dp IS "1:/" + parts[0].
    IF NOT EXISTS(dp) { CREATEDIR(dp). }
}

GLOBAL FUNCTION bootCompiledPath {
    PARAMETER sp_.
    RETURN bootCorePath(sp_) + ".ksm".
}

GLOBAL FUNCTION bootBaseName {
    PARAMETER fn.
    IF fn:CONTAINS(".ksm") { RETURN fn:SUBSTRING(0, fn:LENGTH - 4). }
    IF fn:CONTAINS(".ks") { RETURN fn:SUBSTRING(0, fn:LENGTH - 3). }
    RETURN fn.
}

GLOBAL FUNCTION bootArchiveOnlyLibs {
    LOCAL out IS LIST().
    FOR ln IN LIST(
        "xfer_plan",
        "maneuver_transfer",
        "maneuver_targeting",
        "maneuver_intersystem",
        "lambert",
        "lib_bplane_math"
    ) {
        IF NOT out:CONTAINS(ln) { out:ADD(ln). }
    }
    IF DEFINED BOOT_ARCHIVE_ONLY {
        FOR ln IN BOOT_ARCHIVE_ONLY {
            IF ln <> "" AND NOT out:CONTAINS(ln) {
                out:ADD(ln).
            }
        }
    }
    RETURN out.
}

GLOBAL FUNCTION bootLibArchiveOnly {
    PARAMETER ln.
    LOCAL ao IS bootArchiveOnlyLibs().
    RETURN ao:CONTAINS(ln).
}

GLOBAL FUNCTION bootMissionConfigIds {
    PARAMETER cn.
    PARAMETER hl.
    LOCAL ids IS LIST().
    LOCAL ad IS "0:/missions/" + cn.
    IF NOT hl OR NOT EXISTS(ad) { RETURN ids. }
    LOCAL sp IS PATH().
    LOCAL items IS LIST().
    CD(ad).
    LIST FILES IN items.
    CD(sp).
    FOR item IN items {
        IF item:ISFILE {
            LOCAL nm IS item:NAME.
            IF nm:CONTAINS(".ks") {
                ids:ADD(nm:SUBSTRING(0, nm:LENGTH - 3)).
            }
        }
    }
    RETURN ids.
}

GLOBAL FUNCTION bootCachedMissionConfigIds {
    PARAMETER cn.
    LOCAL ids IS LIST().
    LOCAL cd_ IS "1:/missions/" + cn.
    IF NOT EXISTS(cd_) { RETURN ids. }
    LOCAL sp IS PATH().
    LOCAL items IS LIST().
    CD(cd_).
    LIST FILES IN items.
    CD(sp).
    FOR item IN items {
        IF item:ISFILE {
            LOCAL nm IS item:NAME.
            IF nm:CONTAINS(".ks") {
                ids:ADD(nm:SUBSTRING(0, nm:LENGTH - 3)).
            }
        }
    }
    RETURN ids.
}

GLOBAL FUNCTION bootApplyMissionConfig {
    PARAMETER cn.
    PARAMETER mid.
    PARAMETER hl.
    IF mid = "" { RETURN FALSE. }
    // Persist the selected profile before any bulky copy/profile work.
    // If storage runs out later, the next boot can still recover intent.
    stateSet("mission_id", mid).
    LOCAL ap IS "0:/missions/" + cn + "/" + mid + ".ks".
    LOCAL cd_ IS "1:/missions/" + cn.
    LOCAL cp IS cd_ + "/" + mid + ".ks".
    IF hl AND EXISTS(ap) {
        IF NOT EXISTS("1:/missions") { CREATEDIR("1:/missions"). }
        IF NOT EXISTS(cd_) { CREATEDIR(cd_). }
        COPYPATH(ap, cp).
    }
    LOCAL path_ IS cp.
    IF NOT EXISTS(path_) {
        IF hl AND EXISTS(ap) {
            SET path_ TO ap.
        } ELSE {
            PRINT "  Mission config not found: " + path_.
            RETURN FALSE.
        }
    }
    RUNPATH(path_).
    applyKnownMissionState().
    IF MISSION_ID <> "" { stateSet("mission_id", MISSION_ID). }
    IF stateGet("mission_id", "") = "" { stateSet("mission_id", mid). }
    IF MISSION_NAME <> "" { stateRemove("mission_name"). }
    IF TARGET_ <> "" {
        stateRemove("target").
        getTarget().
    }
    IF PAYLOADS:LENGTH > 0 { stateRemove("payloads"). }
    IF MISSION_TYPE <> "" { stateRemove("mission_type"). }
    IF MISSION_NAME <> "" {
        PRINT "  Mission: " + MISSION_NAME.
    } ELSE {
        PRINT "  Mission: " + stateGet("mission_id", mid).
    }
    IF getTarget("") <> "" { PRINT "  Target:  " + getTarget(""). }
    IF PAYLOADS:LENGTH > 0 { PRINT "  Payload: " + PAYLOADS. }
    printStorageStatus().
    RETURN TRUE.
}

GLOBAL FUNCTION bootMissionConfig {
    PARAMETER cn.
    PARAMETER hl.
    LOCAL mid IS stateGet("mission_id", "").
    IF mid = "" AND SHIP:STATUS <> "PRELAUNCH" {
        LOCAL cachedIds IS bootCachedMissionConfigIds(cn).
        IF cachedIds:LENGTH = 1 {
            SET mid TO cachedIds[0].
            stateSet("mission_id", mid).
            PRINT "  Mission recovered from cache: " + mid + ".".
        } ELSE IF cachedIds:LENGTH > 1 {
            PRINT "  WARN: mission state missing; multiple cached profiles.".
            PRINT "  Use cmd/setphase.ks to reattach manually.".
        }
    }
    IF mid = "" AND hl AND SHIP:STATUS = "PRELAUNCH" {
        LOCAL ids IS bootMissionConfigIds(cn, hl).
        IF ids:LENGTH > 0 {
            IF NOT bootCheckManualKey() {
                PRINT " ".
                PRINT "  >> Press any key for MANUAL mode (2s)".
                LOCAL ms IS TIME:SECONDS.
                WAIT UNTIL TIME:SECONDS > ms + 2
                    OR TERMINAL:INPUT:HASCHAR.
                bootCheckManualKey().
            }
            IF bootCheckManualKey() {
                PRINT "  Mission selection skipped (manual mode).".
            } ELSE {
                // The picker is its own lib — only fresh pad boots
                // pay for it (no link = no profiles to list anyway).
                bootLibSync("boot_picker").
                RUNONCEPATH("1:/lib/boot_picker").
                SET mid TO bootSelectMissionId(cn, hl).
                IF mid <> "" { stateSet("mission_id", mid). }
            }
        }
    }
    IF mid <> "" {
        bootApplyMissionConfig(cn, mid, hl).
    }
}

GLOBAL FUNCTION bootIsLaunchStartPhase {
    PARAMETER pn.
    LOCAL phase IS pn.
    RETURN phase = "" OR phase = "PRELAUNCH" OR phase = "LAUNCH"
        OR phase = "FAIR" OR phase = "ANTS".
}

GLOBAL FUNCTION bootEnsureInitialPhase {
    PARAMETER seq.
    LOCAL phase IS stateGet("phase", "").
    IF (phase = "" OR phase:CONTAINS("MAIN")) AND seq:LENGTH > 0 {
        LOCAL initialPhase IS seq[0].
        IF phase = "" AND SHIP:STATUS = "ORBITING"
                AND SHIP:BODY:NAME = "Kerbin" {
            FROM { LOCAL i IS 0. } UNTIL i >= seq:LENGTH STEP { SET i TO i + 1. } DO {
                IF seq[i] = "PARK" AND i + 1 < seq:LENGTH {
                    SET initialPhase TO seq[i + 1].
                    mLogWarn("Recovered blank phase in Kerbin orbit; starting at "
                        + initialPhase + " after PARK.").
                    BREAK.
                }
            }
        }
        stateSet("phase", initialPhase).
    }
    RETURN stateGet("phase", "").
}

GLOBAL FUNCTION bootShouldResetMissionOnBoot {
    PARAMETER isEVA.
    IF isEVA { RETURN FALSE. }
    IF stateGet("reload_required", "false") = "true" { RETURN FALSE. }
    IF SHIP:STATUS = "PRELAUNCH" {
        RETURN stateGetNum("boot_count", 0) = 0
            OR stateGet("mission_id", "") = "".
    }
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
    PARAMETER vn.
    PARAMETER tn.
    PARAMETER pts.
    missionOverrideClear().
    FOR key IN LIST(
        "mission_id", "mission_name", "phase", "fairing_deployed",
        "lib_band", "lib_band_phase", "lib_band_libs",
        "reload_required", "reload_reason", "reload_next_phase",
        "reload_next_band", "secondary_active", "secondary_release_done",
        "zombie_scansat_active", "zombie_scansat_required_types",
        "launch_time", "launch_site_lat", "launch_site_lng",
        "launch_vs_nonpos_logged", "log_flight_stamp", "boot_log_count"
    ) {
        stateRemove(key).
    }
    IF EXISTS("1:/run") {
        bootDeleteLogFiles("1:/run").
    }
    stateSet("vehicle", vn).
    stateSet("target", tn).
    stateSet("payloads", pts).
    PRINT "  Mission selection reset for prelaunch.".
    mLog("Mission selection reset before launch.").
}

GLOBAL FUNCTION bootResumeOrManual {
    PARAMETER hl.
    LOCAL mm IS bootCheckManualKey().
    IF NOT mm {
        PRINT " ".
        PRINT "  >> Press any key for MANUAL mode (2s)".
        LOCAL os IS TIME:SECONDS.
        WAIT UNTIL TIME:SECONDS > os + 2 OR TERMINAL:INPUT:HASCHAR.
        IF TERMINAL:INPUT:HASCHAR {
            TERMINAL:INPUT:GETCHAR().
            SET mm TO TRUE.
        }
    }
    IF NOT mm {
        LOCAL phase IS stateGet("phase", "").
        IF phase = "DONE" {
            PRINT " ".
            PRINT "  MISSION COMPLETE. MANUAL MODE.".
            mLog("Reboot after DONE - manual mode.").
            // Returning to a parked ship from the tracking
            // station: re-acquire the solar attitude and hold
            // (cached axis — quick aim, no search).
            IF SHIP:STATUS = "ORBITING" AND PHASES_HAS_SOLAR {
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
    PARAMETER dp.
    PARAMETER kn.
    LOCAL rm IS 0.
    IF NOT EXISTS(dp) { RETURN rm. }
    LOCAL sp IS PATH().
    LOCAL items IS LIST().
    CD(dp).
    LIST FILES IN items.
    CD(sp).
    FOR item IN items {
        IF item:ISFILE {
            LOCAL base IS bootBaseName(item:NAME).
            IF NOT kn:CONTAINS(base) {
                DELETEPATH(dp + "/" + item:NAME).
                SET rm TO rm + 1.
            }
        }
    }
    RETURN rm.
}

GLOBAL FUNCTION bootSweepLogs {
    PARAMETER dirPath.
    PARAMETER archiveDir.
    PARAMETER linked.
    LOCAL rm IS 0.
    LOCAL oldLogPath IS "".
    IF NOT EXISTS(dirPath) { RETURN rm. }

    IF linked AND archiveDir <> "" {
        LOCAL archiveParts IS archiveDir:SPLIT("/").
        LOCAL archiveBuildPath IS archiveParts[0].
        FROM { LOCAL archiveIndex IS 1. }
                UNTIL archiveIndex >= archiveParts:LENGTH
                STEP { SET archiveIndex TO archiveIndex + 1. } DO {
            IF archiveParts[archiveIndex] <> "" {
                SET archiveBuildPath TO archiveBuildPath + "/" + archiveParts[archiveIndex].
                IF NOT EXISTS(archiveBuildPath) {
                    CREATEDIR(archiveBuildPath).
                }
            }
        }
    }

    IF dirPath = "1:/run" AND EXISTS("1:/run/log_path.state") {
        SET oldLogPath TO OPEN("1:/run/log_path.state"):READALL:STRING:TRIM.
    }

    LOCAL sp IS PATH().
    LOCAL items IS LIST().
    CD(dirPath).
    LIST FILES IN items.
    CD(sp).
    FOR item IN items {
        LOCAL itemPath IS dirPath + "/" + item:NAME.
        IF item:ISFILE {
            IF item:NAME:CONTAINS(".LOG") OR item:NAME:CONTAINS(".log")
                    OR item:NAME = "log_path.state" {
                IF linked AND archiveDir <> "" {
                    LOCAL archivePath IS archiveDir + "/" + item:NAME.
                    IF EXISTS(archivePath) { DELETEPATH(archivePath). }
                    COPYPATH(itemPath, archivePath).
                }
                DELETEPATH(itemPath).
                SET rm TO rm + 1.
            }
        } ELSE {
            LOCAL childArchive IS archiveDir + "/" + item:NAME.
            IF linked AND archiveDir <> "" AND NOT EXISTS(childArchive) {
                CREATEDIR(childArchive).
            }
            SET rm TO rm + bootSweepLogs(itemPath, childArchive, linked).
        }
    }

    IF oldLogPath <> "" AND EXISTS(oldLogPath) {
        IF linked AND archiveDir <> "" {
            LOCAL oldParts IS oldLogPath:SPLIT("/").
            LOCAL oldName IS oldParts[oldParts:LENGTH - 1].
            LOCAL oldArchivePath IS archiveDir + "/" + oldName.
            IF EXISTS(oldArchivePath) { DELETEPATH(oldArchivePath). }
            COPYPATH(oldLogPath, oldArchivePath).
        }
        DELETEPATH(oldLogPath).
        SET rm TO rm + 1.
    }

    RETURN rm.
}

GLOBAL FUNCTION bootDeleteLogFiles {
    PARAMETER dp.
    RETURN bootSweepLogs(dp, "", FALSE).
}

GLOBAL FUNCTION bootPruneLogs {
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
    }
    LOCAL rm IS 0.
    IF EXISTS("1:/run") {
        SET rm TO rm + bootDeleteLogFiles("1:/run").
    }
    RETURN rm.
}

GLOBAL FUNCTION bootCleanup {
    PARAMETER vn.
    PARAMETER wl.
    LOCAL kl IS LIST(
        "state", "logs", "boot_lib", "resume",
        "phases", "config", "dependencies"
    ).
    FOR lib IN wl {
        IF NOT bootLibArchiveOnly(lib)
                AND NOT kl:CONTAINS(lib) { kl:ADD(lib). }
    }

    LOCAL kr IS LIST().
    IF CORE:TAG <> "" { kr:ADD(CORE:TAG). }

    LOCAL bf IS CORE:VOLUME:FREESPACE.
    LOCAL rm IS 0.
    SET rm TO rm + bootPruneDir("1:/lib", kl).
    SET rm TO rm + bootPruneDir("1:/craft", LIST(vn)).
    SET rm TO rm + bootPruneDir("1:/roles", kr).
    SET rm TO rm + bootPruneDir("1:/cmd", LIST()).
    IF EXISTS("1:/zombie") {
        DELETEPATH("1:/zombie").
        SET rm TO rm + 1.
    }
    SET rm TO rm + bootPruneLogs().

    IF rm > 0 {
        mLog("Cleanup removed " + rm + " files; free "
            + bf + " -> " + CORE:VOLUME:FREESPACE + ".").
    }
}

// ============================================================
// boot_lib.ks - boot-time library dependency expansion
// ============================================================

GLOBAL BOOT_LIB_RAN IS LIST().

// Manual-mode request: boot/boot.ks drains stale terminal input before
// loading this library. Any keypress noticed after that flags manual
// mode — checked before the mission picker so the menu never draws,
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

GLOBAL FUNCTION bootLibAddUnique {
    PARAMETER libs.
    PARAMETER ln.
    IF ln <> "" AND NOT libs:CONTAINS(ln) {
        libs:ADD(ln).
    }
}

GLOBAL FUNCTION bootLibAppendResolved {
    PARAMETER libs.
    PARAMETER ln.
    PARAMETER deps.
    SET ln TO ln:TRIM.
    IF deps:HASKEY(ln) {
        FOR dep IN deps[ln] {
            bootLibAppendResolved(libs, dep, deps).
        }
    }
    bootLibAddUnique(libs, ln).
}

GLOBAL FUNCTION bootLibResolve {
    PARAMETER roots.
    LOCAL libs IS LIST().
    bootLibSync("dependencies").
    RUNONCEPATH("1:/lib/dependencies").
    LOCAL deps IS dependencyLibs().
    FOR ln IN roots {
        bootLibAppendResolved(libs, ln, deps).
    }
    RETURN libs.
}

GLOBAL FUNCTION bootLibSync {
    PARAMETER ln.
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN. }
    LOCAL src IS bootArchivePath(ln).
    IF NOT EXISTS(src) { RETURN. }
    bootEnsureScriptDir(ln).
    COMPILE src TO bootCompiledPath(ln).
}

GLOBAL FUNCTION bootLibLoadList {
    PARAMETER roots.
    FOR ln IN bootLibResolve(roots) {
        LOCAL ap IS bootArchivePath(ln).
        IF ln = "solar" AND DEFINED PHASES_HAS_SOLAR {
            SET PHASES_HAS_SOLAR TO TRUE.
        }
        IF ln:CONTAINS("/") {
            bootLibSync(ln).
            RUNPATH(bootCorePath(ln)).
        } ELSE IF bootLibArchiveOnly(ln)
                AND HOMECONNECTION:ISCONNECTED
                AND EXISTS(ap) {
            RUNONCEPATH(ap).
        } ELSE {
            bootLibSync(ln).
            RUNONCEPATH(bootCorePath(ln)).
        }
    }
}

GLOBAL FUNCTION bootLibLoad {
    PARAMETER ln.
    bootLibLoadList(LIST(ln)).
}

GLOBAL FUNCTION bootPreamble {
    bootLibLoad("core").
}

GLOBAL FUNCTION bootLibBandRoots {
    PARAMETER band.
    LOCAL pr IS LIST("core").
    LOCAL bands IS dependencyBands().
    LOCAL roots IS LIST().
    FOR ln IN pr { bootLibAddUnique(roots, ln). }
    LOCAL bk IS band.
    IF bands:HASKEY(bk) {
        FOR pn IN bands[bk] {
            FOR ln IN bootLibPhaseRoots(pn) { bootLibAddUnique(roots, ln). }
        }
    } ELSE {
        FOR ln IN bootLibPhaseRoots(bk) { bootLibAddUnique(roots, ln). }
    }
    RETURN roots.
}

GLOBAL FUNCTION bootLibBandForPhase {
    PARAMETER pn.
    PARAMETER db IS "".
    LOCAL bands IS dependencyBands().
    LOCAL pk IS pn.
    IF pk = "" { RETURN db. }
    FOR bk IN bands:KEYS {
        FOR bp IN bands[bk] {
            IF bp = pk { RETURN bk. }
        }
    }
    IF db <> "" { RETURN db. }
    RETURN pk.
}

GLOBAL FUNCTION bootLibPhaseRoots {
    PARAMETER pn.
    PARAMETER ispec IS LEXICON().
    LOCAL pr IS LIST("core").
    LOCAL ps IS dependencyPhases().
    LOCAL roots IS LIST().
    FOR ln IN pr { bootLibAddUnique(roots, ln). }
    LOCAL pk IS pn.
    IF ps:HASKEY(pk) {
        FOR ln IN ps[pk] { bootLibAddUnique(roots, ln). }
    }
    RETURN roots.
}

// ============================================================
// Mission planning helpers
//
// The bulky sequence-to-library planner lives in preflight_planner.ks.
// Keep only tiny runtime helpers here.
// ============================================================

GLOBAL FUNCTION getTarget {
    PARAMETER fb IS "KERBIN".
    LOCAL tn IS stateGet("target", "").
    IF tn <> "" { RETURN tn. }
    SET tn TO TARGET_.
    IF tn = "" { SET tn TO fb. }
    IF tn <> "" { stateSet("target", tn). }
    RETURN tn.
}

GLOBAL FUNCTION bootPlannedMissionLibs {
    PARAMETER db IS "LAUNCH".
    LOCAL sq IS phaseSequenceEnsurePrelaunch(SEQUENCE).
    IF sq:LENGTH > 0 {
        bootEnsureInitialPhase(sq).
    }

    LOCAL phase IS stateGet("phase", "").
    LOCAL fb IS db.
    IF phase = "" AND SHIP:STATUS = "PRELAUNCH" {
        SET fb TO "PRELAUNCH".
    }
    IF phase <> "" {
        SET fb TO "".
    }
    LOCAL band IS bootLibBandForPhase(phase, fb).
    stateSet("lib_band", band).
    stateSet("lib_band_phase", phase).
    stateSet("reload_required", "false").

    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots, missionTypeConditionalRoots(band)).
    IF LIBS:LENGTH > 0 {
        SET roots TO LIBS.
    }
    LOCAL libs IS bootLibResolve(roots).
    missionAppendUnique(libs, bootLibResolve(missionExtraLibs())).
    RETURN libs.
}

GLOBAL FUNCTION missionAppendUnique {
    PARAMETER dest.
    PARAMETER src.
    FOR ir IN src {
        LOCAL item IS ir:TRIM.
        IF item <> "" AND NOT dest:CONTAINS(item) {
            dest:ADD(item).
        }
    }
}

GLOBAL FUNCTION missionPayloadsFromState {
    LOCAL raw IS PAYLOADS.
    IF raw:LENGTH = 0 { SET raw TO stateGet("payloads", LIST()). }
    RETURN raw.
}

GLOBAL FUNCTION missionNormalizePayloadType {
    PARAMETER pln.
    LOCAL rs IS pln.
    UNTIL rs:LENGTH = 0 {
        LOCAL last IS rs:SUBSTRING(rs:LENGTH - 1, 1).
        IF last:MATCHESPATTERN("[0-9]") OR last = "-" {
            SET rs TO rs:SUBSTRING(0, rs:LENGTH - 1).
        } ELSE {
            BREAK.
        }
    }
    RETURN rs.
}

GLOBAL FUNCTION missionHasPayload {
    PARAMETER pln.
    FOR raw IN missionPayloadsFromState() {
        IF missionNormalizePayloadType(raw) = pln { RETURN TRUE. }
    }
    RETURN FALSE.
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
    LOCAL seq IS phaseSequenceEnsurePrelaunch(SEQUENCE).
    LOCAL cur IS stateGet("phase", "").
    FOR er IN LIBS_EXTRA {
        IF er:CONTAINS("@") {
            LOCAL parts IS er:SPLIT("@").
            LOCAL ln IS parts[0]:TRIM.
            LOCAL up IS parts[1]:TRIM.
            LOCAL ci IS -1.
            LOCAL pi IS -1.
            LOCAL i IS 0.
            UNTIL i >= seq:LENGTH {
                IF seq[i] = cur { SET ci TO i. }
                IF seq[i] = up { SET pi TO i. }
                SET i TO i + 1.
            }
            IF ci >= 0 AND pi >= 0 AND ci > pi {
                mLog("Extra lib " + ln + " dropped (past "
                    + up + ").").
            } ELSE {
                out:ADD(ln).
            }
        } ELSE {
            out:ADD(er).
        }
    }
    RETURN out.
}

GLOBAL FUNCTION missionLibs {
    PARAMETER fl IS LIST().
    PARAMETER bl IS LIST().
    LOCAL libs IS LIST().
    missionAppendUnique(libs, bl).

    IF LIBS:LENGTH > 0 {
        missionAppendUnique(libs, bootLibResolve(LIBS)).
    } ELSE {
        missionAppendUnique(libs, bootLibResolve(fl)).
    }

    missionAppendUnique(libs, bootLibResolve(missionExtraLibs())).
    RETURN libs.
}

GLOBAL FUNCTION missionSequenceLibs {
    PARAMETER fl IS LIST().
    PARAMETER bd IS LIST().
    LOCAL sl IS fl.
    LOCAL sq IS phaseSequenceEnsurePrelaunch(SEQUENCE).
    IF sq:LENGTH > 0 {
        SET sl TO missionLibsForPhases(sq, bd).
    }
    RETURN missionLibs(sl).
}

// ============================================================
// Aircraft boot helpers — shared by all airplane craft scripts.
// Kept for legacy role/manual paths that still ask scripts for explicit libs.
// ============================================================

GLOBAL FUNCTION airplaneSequenceFromState {
    PARAMETER ds.
    IF SEQUENCE:LENGTH > 0 { RETURN phaseList(SEQUENCE). }
    RETURN ds.
}

GLOBAL FUNCTION airplaneVehicleLibs {
    PARAMETER ds.
    PARAMETER bl IS LIST("orbit", "airplane").
    LOCAL seq IS airplaneSequenceFromState(ds).
    LOCAL libs IS missionLibsForPhases(seq, bl).
    IF missionHasPayload("SCIENCE") AND NOT libs:CONTAINS("science") {
        libs:ADD("science").
    }
    SET libs TO missionSequenceLibs(libs, bl).
    stateSet("lib_band", "AIR").
    stateSet("lib_band_phase", stateGet("phase", seq[0])).
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
    PARAMETER ps.
    PARAMETER bd IS LIST().
    LOCAL roots IS LIST("phases").
    LOCAL pl IS phaseSequenceEnsurePrelaunch(ps).
    FOR lib IN bd {
        missionAppendUnique(roots, LIST(lib)).
    }
    FOR phase IN pl {
        missionAppendUnique(roots, bootLibPhaseRoots(phase)).
    }
    RETURN bootLibResolve(roots).
}
