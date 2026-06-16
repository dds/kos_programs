// ============================================================
// landing_math.ks  -  Vacuum powered-descent math (0:/lib/landing_math.ks)
//
// Pure-ish helpers for airless-body landing guidance. The functions read
// SHIP state, but do not stage, deploy hardware, or mutate mission state.
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// Effective local gravity in meters per second squared.
// For descent trigger math we subtract centripetal acceleration from
// horizontal ground speed, so a fast near-surface pass does not overstate
// the burn needed to arrest vertical fall.
GLOBAL FUNCTION lmGravity {
    LOCAL radiusMag IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    IF radiusMag <= 0 { RETURN 0.01. }
    LOCAL gRaw IS SHIP:BODY:MU / (radiusMag * radiusMag).
    LOCAL groundSpeed IS SHIP:GROUNDSPEED.
    IF groundSpeed > 1 {
        SET gRaw TO gRaw - (groundSpeed * groundSpeed) / radiusMag.
    }
    RETURN MAX(0.01, gRaw).
}

GLOBAL FUNCTION lmMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

GLOBAL FUNCTION lmHorizontalVelocity {
    LOCAL upVec IS SHIP:UP:VECTOR.
    RETURN SHIP:VELOCITY:SURFACE - (VDOT(SHIP:VELOCITY:SURFACE, upVec) * upVec).
}

GLOBAL FUNCTION lmDownSpeed {
    RETURN MAX(0, -SHIP:VERTICALSPEED).
}

// Horizontal stopping distance:
//
//   squared vf = squared vi + 2 a d
//
// To stop horizontal motion, vf = 0 and acceleration opposes motion, so
//   0 = squared vh - 2 ah d
//   d = squared vh / (2 ah)
//
// ah is a conservative reserved horizontal acceleration. It is deliberately
// supplied by the caller so policy remains outside the physics helper.
GLOBAL FUNCTION lmHorizontalBrakeDistance {
    PARAMETER horizontalSpeed.
    PARAMETER horizontalAcc.
    IF horizontalAcc <= 0 { RETURN 999999. }
    RETURN (horizontalSpeed * horizontalSpeed) / (2 * horizontalAcc).
}

// Vertical suicide-burn height:
//
//   squared vf = squared vi + 2 a h
//
// Let downward speed vv be positive and net upward acceleration be
// aNet = aMax - g. Touchdown burn condition uses vf = 0:
//   0 = squared vv - 2(aMax - g)h
//   h = squared vv / (2(aMax - g))
//
// Recomputing every tick naturally accounts for fuel mass changing aMax.
GLOBAL FUNCTION lmVerticalBurnDistance {
    PARAMETER downSpeed.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    LOCAL netAcc IS maxAcc - gravAcc.
    IF netAcc <= 0 { RETURN 999999. }
    RETURN (downSpeed * downSpeed) / (2 * netAcc).
}

// Constant-gravity vertical time to terrain. Positive roots only; returns
// a large sentinel if the quadratic is not meaningful for the current state.
GLOBAL FUNCTION lmTimeToImpact {
    LOCAL gravAcc IS lmGravity().
    LOCAL verticalSpeed IS SHIP:VERTICALSPEED.
    LOCAL radarAlt IS ALT:RADAR.
    IF radarAlt <= 0 { RETURN 0. }
    LOCAL disc IS verticalSpeed * verticalSpeed + 2 * radarAlt * gravAcc.
    IF disc < 0 OR gravAcc <= 0 { RETURN 999999. }
    RETURN (SQRT(disc) + verticalSpeed) / gravAcc.
}

GLOBAL FUNCTION lmDescentSpeed {
    PARAMETER radarAlt.
    PARAMETER touchdownSpeed.
    PARAMETER uprightAlt.
    IF radarAlt > 1000 { RETURN 20. }
    IF radarAlt > 100 {
        RETURN 8 + (radarAlt - 100) / 900 * 12.
    }
    IF radarAlt > uprightAlt {
        RETURN touchdownSpeed + (radarAlt - uprightAlt)
            / (100 - uprightAlt) * (8 - touchdownSpeed).
    }
    RETURN touchdownSpeed.
}

GLOBAL FUNCTION lmDistanceToTarget {
    PARAMETER targetLat.
    PARAMETER targetLng.
    RETURN geoDistance(SHIP:LATITUDE, SHIP:LONGITUDE, targetLat, targetLng).
}

GLOBAL FUNCTION lmDirectionToTarget {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER upVec.
    PARAMETER shipPos.
    LOCAL rawVec IS LATLNG(targetLat, targetLng):POSITION - shipPos.
    LOCAL surfaceVec IS VXCL(upVec, rawVec).
    IF surfaceVec:MAG < 0.01 { RETURN V(0,0,0). }
    RETURN surfaceVec:NORMALIZED.
}

