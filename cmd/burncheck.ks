// Read-only ignition diagnostics. Run in manual mode with the node retained.
// RUNPATH("0:/cmd/burncheck.ks"). Does not ignite, stage, or edit the node.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdBurncheck {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("maneuver").
    // Replay the cached SET-only profile and overrides so the probe uses the
    // mission's actual watchdog settings without changing its phase or node.
    LOCAL profilePath IS "1:/missions/" + stateGet("vehicle", "")
        + "/" + stateGet("mission_id", "") + ".ks".
    IF EXISTS(profilePath) { RUNPATH(profilePath). }
    applyMissionOverrides().
    maneuverThrottleCheck().
}

_cmdBurncheck().
