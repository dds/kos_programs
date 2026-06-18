// cmd/landassist.ks - Compact live command for emergency LAND_ASSIST resume.
// Usage: RUNPATH("0:/cmd/landassist.ks").

RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").
RUNPATH("0:/cmd/setlanding.ks", "assist").
RUNPATH("0:/cmd/setstate.ks", "mission_cfg_LANDING_SKIP_TARGET_SEARCH", 1).

REBOOT.
