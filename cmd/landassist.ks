// cmd/landassist.ks - Compact live command for emergency LAND_ASSIST resume.
// Usage: RUNPATH("0:/cmd/landassist.ks").

LOCAL FUNCTION _cmdLandassist {
    RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").
    RUNPATH("0:/cmd/setlanding.ks", "assist").

    REBOOT.
}

_cmdLandassist().
