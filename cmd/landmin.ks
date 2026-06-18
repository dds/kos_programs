// cmd/landmin.ks - Minimal emergency LAND_ASSIST boot prep.
// Usage: RUNPATH("0:/cmd/landmin.ks").

RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").
RUNPATH("0:/cmd/setlanding.ks", "assist").

LOCAL FUNCTION _del {
    PARAMETER path_.
    IF EXISTS(path_) { DELETEPATH(path_). }
}

_del("1:/lib/maneuver.ksm").
_del("1:/lib/targeting.ksm").
_del("1:/lib/countdown.ksm").
_del("1:/lib/orbit.ksm").
_del("1:/lib/xfer.ksm").
_del("1:/lib/lib_navigation.ksm").
_del("1:/lib/inclination.ksm").
_del("1:/lib/payload_ops.ksm").
_del("1:/lib/science.ksm").
_del("1:/lib/landing.ksm").
_del("1:/lib/landing_main.ksm").
_del("1:/lib/landing_coast.ksm").
_del("1:/lib/landing_brake.ksm").
_del("1:/lib/landing_terminal.ksm").
_del("1:/lib/landing_math.ksm").
_del("1:/lib/vessel_hardware.ksm").
_del("1:/lib/rover.ksm").
_del("1:/run/log_path.state").

REBOOT.
