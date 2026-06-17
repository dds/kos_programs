// cmd/hop.ks - Ballistic surface hop to a lat/lng, then LAND_ASSIST.
// Usage:
//   RUNPATH("0:/cmd/hop.ks", 0, -98.39).
//   RUNPATH("0:/cmd/hop.ks", 0, -98.39, 750, 45, 90, 20).
//
// Args: lat, lng, tolerance meters, pitch deg, max burn sec, max Ap km.

PARAMETER targetLat.
PARAMETER targetLng.
PARAMETER toleranceM IS 750.
PARAMETER pitchDeg IS 45.
PARAMETER maxBurnSeconds IS 90.
PARAMETER maxApKm IS 20.

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("utils").


LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

LOCAL FUNCTION _clearLibCache {
    FOR key IN LIST(
        "lib_band_libs", "lib_band_phase", "reload_reason",
        "reload_next_phase", "reload_next_band"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _prepLandingAssist {
    _cfg("TARGET_LAT", targetLat).
    _cfg("TARGET_LNG", targetLng).
    _cfg("TARGET_LOCK", 0).
    _cfg("TARGET_WAYPOINT", "").
    _cfg("SEQUENCE", "LAND_ASSIST,DONE").
    _cfg("RELOAD_AFTER_LAND_ASSIST", 0).
    stateSet("phase", "LAND_ASSIST").
    stateSet("lib_band", "LANDING").
    stateSet("reload_required", "false").
    stateSet("launch_time", ROUND(TIME:SECONDS)).
    _clearLibCache().
}

LOCAL FUNCTION _directionToTarget {
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL targetVec IS VXCL(upVec,
        LATLNG(targetLat, targetLng):POSITION - SHIP:POSITION).
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
    LOCAL downrange IS _directionToTarget().
    RETURN (upVec * SIN(pitchDeg)
        + downrange * COS(pitchDeg)):NORMALIZED.
}

GLOBAL FUNCTION main {
   IF NOT ADDONS:TR:AVAILABLE {
       PRINT "HOP requires Trajectories.".
       mLogError("HOP: Trajectories unavailable; refusing ballistic hop.").
       RETURN.
   }

   LOCAL maxAp IS maxApKm * 1000.
   IF maxApKm > 1000 { SET maxAp TO maxApKm. }
   LOCAL startDist IS geoDistance(SHIP:LATITUDE, SHIP:LONGITUDE,
      targetLat, targetLng).
   ADDONS:TR:SETTARGET(LATLNG(targetLat, targetLng)).

   _prepLandingAssist().

   PRINT " ".
   PRINT "  BALLISTIC HOP".
   PRINT "  Target lat/lng: " + ROUND(targetLat, 5)
       + ", " + ROUND(targetLng, 5).
   PRINT "  Range: " + ROUND(startDist, 0) + " m"
       + "  pitch=" + ROUND(pitchDeg, 1)
       + " deg  tolerance=" + ROUND(toleranceM, 0) + " m.".

   mLog("HOP setup: target=" + ROUND(targetLat, 5)
       + "," + ROUND(targetLng, 5)
       + " range=" + ROUND(startDist, 0)
       + "m pitch=" + ROUND(pitchDeg, 1)
       + " tolerance=" + ROUND(toleranceM, 0)
       + "m maxApKm=" + ROUND(maxAp / 1000, 1) + ".").

   IF startDist <= toleranceM {
       PRINT "Already inside hop tolerance; rebooting into LAND_ASSIST.".
       mLog("HOP skipped: already inside tolerance.").
       REBOOT.
   }

   SAS OFF.
   RCS OFF.
   GEAR OFF.

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
   LOCAL done IS FALSE.

   LOCK THROTTLE TO 1.

   UNTIL done OR ABORT {
       SET steeringTarget TO _hopSteer().

       LOCAL hasImpact IS ADDONS:TR:HASIMPACT.
       LOCAL impactDist IS 999999.
       IF hasImpact {
           LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
           SET impactDist TO geoDistance(impactPos:LAT, impactPos:LNG,
               targetLat, targetLng).
           IF impactDist < bestDist {
               SET bestDist TO impactDist.
               SET bestLat TO impactPos:LAT.
               SET bestLng TO impactPos:LNG.
           }

           IF impactDist <= toleranceM AND TIME:SECONDS - burnStart > 1 {
               SET reason TO "impact within tolerance".
               SET done TO TRUE.
           } ELSE IF bestDist <= toleranceM * 2
                   AND impactDist > bestDist * 1.25
                   AND TIME:SECONDS - burnStart > 5 {
               SET reason TO "passed best impact".
               SET done TO TRUE.
           }
       }

       IF SHIP:APOAPSIS >= maxAp {
           SET reason TO "max apoapsis".
           SET done TO TRUE.
       } ELSE IF TIME:SECONDS - burnStart >= maxBurnSeconds {
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

   PRINT "HOP cutoff: " + reason + ".".
   PRINT "Best impact miss: " + ROUND(bestDist, 0) + " m.".
   PRINT "Rebooting into LAND_ASSIST.".

   REBOOT.
}

MAIN().
