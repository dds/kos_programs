// No deorbit authorization without a complete offline powered-descent set.
@LAZYGLOBAL OFF.

// Resolve a future band's actual boot set WITHOUT running its code or
// changing the current band. Used before an irreversible flight transition.
GLOBAL FUNCTION bootLibBandCacheList {
    PARAMETER band.
    LOCAL roots IS bootLibBandRoots(band).
    missionAppendUnique(roots,missionTypeConditionalRoots(band)).
    IF LIBS:LENGTH > 0 {
        SET roots TO LIST().
        missionAppendUnique(roots,LIBS).
    }
    missionAppendUnique(roots,missionExtraLibs()).
    LOCAL libs IS LIST().
    LOCAL deps IS dependencyLibs().
    FOR ln IN roots { bootLibAppendResolved(libs,ln,deps). }
    RETURN libs.
}

GLOBAL FUNCTION bootLibCacheReady {
    PARAMETER libs.
    FOR ln IN libs {
        IF bootLibArchiveOnly(ln) { RETURN FALSE. }
        LOCAL path_ IS bootLocalScriptPath(ln).
        IF path_ = "" { RETURN FALSE. }
        IF NOT (OPEN(path_):SIZE > 0) { RETURN FALSE. }
    }
    RETURN TRUE.
}

// Cache only; never RUN another band's functions in the active interpreter.
// Compile before sizing, then preflight the ENTIRE copy before modifying the
// local disk. Insufficient capacity leaves all current programs untouched.
GLOBAL FUNCTION bootLibEnsureCached {
    PARAMETER libs.
    PARAMETER headroom IS 4096.
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN bootLibCacheReady(libs). }
    LOCAL copies IS LIST().
    LOCAL needed IS 0.
    FOR ln IN libs {
        IF bootLibArchiveOnly(ln) {
            mLogError("Offline cache cannot include archive-only library: " + ln).
            RETURN FALSE.
        }
        IF NOT BOOT_LIB_RAN:CONTAINS(ln) OR bootLocalScriptPath(ln) = "" {
            IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
            LOCAL src IS bootArchivePath(ln).
            IF NOT EXISTS(src) { RETURN FALSE. }
            LOCAL compiled IS src:SUBSTRING(0,src:LENGTH-3)+".ksm".
            COMPILE src TO compiled.
            IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
            LOCAL bytes IS OPEN(compiled):SIZE.
            IF NOT (bytes > 0) { RETURN FALSE. }
            LOCAL dest IS bootCompiledPath(ln).
            LOCAL oldBytes IS 0.
            IF EXISTS(dest) { SET oldBytes TO OPEN(dest):SIZE. }
            SET needed TO needed+MAX(0,bytes-oldBytes).
            copies:ADD(LEXICON("LIB",ln,"FROM",compiled,"TO",dest,"BYTES",bytes)).
        }
    }
    mLog("STATS offline-cache requiredBytes=" + needed
        + " freeBytes=" + CORE:VOLUME:FREESPACE + " reserveBytes=" + headroom
        + " files=" + copies:LENGTH).
    IF needed+MAX(4096,headroom) > CORE:VOLUME:FREESPACE { RETURN FALSE. }
    FOR item IN copies {
        IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
        LOCAL dest IS item["TO"].
        LOCAL oldBytes IS 0.
        IF EXISTS(dest) { SET oldBytes TO OPEN(dest):SIZE. }
        IF item["BYTES"]+MAX(4096,headroom) > CORE:VOLUME:FREESPACE+oldBytes { RETURN FALSE. }
        bootEnsureScriptDir(item["LIB"]).
        IF EXISTS(dest) { DELETEPATH(dest). }
        COPYPATH(item["FROM"],dest).
        IF NOT EXISTS(dest) { RETURN FALSE. }
        IF OPEN(dest):SIZE <> item["BYTES"] { RETURN FALSE. }
    }
    RETURN bootLibCacheReady(libs).
}


LOCAL FUNCTION _landingHandoffLibs {
    LOCAL libs IS bootLibBandCacheList(bootLibBandForPhase("LAND_ASSIST","")).
    // LIBS overrides cannot turn an incomplete landing band into a pass.
    LOCAL mandatory IS LIST().
    LOCAL deps IS dependencyLibs().
    FOR ln IN LIST("payload_landing","landing_main","landing_coast","landing_brake") {
        bootLibAppendResolved(mandatory,ln,deps).
    }
    FOR ln IN mandatory {
        IF NOT libs:CONTAINS(ln) { RETURN LIST(). }
    }
    RETURN libs.
}

GLOBAL FUNCTION landingHandoffReady {
    PARAMETER prepare IS FALSE.
    // Payload-only deorbits which never fly LAND/LAND_ASSIST keep their own
    // release policy. This guard applies to a powered landing of this craft.
    IF NOT xferSeq:CONTAINS("LAND_ASSIST") AND NOT xferSeq:CONTAINS("LAND") { RETURN TRUE. }
    LOCAL libs IS _landingHandoffLibs().
    LOCAL ready IS FALSE.
    IF libs:LENGTH > 0 {
        IF prepare { SET ready TO bootLibEnsureCached(libs). }
        ELSE { SET ready TO bootLibCacheReady(libs). }
    }
    mLog("STATS landing-handoff cached=" + ready + " prepare=" + prepare
        + " libraries=" + libs:LENGTH + " linked=" + HOMECONNECTION:ISCONNECTED
        + " freeBytes=" + CORE:VOLUME:FREESPACE).
    IF NOT ready {
        mLogError("Deorbit blocked: complete offline landing code is not cached. Retaining orbit and node; obtain a link and sufficient onboard storage before retrying.").
    }
    RETURN ready.
}
