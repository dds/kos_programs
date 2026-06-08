// cmd/landmin.ks - Minimal emergency LAND_ASSIST boot prep.
// Usage: RUNPATH("0:/cmd/landmin.ks").

IF EXISTS("0:/cmd/landingrescue.ks") {
    RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").
} ELSE {
    RUNPATH("1:/cmd/landingrescue.ks", "LAND_ASSIST").
}

IF EXISTS("0:/cmd/setlandassist.ks") {
    RUNPATH("0:/cmd/setlandassist.ks").
} ELSE IF EXISTS("1:/cmd/setlandassist.ks") {
    RUNPATH("1:/cmd/setlandassist.ks").
}

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
_del("1:/lib/rover.ksm").
_del("1:/run/log_path.state").

REBOOT.
