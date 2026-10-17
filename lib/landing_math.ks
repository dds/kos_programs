// ============================================================
// landing_math.ks  -  Vacuum powered-descent math (0:/lib/landing_math.ks)
//
// Pure-ish helpers for airless-body landing guidance. The functions read
// SHIP state, but do not stage, deploy hardware, or mutate mission state.
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// Same-SOI POSITIONAT is relative to the body's CURRENT center in KSP.
// Subtracting POSITIONAT(body, ut) would inject its parent-orbit motion.
// GEOPOSITIONOF uses current axes too: remove rotation since now to obtain
// the ground coordinates at arrival. These helpers are for local landings,
// not trajectories crossing into another body's SOI.
GLOBAL FUNCTION lmGroundGeoAt {
    PARAMETER ut.
    LOCAL bdy IS SHIP:BODY.
    LOCAL geo IS bdy:GEOPOSITIONOF(POSITIONAT(SHIP, ut)).
    LOCAL longitude_ IS geo:LNG.
    IF ABS(bdy:ROTATIONPERIOD) > 0.01 {
        SET longitude_ TO longitude_ - 360 * (ut - TIME:SECONDS) / bdy:ROTATIONPERIOD.
    }
    RETURN LATLNG(geo:LAT, longitude_).
}

// A future position/velocity expressed in the body's current surface frame.
// Keep radius so the derivative includes vertical speed; do not mix in the
// parent-orbit motion from POSITIONAT(body, ut).
GLOBAL FUNCTION lmGroundPositionAt {
    PARAMETER ut.
    LOCAL relativePos IS POSITIONAT(SHIP, ut) - SHIP:BODY:POSITION.
    LOCAL geo IS lmGroundGeoAt(ut).
    RETURN geo:ALTITUDEPOSITION(relativePos:MAG - SHIP:BODY:RADIUS)
        - SHIP:BODY:POSITION.
}

GLOBAL FUNCTION lmGroundVelocityAt {
    PARAMETER ut.
    RETURN (lmGroundPositionAt(ut) - lmGroundPositionAt(ut - 0.5)) / 0.5.
}

// Spherical along-track/cross-track distances relative to the trajectory
// tangent at impact. No flat-plane Pythagoras: chord sag is NOT cross-track.
// This works across the pole/date line, without choosing a cross-product sign.
GLOBAL FUNCTION lmSurfaceTrackOffset {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER impactLat.
    PARAMETER impactLng.
    PARAMETER groundVelocity.
    LOCAL targetUp IS (LATLNG(targetLat, targetLng):ALTITUDEPOSITION(0)
        - SHIP:BODY:POSITION):NORMALIZED.
    LOCAL impactUp IS (LATLNG(impactLat, impactLng):ALTITUDEPOSITION(0)
        - SHIP:BODY:POSITION):NORMALIZED.
    LOCAL tangent IS VXCL(impactUp, groundVelocity).
    IF tangent:MAG < 0.01 {
        RETURN LEXICON("VALID", FALSE, "DIST", 999999999,
            "DOWNFIELD", -999999999, "CROSS", 999999999).
    }
    SET tangent TO tangent:NORMALIZED.
    LOCAL alongCos IS VDOT(targetUp, impactUp).
    LOCAL alongSin IS -VDOT(targetUp, tangent).
    LOCAL crossVec IS targetUp - alongCos * impactUp + alongSin * tangent.
    // Signed residual for measured node-response solves. Its handedness
    // need not be assumed: both probe nodes use this same convention.
    LOCAL crossSin IS VDOT(targetUp, VCRS(impactUp, tangent)).
    LOCAL metersPerDegree IS SHIP:BODY:RADIUS * CONSTANT:PI / 180.
    RETURN LEXICON(
        "VALID", TRUE,
        "DIST", ARCCOS(MAX(-1, MIN(1, alongCos))) * metersPerDegree,
        "DOWNFIELD", ARCTAN2(alongSin, alongCos) * metersPerDegree,
        "CROSS", ARCSIN(MAX(0, MIN(1, crossVec:MAG))) * metersPerDegree,
        "SIGNED_CROSS", ARCSIN(MAX(-1, MIN(1, crossSin))) * metersPerDegree
    ).
}

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

