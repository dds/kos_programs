// Restore the Kerbin entry Pe at the approaching apoapsis; altitudes in metres.
// RUNPATH("0:/cmd/reentrype.ks",53000).
// Run outside atmosphere on the outbound leg. Existing nodes are preserved.
@LAZYGLOBAL OFF.
PARAMETER targetPe IS 53000.

LOCAL FUNCTION _reentryPeNodeOk {
    PARAMETER nd.
    PARAMETER desiredPe.
    RETURN nd:TIME > TIME:SECONDS+30 AND nd:DELTAV:MAG > 0.05
        AND nd:DELTAV:MAG <= 20
        AND MIN(SHIP:DELTAV:VACUUM,STAGE:DELTAV:VACUUM) >= nd:DELTAV:MAG+0.5
        AND ABS(nd:ORBIT:PERIAPSIS-desiredPe) <= 250
        AND nd:ORBIT:PERIAPSIS >= 52000 AND nd:ORBIT:PERIAPSIS <= 54000
        AND ABS(nd:ORBIT:APOAPSIS-SHIP:APOAPSIS) <= 100
        AND ABS(nd:ORBIT:INCLINATION-SHIP:ORBIT:INCLINATION) <= 0.01
        AND ABS(nd:RADIALOUT) < 0.000001 AND ABS(nd:NORMAL) < 0.000001.
}

LOCAL FUNCTION _cmdReentrype {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("maneuver_plan").
    IF NOT (targetPe >= 52000 AND targetPe <= 54000) {
        PRINT "Target must be within the Kerbin 52000-54000m entry corridor.". RETURN.
    }
    IF SHIP:BODY:NAME <> "Kerbin" OR NOT SHIP:BODY:ATM:EXISTS
            OR NOT (SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT
                AND SHIP:ORBIT:ECCENTRICITY < 1 AND SHIP:PERIAPSIS > 0
                AND SHIP:APOAPSIS > SHIP:BODY:ATM:HEIGHT
                AND VDOT(SHIP:POSITION-SHIP:BODY:POSITION,SHIP:VELOCITY:ORBIT) > 0
                AND ETA:APOAPSIS > 30) {
        PRINT "Requires an outbound, bound Kerbin orbit outside atmosphere, before apoapsis.". RETURN.
    }
    IF HASNODE OR maneuverBurnInterrupted() {
        PRINT "Existing/interrupted maneuver retained. Inspect it before requesting a new correction.". RETURN.
    }
    IF ABS(SHIP:PERIAPSIS-targetPe) <= 250 {
        PRINT "Pe is already within 250m of target; no correction needed.". RETURN.
    }
    IF NOT thrustCutoffOk() { RETURN. }
    LOCAL startInclination IS SHIP:ORBIT:INCLINATION.
    // Despite its name this shared planner also raises Pe with positive dV.
    // It uses vis-viva from orbital elements, never future VELOCITYAT.
    LOCAL nd IS planLowerPe(targetPe).
    IF NOT _reentryPeNodeOk(nd,targetPe) {
        mLogWarn("STATS reentry-pe status=rejected nativePe=" + nd:ORBIT:PERIAPSIS
            + " nativeAp=" + nd:ORBIT:APOAPSIS + " dv=" + nd:DELTAV:MAG).
        REMOVE nd.
        PRINT "Correction rejected: native corridor, plane, apoapsis, timing or fuel check failed.". RETURN.
    }
    mLog("STATS reentry-pe status=planned startPe=" + SHIP:PERIAPSIS
        + " startAp=" + SHIP:APOAPSIS + " targetPe=" + targetPe
        + " inclination=" + startInclination + " dv=" + nd:DELTAV:MAG
        + " nodeUt=" + nd:TIME + " predictedPe=" + nd:ORBIT:PERIAPSIS).
    LOCAL success IS executeManeuver().
    LOCAL stopped IS thrustCutoffOk().
    IF NOT stopped OR NOT success {
        PRINT "Pe correction failed; inspect any remaining node and burn report before retrying.". RETURN.
    }
    mLog("STATS reentry-pe status=flown Pe=" + SHIP:PERIAPSIS + " Ap=" + SHIP:APOAPSIS
        + " inclination=" + SHIP:ORBIT:INCLINATION + " targetPe=" + targetPe).
    IF NOT (ABS(SHIP:PERIAPSIS-targetPe) <= 500
            AND SHIP:PERIAPSIS >= 52000 AND SHIP:PERIAPSIS <= 54000
            AND ABS(SHIP:ORBIT:INCLINATION-startInclination) <= 0.1) {
        PRINT "Correction finished outside the requested orbit; inspect the log before resuming.". RETURN.
    }
    PRINT "Entry Pe restored. Reboot to resume the existing aerobrake mission.".
}

_cmdReentrype().
