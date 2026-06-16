// cmd/resetmission.ks - Clear selected mission profile before a fresh launch.
// Usage:
//   RUNPATH("0:/cmd/resetmission.ks").                    // prompt on next boot
//   RUNPATH("0:/cmd/resetmission.ks", "mun_scansat_polar"). // force after launch
//
// Use this on the pad or in a fresh simulation. It clears phase/reload state too.
// New boot.ks also does this automatically while the vessel is prelaunch.

PARAMETER newMission IS "".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

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
