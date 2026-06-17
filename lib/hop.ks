// ============================================================
// hop.ks  -  Ballistic surface hop phase  (0:/lib/hop.ks)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL HOP_TARGET_LAT IS 0.
GLOBAL HOP_TARGET_LNG IS 0.
GLOBAL HOP_TOLERANCE IS 750.
GLOBAL HOP_PITCH IS 45.
GLOBAL HOP_MAX_BURN_SECONDS IS 90.
GLOBAL HOP_MAX_AP_KM IS 5.
GLOBAL HOP_TWR IS 1.15.
GLOBAL HOP_MIN_THRUST_LIMIT IS 1.

LOCAL FUNCTION _hopCfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

LOCAL FUNCTION _hopClearLibCache {
    FOR key IN LIST(
        "lib_band_libs", "lib_band_phase", "reload_reason",
        "reload_next_phase", "reload_next_band"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _hopPrepLandingAssist {
    _hopCfg("TARGET_LAT", HOP_TARGET_LAT).
    _hopCfg("TARGET_LNG", HOP_TARGET_LNG).
    _hopCfg("TARGET_LOCK", 0).
    _hopCfg("TARGET_WAYPOINT", "").
    _hopCfg("SEQUENCE", "HOP,LAND_ASSIST,DONE").
    _hopCfg("RELOAD_AFTER_LAND_ASSIST", 0).
    stateSet("phase", "LAND_ASSIST").
    stateSet("lib_band", "LANDING").
    stateSet("reload_required", "false").
    _hopClearLibCache().
}

LOCAL FUNCTION _hopDirectionToTarget {
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL targetVec IS VXCL(upVec,
        LATLNG(HOP_TARGET_LAT, HOP_TARGET_LNG):POSITION - SHIP:POSITION).
    IF targetVec:MAG < 0.01 {
        LOCAL fallback IS VXCL(upVec, SHIP:FACING:FOREVECTOR).
        IF fallback:MAG < 0.01 { SET fallback TO VCRS(upVec, V(0,0,1)). }
        IF fallback:MAG < 0.01 { SET fallback TO VCRS(upVec, V(1,0,0)). }
        RETURN fallback:NORMALIZED.
    }
    RETURN targetVec:NORMALIZED.
}

LOCAL FUNCTION _hopSteer {
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL downrange IS _hopDirectionToTarget().
    RETURN (upVec * SIN(HOP_PITCH)
        + downrange * COS(HOP_PITCH)):NORMALIZED.
}

LOCAL FUNCTION _hopClearStickyAbort {
    IF NOT ABORT { RETURN FALSE. }
    SET ABORT TO FALSE.
    WAIT 0.1.
    RETURN NOT ABORT.
}

LOCAL FUNCTION _hopGravity {
    LOCAL radiusMag IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    IF radiusMag <= 0 { RETURN 0.01. }
    RETURN MAX(0.01, SHIP:BODY:MU / (radiusMag * radiusMag)).
}

LOCAL FUNCTION _hopTwr {
    LOCAL gravAcc IS _hopGravity().
    IF SHIP:MASS <= 0 OR gravAcc <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / (SHIP:MASS * gravAcc).
}

LOCAL FUNCTION _hopCaptureThrustLimits {
    LOCAL limits IS LIST().
    FOR eng IN SHIP:ENGINES {
        limits:ADD(LEXICON("ENGINE", eng, "LIMIT", eng:THRUSTLIMIT)).
    }
    RETURN limits.
}

LOCAL FUNCTION _hopRestoreThrustLimits {
    PARAMETER limits.
    FOR item IN limits {
        LOCAL eng IS item["ENGINE"].
        SET eng:THRUSTLIMIT TO item["LIMIT"].
    }
}

LOCAL FUNCTION _hopAverageThrustLimit {
    LOCAL total IS 0.
    LOCAL count IS 0.
    FOR eng IN SHIP:ENGINES {
        SET total TO total + eng:THRUSTLIMIT.
        SET count TO count + 1.
    }
    IF count = 0 { RETURN 0. }
    RETURN total / count.
}

LOCAL FUNCTION _hopTuneThrustLimit {
    LOCAL liftFrac IS MAX(0.2, SIN(HOP_PITCH)).
    LOCAL targetTotalTwr IS HOP_TWR / liftFrac.
    LOCAL currentTwr IS _hopTwr().
    IF currentTwr <= 0 { RETURN targetTotalTwr. }

    LOCAL ratio IS targetTotalTwr / currentTwr.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION {
            LOCAL newLimit IS eng:THRUSTLIMIT * ratio.
            SET newLimit TO MAX(HOP_MIN_THRUST_LIMIT, MIN(100, newLimit)).
            SET eng:THRUSTLIMIT TO newLimit.
        }
    }
    RETURN targetTotalTwr.
}

GLOBAL FUNCTION phaseHop {
    applyKnownMissionState().

    IF NOT ADDONS:TR:AVAILABLE {
        PRINT "HOP requires Trajectories.".
        mLogError("HOP: Trajectories unavailable; refusing ballistic hop.").
        RETURN.
    }

    stateSet("phase", "HOP").
    stateSet("lib_band", "LAUNCH").
    stateSet("reload_required", "false").
    IF stateGetNum("launch_time", 0) = 0 {
        stateSet("launch_time", ROUND(TIME:SECONDS)).
    }

    LOCAL startDist IS geoDistance(SHIP:LATITUDE, SHIP:LONGITUDE,
        HOP_TARGET_LAT, HOP_TARGET_LNG).
    LOCAL configMaxAp IS HOP_MAX_AP_KM * 1000.
    IF HOP_MAX_AP_KM > 1000 { SET configMaxAp TO HOP_MAX_AP_KM. }
    LOCAL rangeMaxAp IS MAX(500, startDist * 0.25).
    LOCAL maxAp IS MIN(configMaxAp, rangeMaxAp).
    ADDONS:TR:SETTARGET(LATLNG(HOP_TARGET_LAT, HOP_TARGET_LNG)).

    IF ABORT {
        IF _hopClearStickyAbort() {
            mLogWarn("HOP cleared sticky ABORT before ignition.").
        } ELSE {
            mLogError("HOP held: ABORT stayed set before ignition.").
            PRINT "HOP held: ABORT stayed set before ignition.".
            yieldToPrompt().
            RETURN.
        }
    }

    PRINT " ".
    PRINT "  BALLISTIC HOP".
    PRINT "  Target lat/lng: " + ROUND(HOP_TARGET_LAT, 5)
        + ", " + ROUND(HOP_TARGET_LNG, 5).
    PRINT "  Range: " + ROUND(startDist, 0) + " m"
        + "  pitch=" + ROUND(HOP_PITCH, 1)
        + " deg  tolerance=" + ROUND(HOP_TOLERANCE, 0) + " m.".
    PRINT "  Limits: burn " + ROUND(HOP_MAX_BURN_SECONDS, 0)
        + "s, Ap " + ROUND(maxAp / 1000, 1) + " km"
        + " (cfg " + ROUND(configMaxAp / 1000, 1) + " km).".

    mLog("HOP setup: target=" + ROUND(HOP_TARGET_LAT, 5)
        + "," + ROUND(HOP_TARGET_LNG, 5)
        + " range=" + ROUND(startDist, 0)
        + "m pitch=" + ROUND(HOP_PITCH, 1)
        + " tolerance=" + ROUND(HOP_TOLERANCE, 0)
        + "m maxBurn=" + ROUND(HOP_MAX_BURN_SECONDS, 0)
        + "s maxApKm=" + ROUND(maxAp / 1000, 1)
        + " cfgMaxApKm=" + ROUND(configMaxAp / 1000, 1)
        + " rangeMaxApKm=" + ROUND(rangeMaxAp / 1000, 1) + ".").

    IF startDist <= HOP_TOLERANCE {
        PRINT "Already inside hop tolerance; rebooting into LAND_ASSIST.".
        mLog("HOP skipped: already inside tolerance.").
        _hopPrepLandingAssist().
        REBOOT.
    }

    SAS OFF.
    RCS OFF.

    LOCAL steeringTarget IS _hopSteer().
    LOCK STEERING TO steeringTarget.
    LOCAL alignDeadline IS TIME:SECONDS + 12.
    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, steeringTarget) < 8
        OR TIME:SECONDS > alignDeadline.

    IF SHIP:MAXTHRUST <= 0 AND STAGE:NUMBER > 0 {
        mLog("HOP staging to activate thrust.").
        STAGE.
        WAIT 0.5.
    }
    IF SHIP:MAXTHRUST <= 0 {
        PRINT "HOP failed: no thrust available.".
        mLogError("HOP failed: no thrust available.").
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        RETURN.
    }

    LOCAL burnStart IS TIME:SECONDS.
    LOCAL nextLog IS TIME:SECONDS.
    LOCAL bestDist IS 999999.
    LOCAL bestLat IS 0.
    LOCAL bestLng IS 0.
    LOCAL bestTime IS TIME:SECONDS.
    LOCAL reason IS "operator abort".
    LOCAL abortedHop IS FALSE.
    LOCAL done IS FALSE.
    LOCAL divergeMargin IS MAX(250, HOP_TOLERANCE).
    LOCAL thrustLimits IS _hopCaptureThrustLimits().
    LOCAL targetTotalTwr IS _hopTuneThrustLimit().

    mLog("HOP thrust limiter: targetVerticalTwr=" + ROUND(HOP_TWR, 2)
        + " targetTotalTwr=" + ROUND(targetTotalTwr, 2)
        + " avgLimit=" + ROUND(_hopAverageThrustLimit(), 1)
        + "% twr=" + ROUND(_hopTwr(), 2) + ".").

    LOCK THROTTLE TO 1.

    UNTIL done {
        SET steeringTarget TO _hopSteer().
        SET targetTotalTwr TO _hopTuneThrustLimit().

        IF ABORT {
            SET reason TO "operator abort".
            SET abortedHop TO TRUE.
            SET done TO TRUE.
        }

        LOCAL hasImpact IS ADDONS:TR:HASIMPACT.
        LOCAL impactDist IS 999999.
        IF hasImpact {
            LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
            SET impactDist TO geoDistance(impactPos:LAT, impactPos:LNG,
                HOP_TARGET_LAT, HOP_TARGET_LNG).
            IF impactDist < bestDist {
                SET bestDist TO impactDist.
                SET bestLat TO impactPos:LAT.
                SET bestLng TO impactPos:LNG.
                SET bestTime TO TIME:SECONDS.
            }

            IF impactDist <= HOP_TOLERANCE AND TIME:SECONDS - burnStart > 1 {
                SET reason TO "impact within tolerance".
                SET done TO TRUE.
            } ELSE IF bestDist < startDist
                    AND impactDist > bestDist + divergeMargin
                    AND TIME:SECONDS - bestTime > 0.5
                    AND TIME:SECONDS - burnStart > 2 {
                SET reason TO "impact diverging after best".
                SET done TO TRUE.
            } ELSE IF bestDist <= HOP_TOLERANCE * 2
                    AND impactDist > bestDist * 1.25
                    AND TIME:SECONDS - burnStart > 5 {
                SET reason TO "passed best impact".
                SET done TO TRUE.
            }
        }

        IF SHIP:APOAPSIS >= maxAp {
            SET reason TO "max apoapsis".
            SET done TO TRUE.
        } ELSE IF TIME:SECONDS - burnStart >= HOP_MAX_BURN_SECONDS {
            SET reason TO "max burn time".
            SET done TO TRUE.
        }

        IF TIME:SECONDS >= nextLog {
            SET nextLog TO TIME:SECONDS + 2.
            mLog("HOP burn: t=" + ROUND(TIME:SECONDS - burnStart, 1)
                + "s Ap=" + ROUND(SHIP:APOAPSIS / 1000, 1)
                + "km impact=" + ROUND(impactDist, 0)
                + "m best=" + ROUND(bestDist, 0)
                + "m twr=" + ROUND(_hopTwr(), 2)
                + " lim=" + ROUND(_hopAverageThrustLimit(), 1)
                + "% align=" + ROUND(VANG(SHIP:FACING:FOREVECTOR,
                    steeringTarget), 1) + "deg.").
        }

        WAIT 0.1.
    }

    LOCK THROTTLE TO 0.
    WAIT 0.2.
    UNLOCK THROTTLE.
    _hopRestoreThrustLimits(thrustLimits).

    mLogWarn("STATS hop cutoff reason=" + reason
        + " burn=" + ROUND(TIME:SECONDS - burnStart, 1)
        + " bestDist=" + ROUND(bestDist, 0)
        + " best=" + ROUND(bestLat, 5) + "," + ROUND(bestLng, 5)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)).

    IF abortedHop {
        stateSet("phase", "HOP").
        stateSet("lib_band", "LAUNCH").
        stateSet("reload_required", "false").
        PRINT "HOP aborted; holding HOP phase.".
        mLogError("HOP aborted by operator; holding HOP phase. Clear ABORT before resuming.").
        RETURN.
    }

    PRINT "HOP cutoff: " + reason + ".".
    PRINT "Best impact miss: " + ROUND(bestDist, 0) + " m.".
    PRINT "Rebooting into LAND_ASSIST.".

    _hopPrepLandingAssist().
    REBOOT.
}