GLOBAL FUNCTION lmRetroSteering {
    PARAMETER horizontalVel.
    PARAMETER surfaceVel.
    PARAMETER upVec.
    IF surfaceVel:MAG < 1 { RETURN upVec. }
    LOCAL retroVec IS (-surfaceVel):NORMALIZED.
    IF horizontalVel:MAG < 0.5 { RETURN retroVec. }
    LOCAL maxLean IS SIN(LAND_CFG_MAX_TILT).
    LOCAL leanMag IS MIN(maxLean, horizontalVel:MAG / 25).
    RETURN (retroVec + upVec * leanMag):NORMALIZED.
}

GLOBAL FUNCTION lmHoverSteering {
    PARAMETER horizontalVel.
    PARAMETER upVec.
    IF horizontalVel:MAG < 0.3 { RETURN upVec. }
    LOCAL maxLean IS SIN(LAND_CFG_MAX_TILT).
    LOCAL leanMag IS MIN(maxLean, horizontalVel:MAG / 10).
    RETURN (upVec + (-horizontalVel):NORMALIZED * leanMag):NORMALIZED.
}

GLOBAL FUNCTION lmApproachSteering {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER targetHorizontalSpeed.
    PARAMETER horizontalVel.
    PARAMETER upVec.
    PARAMETER shipPos.

    LOCAL targetDir IS lmDirectionToTarget(targetLat, targetLng,
        upVec, shipPos).
    LOCAL maxLean IS SIN(LAND_CFG_MAX_TILT).
    LOCAL desiredVel IS targetDir * targetHorizontalSpeed.
    LOCAL correctionVec IS desiredVel - horizontalVel.
    IF correctionVec:MAG <= 0.1 { RETURN upVec. }

    LOCAL leanVec IS correctionVec:NORMALIZED * MIN(maxLean, correctionVec:MAG / 20).
    RETURN (upVec + leanVec):NORMALIZED.
}

GLOBAL FUNCTION lmVerticalThrottle {
    PARAMETER targetVerticalSpeed.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    PARAMETER verticalSpeed.
    IF maxAcc <= 0 { RETURN 0. }
    LOCAL speedErr IS targetVerticalSpeed - verticalSpeed.
    RETURN MAX(0, MIN(1, (gravAcc / maxAcc) + speedErr * 0.3)).
}

GLOBAL FUNCTION lmTerrainClearanceCheck {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER startUt.
    PARAMETER endUt.
    PARAMETER stepSec.
    PARAMETER minClearance.
    PARAMETER safeAlt.

    LOCAL sampleUt IS startUt.
    LOCAL bodyRad IS SHIP:BODY:RADIUS.
    LOCAL bdy IS SHIP:BODY.

    UNTIL sampleUt > endUt {
        LOCAL pos IS POSITIONAT(SHIP, sampleUt).
        LOCAL altRadius IS (pos - POSITIONAT(bdy, sampleUt)):MAG.
        LOCAL altDatum IS altRadius - bodyRad.

        IF altDatum < safeAlt {
            LOCAL geo IS bdy:GEOPOSITIONOF(pos).
            LOCAL terrain IS LATLNG(geo:LAT, geo:LNG):TERRAINHEIGHT.
            IF (altDatum - terrain) <= minClearance {
                RETURN geoDistance(geo:LAT, geo:LNG, targetLat, targetLng).
            }
        }
        SET sampleUt TO sampleUt + stepSec.
    }
    RETURN 0.
}

GLOBAL FUNCTION lmTerrainImpactAngle {
    PARAMETER startUt.
    PARAMETER endUt.
    PARAMETER stepSec.
    PARAMETER minClearance.
    PARAMETER safeAlt.

    LOCAL sampleUt IS startUt.
    LOCAL bodyRad IS SHIP:BODY:RADIUS.
    LOCAL bdy IS SHIP:BODY.

    UNTIL sampleUt > endUt {
        LOCAL pos IS POSITIONAT(SHIP, sampleUt).
        LOCAL altRadius IS (pos - POSITIONAT(bdy, sampleUt)):MAG.
        LOCAL altDatum IS altRadius - bodyRad.

        IF altDatum < safeAlt {
            LOCAL geo IS bdy:GEOPOSITIONOF(pos).
            LOCAL terrain IS LATLNG(geo:LAT, geo:LNG):TERRAINHEIGHT.
            IF (altDatum - terrain) <= minClearance {
                LOCAL prevPos IS POSITIONAT(SHIP, sampleUt - stepSec).
                LOCAL velVec IS pos - prevPos.
                LOCAL upVec IS (pos - POSITIONAT(bdy, sampleUt)):NORMALIZED.
                LOCAL downRate IS -VDOT(velVec, upVec).
                LOCAL sideRate IS VXCL(upVec, velVec):MAG.
                IF downRate <= 0 { RETURN 0. }
                IF sideRate < 0.01 { RETURN 90. }
                RETURN ARCTAN2(downRate, sideRate).
            }
        }
        SET sampleUt TO sampleUt + stepSec.
    }
    RETURN -1.
}