// Simultaneous horizontal/vertical stop, not two independent full-thrust
// stops. Reserve full gravity even while orbital speed still supports weight.
// Precision actuation and the economy ignition/flare envelopes use this
// budget. The economy main-burn vector solver lives in landing_brake.ks.
GLOBAL FUNCTION lmBrakeNetAcc {
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    RETURN MAX(0, maxAcc - gravAcc)
        * MAX(0.1, MIN(1, LANDING_BRAKE_ACCEL_FRACTION)).
}

GLOBAL FUNCTION lmBrakeEnvelope {
    PARAMETER horizontalSpeed.
    PARAMETER downSpeed.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    PARAMETER delay.
    LOCAL netAcc IS lmBrakeNetAcc(maxAcc, gravAcc).
    IF netAcc <= 0 {
        RETURN LEXICON("H", 999999999, "V", 999999999).
    }
    LOCAL futureDown IS MAX(0, downSpeed + gravAcc * delay).
    LOCAL speed IS SQRT(horizontalSpeed ^ 2 + futureDown ^ 2).
    LOCAL stopTime IS speed / netAcc * MAX(1, BURN_MARGIN).
    RETURN LEXICON(
        "H", horizontalSpeed * (delay + stopTime / 2),
        "V", MAX(0, downSpeed * delay + gravAcc * delay ^ 2 / 2)
            + futureDown * stopTime / 2
            + MAX(BRAKE_MARGIN, LANDING_BRAKE_CLEARANCE)
    ).
}

// Gravity-compensated velocity arrest. Adding g upward before normalizing
// avoids commanding full throttle almost sideways during a dangerous fall.
GLOBAL FUNCTION lmBrakeThrust {
    PARAMETER horizontalVel.
    PARAMETER verticalSpeed.
    PARAMETER targetVs.
    PARAMETER upVec.
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    LOCAL deltaVel IS -horizontalVel + (targetVs - verticalSpeed) * upVec.
    LOCAL thrustVec IS gravAcc * upVec.
    IF deltaVel:MAG > 0.001 {
        LOCAL netAcc IS MIN(lmBrakeNetAcc(maxAcc, gravAcc),
            deltaVel:MAG / MAX(0.1, LANDING_BRAKE_RESPONSE_TIME)).
        SET thrustVec TO thrustVec + deltaVel:NORMALIZED * netAcc.
    }
    // Faster descent comes from reducing support, never flipping the engine
    // downward to chase the scheduled vertical speed on a high-TWR craft.
    LOCAL upwardAcc IS VDOT(thrustVec, upVec).
    IF upwardAcc < 0 { SET thrustVec TO thrustVec - upwardAcc * upVec. }
    RETURN thrustVec.
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
    PARAMETER highSpeed IS 20.
    LOCAL fastSpeed IS MAX(20, highSpeed).
    IF radarAlt > 1500 { RETURN fastSpeed. }
    IF radarAlt > 1000 {
        RETURN 20 + (radarAlt - 1000) / 500 * (fastSpeed - 20).
    }
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
    LOCAL maxLean IS SIN(MAX_TILT).
    LOCAL leanMag IS MIN(maxLean, horizontalVel:MAG / 25).
    RETURN (retroVec + upVec * leanMag):NORMALIZED.
}

GLOBAL FUNCTION lmHoverSteering {
    PARAMETER horizontalVel.
    PARAMETER upVec.
    IF horizontalVel:MAG < 0.3 { RETURN upVec. }
    LOCAL maxLean IS SIN(MAX_TILT).
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
    PARAMETER targetWeight IS 1.25.

    LOCAL targetDir IS lmDirectionToTarget(targetLat, targetLng,
        upVec, shipPos).
    LOCAL maxLean IS TAN(MAX_TILT).
    LOCAL desiredVel IS targetDir * targetHorizontalSpeed.
    LOCAL correctionVec IS desiredVel - horizontalVel.
    IF correctionVec:MAG <= 0.1 { RETURN upVec. }

    // Convert velocity error to lateral acceleration, then tilt. The old
    // /20 lean gain took ~40 seconds to respond in Minmus gravity.
    // Weight affects response, not the speed/stopping-distance limit.
    LOCAL leanDemand IS correctionVec:MAG * MAX(0, targetWeight)
        / (MAX(0.01, lmGravity()) * MAX(1, LANDING_APPROACH_RESPONSE_TIME)).
    LOCAL leanVec IS correctionVec:NORMALIZED * MIN(maxLean, leanDemand).
    RETURN (upVec + leanVec):NORMALIZED.
}

