// cmd/kscsplash.ks - Target a water splashdown just offshore of KSC.
// Usage: RUNPATH("0:/cmd/kscsplash.ks").              // default offshore KSC
//        RUNPATH("0:/cmd/kscsplash.ks", -0.10, -74.25).

PARAMETER targetLat IS -0.10.
PARAMETER targetLng IS -74.25.
PARAMETER entryPeKm IS 30.
PARAMETER toleranceKm IS 15.

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoadList(LIST("deorbit_targeting", "maneuver")).

LOCAL entryPe IS entryPeKm * 1000.
LOCAL tolerance IS toleranceKm * 1000.

LOCAL splashCfg IS LEXICON(
    "TARGET_DEORBIT_SCAN_ORBITS", 32,
    "TARGET_DEORBIT_SCAN_SAMPLES", 2048,
    "TARGET_DEORBIT_COARSE_STOP_DIST", tolerance,
    "TARGET_DEORBIT_REFINE_TOLERANCE", 1000,
    "TARGET_DEORBIT_PROCEED_ON_MISS", 0,
    "TARGET_DEORBIT_MIN_LEAD", 90
).

IF DEFINED CFG {
    SET CFG TO splashCfg.
} ELSE {
    GLOBAL CFG IS splashCfg.
}

PRINT "KSC SPLASH: " + ROUND(targetLat,4) + ", " + ROUND(targetLng,4).
mLogWarn("STATS ksc-splash setup target="
    + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
    + " entryPeKm=" + ROUND(entryPe/1000,1)
    + " toleranceKm=" + ROUND(tolerance/1000,1)
    + " body=" + SHIP:BODY:NAME
    + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
    + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
    + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)).

IF SHIP:BODY:NAME <> "KERBIN" {
    PRINT "Not in Kerbin SOI yet.".
    mLogError("KSC splash aborted: current body is " + SHIP:BODY:NAME + ".").
}

LOCAL ok IS targetedDeorbitAt(targetLat, targetLng, entryPe, tolerance).
IF ok {
    PRINT "KSC splash deorbit complete.".
    LOCAL loggedImpact IS FALSE.
    IF ADDONS:TR:AVAILABLE {
        IF ADDONS:TR:HASIMPACT {
            LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
            PRINT "Impact: " + ROUND(impactPos:LAT,4) + ", " + ROUND(impactPos:LNG,4).
            mLogWarn("STATS ksc-splash result status=complete impact="
                + ROUND(impactPos:LAT,4) + "," + ROUND(impactPos:LNG,4)).
            SET loggedImpact TO TRUE.
        }
    }
    IF NOT loggedImpact { mLogWarn("STATS ksc-splash result status=complete impact=unknown"). }
} ELSE {
    PRINT "KSC splash targeting failed; holding for manual review.".
    mLogError("KSC splash targeting failed.").
}
