// cmd/resetmission.ks - Clear selected mission profile before a fresh launch.
// Usage:
//   RUNPATH("1:/cmd/resetmission.ks").                    // prompt on next boot
//   RUNPATH("1:/cmd/resetmission.ks", "mun_scansat_polar"). // force after launch
//
// Use this on the pad or in a fresh simulation. It clears phase/reload state too.
// New boot.ks also does this automatically while the vessel is prelaunch.

PARAMETER newMission IS "".

LOCAL HAS_LINK IS HOMECONNECTION:ISCONNECTED.

LOCAL FUNCTION _syncLib {
    PARAMETER libName.
    IF NOT HAS_LINK { RETURN. }

    LOCAL src IS "0:/lib/" + libName + ".ks".
    LOCAL dst IS "1:/lib/" + libName + ".ks".
    LOCAL dstKsm IS "1:/lib/" + libName + ".ksm".

    IF EXISTS(src) {
        IF NOT KSM_SKIP:CONTAINS(libName) {
            COMPILE src TO dstKsm.
        } ELSE {
            COPYPATH(src, dst).
        }
    }
}

LOCAL FUNCTION _loadLib {
    PARAMETER libName.
    IF EXISTS("1:/lib/" + libName + ".ksm") {
        RUNONCEPATH("1:/lib/" + libName + ".ksm").
    } ELSE {
        RUNONCEPATH("1:/lib/" + libName + ".ks").
    }
}

_syncLib("logs").
_loadLib("logs").
initLog().
_syncLib("state").
_loadLib("state").

LOCAL removed IS stateRemovePrefix("mission_cfg_").
FOR key IN LIST(
    "mission_id", "mission_name", "target", "payloads", "phase",
    "lib_band", "lib_band_phase", "lib_band_libs",
    "reload_required", "reload_reason", "reload_next_phase",
    "reload_next_band", "fairing_deployed"
) {
    stateRemove(key).
}

IF newMission <> "" {
    stateSet("mission_id", newMission).
    PRINT "Mission reset. Next boot will load profile: " + newMission.
    mLog("Mission reset to profile " + newMission + "; cleared " + removed + " config keys.").
} ELSE {
    PRINT "Mission reset. Next boot will ask for a profile.".
    mLog("Mission selection reset; cleared " + removed + " config keys.").
}
