// ============================================================
// reentry_pe.ks — shared native-validated apoapsis Pe repair
// (0:/lib/reentry_pe.ks). The repair may spend the fuel protected from
// optional aerobrake assistance, using the active-stage fuel budget and
// shared maneuver executor. No repair is planned inside atmosphere.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION reentryPeNodeOk {
    PARAMETER nd.
    PARAMETER desiredPe.
    PARAMETER peLow.
    PARAMETER peHigh.
    RETURN nd:TIME > TIME:SECONDS+30 AND nd:DELTAV:MAG > 0.05
        AND nd:DELTAV:MAG <= 20
        AND MIN(SHIP:DELTAV:VACUUM,STAGE:DELTAV:VACUUM) >= nd:DELTAV:MAG+0.5
        AND ABS(nd:ORBIT:PERIAPSIS-desiredPe) <= 250
        AND nd:ORBIT:PERIAPSIS >= peLow AND nd:ORBIT:PERIAPSIS <= peHigh
        AND ABS(nd:ORBIT:APOAPSIS-SHIP:APOAPSIS) <= 100
        AND ABS(nd:ORBIT:INCLINATION-SHIP:ORBIT:INCLINATION) <= 0.01
        AND ABS(nd:RADIALOUT) < 0.000001 AND ABS(nd:NORMAL) < 0.000001.
}

GLOBAL FUNCTION restoreEntryPe {
    PARAMETER targetPe.
    PARAMETER peLow.
    PARAMETER peHigh.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    LOCAL result IS LEXICON("OK",FALSE,"BURNED",FALSE,"REASON","invalid-context").
    IF ABORT OR HASNODE OR maneuverBurnInterrupted()
            OR SHIP:ORBIT:HASNEXTPATCH
            OR NOT SHIP:BODY:ATM:EXISTS
            OR NOT (SHIP:ALTITUDE > SHIP:BODY:ATM:HEIGHT
                AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
                AND SHIP:PERIAPSIS > 0 AND SHIP:APOAPSIS > SHIP:BODY:ATM:HEIGHT
                AND VDOT(SHIP:POSITION-SHIP:BODY:POSITION,SHIP:VELOCITY:ORBIT) > 0
                AND ETA:APOAPSIS > 30 AND ETA:APOAPSIS < 1e30
                AND targetPe >= peLow AND targetPe <= peHigh
                AND peLow > 0 AND peHigh < SHIP:BODY:ATM:HEIGHT) { RETURN result. }
    IF ABS(SHIP:PERIAPSIS-targetPe) <= 250 {
        RETURN LEXICON("OK",TRUE,"BURNED",FALSE,"REASON","within-tolerance").
    }
    LOCAL available IS MIN(SHIP:DELTAV:VACUUM,STAGE:DELTAV:VACUUM).
    IF NOT (available > 0.5 AND available < 1e30) {
        SET result["REASON"] TO "insufficient-fuel". RETURN result.
    }
    IF NOT thrustCutoffOk() { SET result["REASON"] TO "cutoff-failed". RETURN result. }
    LOCAL startInc IS SHIP:ORBIT:INCLINATION.
    LOCAL nd IS planLowerPe(targetPe).
    IF NOT reentryPeNodeOk(nd,targetPe,peLow,peHigh) {
        SET result["REASON"] TO "native-node-rejected".
        IF nd:DELTAV:MAG+0.5 > available { SET result["REASON"] TO "insufficient-fuel". }
        IF nd:DELTAV:MAG <= 0.05 AND SHIP:PERIAPSIS >= peLow AND SHIP:PERIAPSIS <= peHigh {
            SET result["OK"] TO TRUE. SET result["REASON"] TO "below-execution-minimum".
        }
        mLogWarn("STATS reentry-pe status=rejected reason=" + result["REASON"]
            + " nativePe=" + nd:ORBIT:PERIAPSIS + " nativeAp=" + nd:ORBIT:APOAPSIS
            + " dv=" + nd:DELTAV:MAG).
        REMOVE nd. RETURN result.
    }
    mLog("STATS reentry-pe status=planned startPe=" + SHIP:PERIAPSIS
        + " startAp=" + SHIP:APOAPSIS + " targetPe=" + targetPe
        + " dv=" + nd:DELTAV:MAG + " nodeUt=" + nd:TIME).
    LOCAL oldAbs IS BURN_TRIM_ABS_COMPLETE_DV.
    LOCAL oldMax IS BURN_TRIM_COMPLETE_MAX_DV.
    SET BURN_TRIM_ABS_COMPLETE_DV TO MIN(oldAbs,0.005).
    SET BURN_TRIM_COMPLETE_MAX_DV TO MIN(oldMax,0.005).
    LOCAL success IS executeManeuver().
    SET BURN_TRIM_ABS_COMPLETE_DV TO oldAbs.
    SET BURN_TRIM_COMPLETE_MAX_DV TO oldMax.
    LOCAL stopped IS thrustCutoffOk().
    SET result["REASON"] TO "burn-failed-inspect-retained-node".
    IF NOT stopped OR NOT success { RETURN result. }
    SET result["BURNED"] TO TRUE.
    SET result["OK"] TO ABS(SHIP:PERIAPSIS-targetPe) <= 500
        AND SHIP:PERIAPSIS >= peLow AND SHIP:PERIAPSIS <= peHigh
        AND ABS(SHIP:ORBIT:INCLINATION-startInc) <= 0.1.
    SET result["REASON"] TO "flown-outside-corridor".
    IF result["OK"] { SET result["REASON"] TO "restored". }
    mLog("STATS reentry-pe status=flown reason=" + result["REASON"]
        + " Pe=" + SHIP:PERIAPSIS + " Ap=" + SHIP:APOAPSIS + " targetPe=" + targetPe).
    RETURN result.
}
