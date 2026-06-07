// cmd/landassist.ks - Compact live command for emergency LAND_ASSIST resume.
// Usage: RUNPATH("0:/cmd/landassist.ks").

IF EXISTS("0:/cmd/landingrescue.ks") {
    RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").
} ELSE {
    RUNPATH("1:/cmd/landingrescue.ks", "LAND_ASSIST").
}

IF EXISTS("0:/cmd/setlandassist.ks") {
    RUNPATH("0:/cmd/setlandassist.ks").
} ELSE {
    RUNPATH("1:/cmd/setlandassist.ks").
}

REBOOT.