GLOBAL FUNCTION lmApproachAcceleration {
    PARAMETER maxAcc.
    PARAMETER gravAcc.
    // Approach is upright, supporting weight, not a full-thrust sideways
    // braking burn. Reserve 20% for response/attitude lag.
    LOCAL thrustReserve IS SQRT(MAX(0, maxAcc ^ 2 - gravAcc ^ 2)).
    RETURN 0.8 * MAX(0, MIN(thrustReserve, gravAcc * TAN(MAX_TILT))).
}

GLOBAL FUNCTION lmApproachDescentSpeed {
    PARAMETER scheduledSpeed.
    PARAMETER height.
    PARAMETER distance.
    PARAMETER horizontalSpeed.
    PARAMETER lateralAcc.
    LOCAL transitDist IS MAX(0, distance - LANDING_HOVER_REFINE_SETTLE_RADIUS).
    LOCAL lateralTime IS 2 * SQRT(transitDist / MAX(0.01, lateralAcc))
        + horizontalSpeed / MAX(0.01, lateralAcc)
        + MAX(1, LANDING_APPROACH_RESPONSE_TIME).
    RETURN MIN(scheduledSpeed,
        MAX(0, height - LANDING_FINAL_HOVER_ALT) / lateralTime).
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
        LOCAL altRadius IS (pos - bdy:POSITION):MAG.
        LOCAL altDatum IS altRadius - bodyRad.

        IF altDatum < safeAlt {
            LOCAL geo IS lmGroundGeoAt(sampleUt).
            LOCAL terrain IS LATLNG(geo:LAT, geo:LNG):TERRAINHEIGHT.
            IF (altDatum - terrain) <= minClearance {
                RETURN geoDistance(geo:LAT, geo:LNG, targetLat, targetLng).
            }
        }
        SET sampleUt TO sampleUt + stepSec.
    }
    RETURN 0.
}

GLOBAL FUNCTION lmTerrainClearanceInfo {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER burnUt.
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
        LOCAL altRadius IS (pos - bdy:POSITION):MAG.
        LOCAL altDatum IS altRadius - bodyRad.

        IF altDatum < safeAlt {
            LOCAL geo IS lmGroundGeoAt(sampleUt).
            LOCAL terrain IS LATLNG(geo:LAT, geo:LNG):TERRAINHEIGHT.
            LOCAL clearance IS altDatum - terrain.
            IF clearance <= minClearance {
                LOCAL offset IS lmSurfaceTrackOffset(targetLat, targetLng,
                    geo:LAT, geo:LNG, lmGroundVelocityAt(sampleUt)).
                RETURN LEXICON(
                    "HIT", TRUE,
                    "UT", sampleUt,
                    "LAT", geo:LAT,
                    "LNG", geo:LNG,
                    "DIST", offset["DIST"],
                    "DOWNFIELD", offset["DOWNFIELD"],
                    "CLEARANCE", clearance
                ).
            }
        }
        SET sampleUt TO sampleUt + stepSec.
    }
    RETURN LEXICON("HIT", FALSE).
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
        LOCAL altRadius IS (pos - bdy:POSITION):MAG.
        LOCAL altDatum IS altRadius - bodyRad.

        IF altDatum < safeAlt {
            LOCAL geo IS lmGroundGeoAt(sampleUt).
            LOCAL terrain IS LATLNG(geo:LAT, geo:LNG):TERRAINHEIGHT.
            IF (altDatum - terrain) <= minClearance {
                LOCAL velVec IS lmGroundVelocityAt(sampleUt).
                LOCAL upVec IS lmGroundPositionAt(sampleUt):NORMALIZED.
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

// Fine-scale local terrain gradient, shared with archive diagnostics.
GLOBAL FUNCTION landingTerrainGrade {
    PARAMETER sampleLat.
    PARAMETER sampleLng.
    PARAMETER stepM.
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(sampleLat)).
    LOCAL hN IS LATLNG(sampleLat + stepM * degPerM, sampleLng):TERRAINHEIGHT.
    LOCAL hS IS LATLNG(sampleLat - stepM * degPerM, sampleLng):TERRAINHEIGHT.
    LOCAL hE IS LATLNG(sampleLat, sampleLng + stepM * degPerM / lonScale):TERRAINHEIGHT.
    LOCAL hW IS LATLNG(sampleLat, sampleLng - stepM * degPerM / lonScale):TERRAINHEIGHT.
    // Magnitude of the terrain gradient, rather than adding both slopes.
    RETURN SQRT(((hN - hS) / (2 * stepM)) ^ 2
        + ((hE - hW) / (2 * stepM)) ^ 2).
}
