// ============================================================
// hop.ks  -  Ballistic surface hop phase  (0:/lib/hop.ks)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL HOP_TARGET_LAT IS 0.
GLOBAL HOP_TARGET_LNG IS 0.
GLOBAL HOP_TOLERANCE IS 750.
GLOBAL HOP_PITCH IS 45.
GLOBAL HOP_MAX_BURN_SECONDS IS 90.
GLOBAL HOP_MAX_AP_KM IS 10.

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

    LOCAL maxAp IS HOP_MAX_AP_KM * 1000.
    IF HOP_MAX_AP_KM > 1000 { SET maxAp TO HOP_MAX_AP_KM. }
    LOCAL startDist IS geoDistance(SHIP:LATITUDE, SHIP:LONGITUDE,
        HOP_TARGET_LAT, HOP_TARGET_LNG).
    ADDONS:TR:SETTARGET(LATLNG(HOP_TARGET_LAT, HOP_TARGET_LNG)).

    IF ABORT {
        mLogError("HOP held: ABORT is set before ignition; clear ABORT and resume HOP.").
        PRINT "HOP held: clear ABORT before ignition.".
        RETURN.
    }

    PRINT " ".
    PRINT "  BALLISTIC HOP".
    PRINT "  Target lat/lng: " + ROUND(HOP_TARGET_LAT, 5)
        + ", " + ROUND(HOP_TARGET_LNG, 5).
    PRINT "  Range: " + ROUND(startDist, 0) + " m"
        + "  pitch=" + ROUND(HOP_PITCH, 1)
        + " deg  tolerance=" + ROUND(HOP_TOLERANCE, 0) + " m.".
    PRINT "  Limits: burn " + ROUND(HOP_MAX_BURN_SECONDS, 0)
        + "s, Ap " + ROUND(maxAp / 1000, 1) + " km.".

    mLog("HOP setup: target=" + ROUND(HOP_TARGET_LAT, 5)
        + "," + ROUND(HOP_TARGET_LNG, 5)
        + " range=" + ROUND(startDist, 0)
        + "m pitch=" + ROUND(HOP_PITCH, 1)
        + " tolerance=" + ROUND(HOP_TOLERANCE, 0)
        + "m maxBurn=" + ROUND(HOP_MAX_BURN_SECONDS, 0)
        + "s maxApKm=" + ROUND(maxAp / 1000, 1) + ".").

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
    LOCAL reason IS "operator abort".
    LOCAL abortedHop IS FALSE.
    LOCAL done IS FALSE.

    LOCK THROTTLE TO 1.

    UNTIL done {
        SET steeringTarget TO _hopSteer().

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
            }

            IF impactDist <= HOP_TOLERANCE AND TIME:SECONDS - burnStart > 1 {
                SET reason TO "impact within tolerance".
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
                + "m align=" + ROUND(VANG(SHIP:FACING:FOREVECTOR,
                    steeringTarget), 1) + "deg.").
        }

        WAIT 0.1.
    }

    LOCK THROTTLE TO 0.
    WAIT 0.2.
    UNLOCK THROTTLE.

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
