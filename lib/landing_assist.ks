// ============================================================
// landing_assist.ks - Targeted deorbit + assist-stage release
// (0:/lib/landing_assist.ks)
// ============================================================

GLOBAL LANDING_CFG IS LEXICON(
    "DEORBIT_PE",        5000,
    "TARGET_LAT",           0,
    "TARGET_LNG",           0,
    "TARGET_BODY",         "",
    "TARGET_WAYPOINT",     "",
    "TARGET_LOCK",      FALSE,
    "TARGET_TOLERANCE",  2500,
    "GUIDANCE_ALT",      5000,
    "ASSIST_TARGET_SPEED", 80.0,
    "ASSIST_MIN_ALT",      800,
    "ASSIST_THROTTLE",       1,
    "ASSIST_RELEASE_ALT",  100,
    "ASSIST_RELEASE_HSPEED", 0.5,
    "ASSIST_RELEASE_VSPEED", 0.0,
    "ASSIST_RELEASE_ALT_TOL", 5,
    "ASSIST_RELEASE_H_TOL", 0.3,
    "ASSIST_RELEASE_V_TOL", 0.3,
    "ASSIST_RELEASE_HOLD", 1.0,
    "ASSIST_DESCENT_SPEED", 15.0,
    "ASSIST_MAX_TILT",     18,
    "ASSIST_DECOUPLER_TAG", "landing_assist_decoupler",
    "ASSIST_FLYAWAY",     FALSE,
    "ASSIST_FLYAWAY_TIME", 4.0,
    "ASSIST_FLYAWAY_THROTTLE", 0.6,
    "ASSIST_RELEASE_ON_SURFACE", FALSE,
    "ASSIST_SURFACE_BRAKE_HSPEED", 80.0,
    "ASSIST_SURFACE_BRAKE_THROTTLE", 1.0,
    "ASSIST_SURFACE_BRAKE_LEAD", 15.0,
    "ASSIST_SURFACE_BRAKE_MARGIN", 600.0,
    "ASSIST_SURFACE_BRAKE_FACTOR", 1.8,
    "ASSIST_SURFACE_BRAKE_RELEASE_HSPEED", 5.0,
    "ASSIST_SURFACE_BRAKE_AOA", 60.0,
    "ASSIST_SURFACE_FINAL_SPEED", 0.8,
    "ASSIST_SURFACE_FINAL_HSPEED", 2.0,
    "ASSIST_SURFACE_SETTLE_TIME", 5.0,
    "ASSIST_SURFACE_TIPOVER", TRUE,
    "ASSIST_SURFACE_TIP_TIME", 4.0,
    "DEORBIT_OVERSHOOT", 1500.0,
    "DEORBIT_OVERSHOOT_TOLERANCE", 1200.0,
    "SITE_GRID_RADIUS", 625.0,
    "SITE_GRID_STEP", 250.0,
    "SITE_MAX_SLOPE", 12.0
).

GLOBAL landingAbortFlag IS FALSE.

GLOBAL FUNCTION landingTargetedDeorbit {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set - refusing blind landing deorbit.").
        RETURN FALSE.
    }

    mLogWarn("STATS landing target source=" + landingTarget["SOURCE"]
        + " lat=" + ROUND(landingTarget["LAT"],4)
        + " lng=" + ROUND(landingTarget["LNG"],4)).
    SET LANDING_CFG["TARGET_LAT"] TO landingTarget["LAT"].
    SET LANDING_CFG["TARGET_LNG"] TO landingTarget["LNG"].
    mLog("Landing deorbit target: " + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)
        + " from " + landingTarget["SOURCE"] + ".").

    LOCAL aimTarget IS _landingOvershootTarget(landingTarget).
    RETURN targetedDeorbitAt(
        aimTarget["LAT"],
        aimTarget["LNG"],
        LANDING_CFG["DEORBIT_PE"],
        LANDING_CFG["TARGET_TOLERANCE"]).
}

GLOBAL FUNCTION landingAssistStage {
    mLogPhase("LANDING ASSIST").

    LOCAL decoupler IS _taggedDecoupler(LANDING_CFG["ASSIST_DECOUPLER_TAG"]).
    IF decoupler = 0 {
        mLogWarn("No assist decoupler tagged '"
            + LANDING_CFG["ASSIST_DECOUPLER_TAG"] + "' - skipping assist.").
        RETURN FALSE.
    }

    IF LANDING_CFG["ASSIST_RELEASE_ON_SURFACE"] {
        RETURN _assistSurfaceRelease(decoupler).
    }

    SET SAS TO FALSE.
    LOCAL stableStart IS 0.
    mLog("Assist descent: release at "
        + ROUND(LANDING_CFG["ASSIST_RELEASE_ALT"],0) + "m, h="
        + LANDING_CFG["ASSIST_RELEASE_HSPEED"] + "m/s, v="
        + LANDING_CFG["ASSIST_RELEASE_VSPEED"] + "m/s.").
    HUDTEXT("Assist precision descent", 3, 2, 14, YELLOW, FALSE).

    UNTIL landingAbortFlag {
        LOCAL hVel IS _horizontalSurfaceVelocity().
        LOCAL hSpeed IS hVel:MAG.
        LOCAL radarAlt IS ALT:RADAR.
        LOCAL vSpeed IS SHIP:VERTICALSPEED.

        LOCK STEERING TO _assistSteering(hVel, hSpeed).

        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            LOCAL releaseAlt IS LANDING_CFG["ASSIST_RELEASE_ALT"].
            LOCAL altErr IS radarAlt - releaseAlt.
            LOCAL targetV IS -MAX(
                -2,
                MIN(LANDING_CFG["ASSIST_DESCENT_SPEED"], altErr * 0.2)).
            IF ABS(altErr) <= LANDING_CFG["ASSIST_RELEASE_ALT_TOL"] {
                SET targetV TO LANDING_CFG["ASSIST_RELEASE_VSPEED"].
            }

            LOCAL grav IS _localGravity().
            LOCAL desiredAcc IS (targetV - vSpeed) * 0.35.
            LOCAL thrott IS (grav + desiredAcc) / maxAcc.
            LOCK THROTTLE TO MAX(0, MIN(LANDING_CFG["ASSIST_THROTTLE"], thrott)).
        }

        IF _assistReleaseStable(hSpeed, vSpeed, radarAlt) {
            IF stableStart = 0 { SET stableStart TO TIME:SECONDS. }
            IF TIME:SECONDS - stableStart >= LANDING_CFG["ASSIST_RELEASE_HOLD"] {
                BREAK.
            }
        } ELSE {
            SET stableStart TO 0.
        }

        IF _needsStage() {
            mLogWarn("Assist stage needs staging before release target - separating now.").
            BREAK.
        }

        HUDTEXT("Assist alt:" + ROUND(radarAlt,0)
            + "m h:" + ROUND(hSpeed,2)
            + " v:" + ROUND(vSpeed,2),
            1, 2, 13, YELLOW, FALSE).
        WAIT 0.05.
    }

    IF landingAbortFlag {
        LOCK THROTTLE TO 0.
        RETURN FALSE.
    }

    LOCK THROTTLE TO 0.
    WAIT 0.2.
    mLog("Assist release: alt=" + ROUND(ALT:RADAR,1)
        + "m h=" + ROUND(_horizontalSurfaceVelocity():MAG,2)
        + "m/s v=" + ROUND(SHIP:VERTICALSPEED,2) + "m/s.").

    _decouplePart(decoupler).
    WAIT 0.5.

    IF LANDING_CFG["ASSIST_FLYAWAY"] {
        mLog("Assist flyaway burn.").
        LOCK STEERING TO (SHIP:FACING:RIGHTVECTOR + SHIP:UP):NORMALIZED.
        WAIT 1.
        LOCK THROTTLE TO LANDING_CFG["ASSIST_FLYAWAY_THROTTLE"].
        WAIT LANDING_CFG["ASSIST_FLYAWAY_TIME"].
        LOCK THROTTLE TO 0.
    }

    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    RETURN TRUE.
}

GLOBAL FUNCTION landingImpactWithinTolerance {
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN TRUE. }

    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set - refusing descent impact check.").
        RETURN FALSE.
    }
    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available - cannot verify landing impact.").
        RETURN FALSE.
    }

    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT {
        mLogWarn("STATS landing-impact status=no-impact target="
            + ROUND(landingTarget["LAT"],4)
            + "," + ROUND(landingTarget["LNG"],4)).
        RETURN FALSE.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _assistGeoDistance(
        impactPos:LAT,
        impactPos:LNG,
        landingTarget["LAT"],
        landingTarget["LNG"]).
    LOCAL ok IS dist <= LANDING_CFG["TARGET_TOLERANCE"].
    mLogWarn("STATS landing-impact status=" + ok
        + " distKm=" + ROUND(dist/1000,2)
        + " toleranceKm=" + ROUND(LANDING_CFG["TARGET_TOLERANCE"]/1000,2)
        + " impact=" + ROUND(impactPos:LAT,4)
        + "," + ROUND(impactPos:LNG,4)
        + " target=" + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)).
    RETURN ok.
}

GLOBAL FUNCTION landingImpactAcceptableForAssist {
    IF LANDING_CFG["DEORBIT_OVERSHOOT"] <= 0 { RETURN landingImpactWithinTolerance(). }
    IF NOT ADDONS:TR:AVAILABLE { RETURN FALSE. }
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN FALSE. }
    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT { RETURN FALSE. }
    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _assistGeoDistance(
        impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL maxDist IS LANDING_CFG["DEORBIT_OVERSHOOT"]
        + LANDING_CFG["DEORBIT_OVERSHOOT_TOLERANCE"].
    LOCAL ok IS dist <= maxDist.
    mLogWarn("STATS landing-impact-assist status=" + ok
        + " distKm=" + ROUND(dist/1000,2)
        + " allowedKm=" + ROUND(maxDist/1000,2)
        + " impact=" + ROUND(impactPos:LAT,4)
        + "," + ROUND(impactPos:LNG,4)
        + " target=" + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)).
    RETURN ok.
}

LOCAL FUNCTION _assistSurfaceRelease {
    PARAMETER decoupler.

    SET SAS TO FALSE.
    LOCAL landingTarget IS landingResolveTarget().
    IF landingTarget["FOUND"] {
        LOCAL site IS _assistSelectLandingSite(landingTarget["LAT"], landingTarget["LNG"]).
        IF site["FOUND"] {
            SET landingTarget["LAT"] TO site["LAT"].
            SET landingTarget["LNG"] TO site["LNG"].
            SET landingTarget["SOURCE"] TO "site-grid".
        }
    }
    mLogWarn("STATS assist-surface setup release=surface finalV="
        + LANDING_CFG["ASSIST_SURFACE_FINAL_SPEED"]
        + " settle=" + LANDING_CFG["ASSIST_SURFACE_SETTLE_TIME"]).
    IF landingTarget["FOUND"] {
        mLogWarn("STATS assist-surface target source=" + landingTarget["SOURCE"]
            + " lat=" + ROUND(landingTarget["LAT"],4)
            + " lng=" + ROUND(landingTarget["LNG"],4)).
    } ELSE {
        mLogWarn("STATS assist-surface target status=missing").
    }
    mLog("Emergency surface assist: landing whole stack on second stage.").
    HUDTEXT("Emergency carrier landing", 5, 2, 15, YELLOW, FALSE).

    LOCAL nextStatsAlt IS 5000.
    LOCAL lastMode IS "".
    LOCAL brakeCommitted IS FALSE.
    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" OR landingAbortFlag {
        LOCAL hVel IS _horizontalSurfaceVelocity().
        LOCAL hSpeed IS hVel:MAG.
        LOCAL radarAlt IS ALT:RADAR.
        LOCAL vSpeed IS SHIP:VERTICALSPEED.
        LOCAL targetDistM IS -1.
        IF landingTarget["FOUND"] {
            SET targetDistM TO _assistGeoDistance(
                SHIP:GEOPOSITION:LAT,
                SHIP:GEOPOSITION:LNG,
                landingTarget["LAT"],
                landingTarget["LNG"]).
        }
        LOCAL mode_ IS "APPROACH".
        IF brakeCommitted {
            IF hSpeed > LANDING_CFG["ASSIST_SURFACE_FINAL_HSPEED"]
                    OR (radarAlt < 1000
                        AND vSpeed < -LANDING_CFG["ASSIST_DESCENT_SPEED"]) {
                SET mode_ TO "BRAKE".
            } ELSE {
                SET brakeCommitted TO FALSE.
            }
        } ELSE IF hSpeed > LANDING_CFG["ASSIST_SURFACE_BRAKE_HSPEED"] {
            IF _assistSurfaceBrakeReady(radarAlt, hSpeed, vSpeed, targetDistM) {
                SET brakeCommitted TO TRUE.
                SET mode_ TO "BRAKE".
            } ELSE {
                SET mode_ TO "COAST".
            }
        } ELSE IF radarAlt < 50 {
            SET mode_ TO "FINAL".
        }

        IF mode_ <> lastMode {
            mLogWarn("STATS assist-surface mode=" + mode_
                + " alt=" + ROUND(radarAlt,1)
                + " h=" + ROUND(hSpeed,1)
                + " v=" + ROUND(vSpeed,1)
                + " targetDistM=" + ROUND(targetDistM,0)).
            SET lastMode TO mode_.
        }

        IF mode_ = "COAST" OR mode_ = "BRAKE" {
            LOCK STEERING TO _surfaceRetrograde().
        } ELSE IF landingTarget["FOUND"] AND radarAlt < LANDING_CFG["GUIDANCE_ALT"] {
            LOCK STEERING TO _assistTargetSteering(landingTarget, hVel, hSpeed).
        } ELSE {
            LOCK STEERING TO _assistSteering(hVel, hSpeed).
        }

        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            IF mode_ = "COAST" {
                LOCK THROTTLE TO 0.
            } ELSE IF mode_ = "BRAKE" {
                LOCAL brakeThrottle IS LANDING_CFG["ASSIST_SURFACE_BRAKE_THROTTLE"].
                LOCAL aoa IS _assistTargetAoa(targetDistM, radarAlt).
                IF targetDistM >= 0
                        AND aoa < LANDING_CFG["ASSIST_SURFACE_BRAKE_AOA"]
                        AND radarAlt > 500 {
                    SET brakeThrottle TO MAX(0.3, brakeThrottle * 0.5).
                }
                IF vSpeed < -LANDING_CFG["ASSIST_DESCENT_SPEED"] {
                    SET brakeThrottle TO MIN(1, brakeThrottle + 0.2).
                }
                LOCK THROTTLE TO MAX(0.1, MIN(LANDING_CFG["ASSIST_THROTTLE"], brakeThrottle)).
            } ELSE {
                LOCAL targetV IS -MAX(
                    LANDING_CFG["ASSIST_SURFACE_FINAL_SPEED"],
                    MIN(LANDING_CFG["ASSIST_DESCENT_SPEED"], radarAlt * 0.2)).
                IF radarAlt < 20 {
                    SET targetV TO -LANDING_CFG["ASSIST_SURFACE_FINAL_SPEED"].
                }

                LOCAL grav IS _localGravity().
                LOCAL desiredAcc IS (targetV - vSpeed) * 0.35.
                LOCAL thrott IS (grav + desiredAcc) / maxAcc.
                LOCK THROTTLE TO MAX(0, MIN(LANDING_CFG["ASSIST_THROTTLE"], thrott)).
            }
        }

        HUDTEXT("Carrier alt:" + ROUND(radarAlt,0)
            + "m h:" + ROUND(hSpeed,2)
            + " v:" + ROUND(vSpeed,2),
            1, 2, 13, YELLOW, FALSE).
        IF radarAlt < nextStatsAlt {
            mLogWarn("STATS assist-surface descent alt=" + ROUND(radarAlt,1)
                + " h=" + ROUND(hSpeed,2)
                + " v=" + ROUND(vSpeed,2)
                + " targetDistM=" + ROUND(targetDistM,0)
                + " maxAcc=" + ROUND(_safeMaxAcc(),2)).
            SET nextStatsAlt TO nextStatsAlt / 2.
            IF nextStatsAlt < 100 { SET nextStatsAlt TO 100. }
        }
        WAIT 0.05.
    }

    LOCK THROTTLE TO 0.
    IF landingAbortFlag {
        mLogError("Surface assist aborted before touchdown.").
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        SET SAS TO TRUE.
        RETURN FALSE.
    }
    IF NOT (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED") {
        mLogError("Surface assist ended without landed status: " + SHIP:STATUS + ".").
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        SET SAS TO TRUE.
        RETURN FALSE.
    }
    WAIT LANDING_CFG["ASSIST_SURFACE_SETTLE_TIME"].
    mLog("Carrier touchdown: status=" + SHIP:STATUS
        + " h=" + ROUND(_horizontalSurfaceVelocity():MAG,2)
        + " v=" + ROUND(SHIP:VERTICALSPEED,2)
        + " roll=" + ROUND(SHIP:FACING:ROLL,1)
        + " pitch=" + ROUND(SHIP:FACING:PITCH,1)).
    mLogWarn("STATS assist-surface result status=" + SHIP:STATUS
        + " h=" + ROUND(_horizontalSurfaceVelocity():MAG,2)
        + " roll=" + ROUND(SHIP:FACING:ROLL,1)
        + " pitch=" + ROUND(SHIP:FACING:PITCH,1)).

    IF LANDING_CFG["ASSIST_SURFACE_TIPOVER"] {
        mLog("Tipping carrier before rover release.").
        LOCK STEERING TO SHIP:FACING:RIGHTVECTOR.
        WAIT LANDING_CFG["ASSIST_SURFACE_TIP_TIME"].
    }

    _decouplePart(decoupler).
    WAIT 0.5.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    RETURN TRUE.
}

GLOBAL FUNCTION landingResolveTarget {
    LOCAL result IS LEXICON().
    result:ADD("FOUND", FALSE).
    result:ADD("LAT", 0).
    result:ADD("LNG", 0).
    result:ADD("SOURCE", "none").

    IF LANDING_CFG["TARGET_WAYPOINT"] <> "" {
        LOCAL namedWp IS _waypointNamed(LANDING_CFG["TARGET_WAYPOINT"]).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Landing waypoint '" + LANDING_CFG["TARGET_WAYPOINT"]
            + "' not found on " + SHIP:BODY:NAME + ".").
    }

    IF LANDING_CFG["TARGET_LOCK"]
            AND (LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0) {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LANDING_CFG["TARGET_LAT"].
        SET result["LNG"] TO LANDING_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "locked LANDING_CFG".
        RETURN result.
    }

    LOCAL selectedWp IS _selectedWaypoint().
    IF selectedWp <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO selectedWp:GEOPOSITION:LAT.
        SET result["LNG"] TO selectedWp:GEOPOSITION:LNG.
        SET result["SOURCE"] TO "selected waypoint:" + selectedWp:NAME.
        RETURN result.
    }

    IF LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LANDING_CFG["TARGET_LAT"].
        SET result["LNG"] TO LANDING_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "LANDING_CFG".
        RETURN result.
    }

    RETURN result.
}

LOCAL FUNCTION _waypointNamed {
    PARAMETER waypointName.
    LOCAL allWps IS ALLWAYPOINTS().
    LOCAL targetName IS waypointName:TOUPPER.
    FOR wp IN allWps {
        IF wp:BODY:NAME = SHIP:BODY:NAME {
            IF wp:NAME:TOUPPER = targetName { RETURN wp. }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _selectedWaypoint {
    LOCAL allWps IS ALLWAYPOINTS().
    FOR wp IN allWps {
        IF wp:ISSELECTED {
            IF wp:BODY:NAME = SHIP:BODY:NAME { RETURN wp. }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _taggedDecoupler {
    PARAMETER tagName.
    FOR p IN SHIP:PARTS {
        IF p:TAG = tagName {
            IF p:HASMODULE("ModuleDecouple")
                    OR p:HASMODULE("ModuleAnchoredDecoupler") {
                RETURN p.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _decouplePart {
    PARAMETER partRef.
    IF partRef:HASMODULE("ModuleDecouple") {
        partRef:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF partRef:HASMODULE("ModuleAnchoredDecoupler") {
        partRef:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogWarn("Assist decoupler tag found, but no decouple module. Trying STAGE.").
        STAGE.
    }
}

LOCAL FUNCTION _horizontalSurfaceVelocity {
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL hVel IS SHIP:VELOCITY:SURFACE
        - (VDOT(SHIP:VELOCITY:SURFACE, upVec) * upVec).
    RETURN hVel.
}

LOCAL FUNCTION _assistSteering {
    PARAMETER hVel.
    PARAMETER hSpeed.

    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL steerVec IS upVec.
    IF hSpeed > LANDING_CFG["ASSIST_RELEASE_HSPEED"] {
        LOCAL maxLean IS SIN(LANDING_CFG["ASSIST_MAX_TILT"]).
        LOCAL lean IS MIN(maxLean, hSpeed / 10).
        SET steerVec TO (upVec + (-hVel):NORMALIZED * lean):NORMALIZED.
    }
    RETURN steerVec.
}

LOCAL FUNCTION _assistTargetSteering {
    PARAMETER landingTarget.
    PARAMETER hVel.
    PARAMETER hSpeed.

    LOCAL steerVec IS _assistSteering(hVel, hSpeed).
    LOCAL targetGeo IS LATLNG(landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL toTarget IS targetGeo:POSITION - SHIP:GEOPOSITION:POSITION.
    LOCAL lateral IS VXCL(SHIP:UP:VECTOR, toTarget).
    IF lateral:MAG < 0.001 { RETURN steerVec. }

    LOCAL dist IS _assistGeoDistance(
        SHIP:LATITUDE,
        SHIP:LONGITUDE,
        landingTarget["LAT"],
        landingTarget["LNG"]).
    IF dist < 25 { RETURN steerVec. }

    LOCAL maxLean IS SIN(LANDING_CFG["ASSIST_MAX_TILT"]).
    LOCAL lean IS MIN(maxLean, dist / 500).
    RETURN (steerVec:NORMALIZED + lateral:NORMALIZED * lean):NORMALIZED.
}

LOCAL FUNCTION _surfaceRetrograde {
    LOCAL sVel IS SHIP:VELOCITY:SURFACE.
    IF sVel:MAG < 0.1 { RETURN SHIP:UP:VECTOR. }
    RETURN (-sVel):NORMALIZED.
}

LOCAL FUNCTION _assistTargetAoa {
    PARAMETER targetDistM.
    PARAMETER radarAlt.
    IF targetDistM <= 0 { RETURN 90. }
    RETURN ARCTAN(radarAlt / targetDistM).
}

LOCAL FUNCTION _assistSurfaceBrakeReady {
    PARAMETER radarAlt.
    PARAMETER hSpeed.
    PARAMETER vSpeed.
    PARAMETER targetDistM IS -1.

    IF radarAlt < 500 { RETURN TRUE. }
    LOCAL maxAcc IS _safeMaxAcc().
    IF maxAcc <= 0 { RETURN FALSE. }
    LOCAL netAcc IS MAX(0.1, maxAcc - _localGravity()).
    LOCAL speed IS SQRT(hSpeed^2 + MAX(0, -vSpeed)^2).
    LOCAL brakeDist IS ((speed^2) / (2 * netAcc))
        * LANDING_CFG["ASSIST_SURFACE_BRAKE_FACTOR"]
        + LANDING_CFG["ASSIST_SURFACE_BRAKE_MARGIN"].
    LOCAL verticalAlt IS ((MAX(0, -vSpeed)^2) / (2 * netAcc))
        * LANDING_CFG["ASSIST_SURFACE_BRAKE_FACTOR"]
        + LANDING_CFG["ASSIST_SURFACE_BRAKE_MARGIN"].

    IF targetDistM >= 0 {
        IF _assistTargetAoa(targetDistM, radarAlt)
                >= LANDING_CFG["ASSIST_SURFACE_BRAKE_AOA"] {
            RETURN TRUE.
        }
        IF targetDistM <= brakeDist { RETURN TRUE. }
        IF radarAlt <= verticalAlt { RETURN TRUE. }
        RETURN FALSE.
    }

    IF ADDONS:KE:AVAILABLE {
        LOCAL countdown IS ADDONS:KE:SUICIDEBURNCOUNTDOWN.
        IF countdown <= LANDING_CFG["ASSIST_SURFACE_BRAKE_LEAD"] {
            RETURN TRUE.
        }
    }
    RETURN radarAlt <= brakeDist.
}

LOCAL FUNCTION _landingOvershootTarget {
    PARAMETER landingTarget.
    LOCAL out IS LEXICON(
        "LAT", landingTarget["LAT"],
        "LNG", landingTarget["LNG"]
    ).
    LOCAL overshoot IS LANDING_CFG["DEORBIT_OVERSHOOT"].
    IF overshoot <= 0 { RETURN out. }

    LOCAL hVel IS _horizontalSurfaceVelocity().
    IF hVel:MAG < 0.1 { RETURN out. }
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL northVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE + 0.01, SHIP:LONGITUDE):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL eastVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE, SHIP:LONGITUDE + 0.01):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL northM IS VDOT(hVel:NORMALIZED, northVec) * overshoot.
    LOCAL eastM IS VDOT(hVel:NORMALIZED, eastVec) * overshoot.
    LOCAL shifted IS _assistOffsetLatLng(landingTarget["LAT"], landingTarget["LNG"], northM, eastM).
    SET out["LAT"] TO shifted["LAT"].
    SET out["LNG"] TO shifted["LNG"].
    mLogWarn("STATS deorbit overshoot target actual="
        + ROUND(landingTarget["LAT"],4) + "," + ROUND(landingTarget["LNG"],4)
        + " aim=" + ROUND(out["LAT"],4) + "," + ROUND(out["LNG"],4)
        + " overshootM=" + ROUND(overshoot,0)).
    RETURN out.
}

LOCAL FUNCTION _assistOffsetLatLng {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER northM.
    PARAMETER eastM.
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(lat)).
    RETURN LEXICON(
        "LAT", lat + northM * degPerM,
        "LNG", lng + eastM * degPerM / lonScale
    ).
}

LOCAL FUNCTION _assistSelectLandingSite {
    PARAMETER targetLat.
    PARAMETER targetLng.
    LOCAL out IS LEXICON(
        "FOUND", FALSE,
        "LAT", targetLat,
        "LNG", targetLng,
        "SLOPE", -1,
        "DIST", 0
    ).
    IF NOT ADDONS:SCANSAT:AVAILABLE { RETURN out. }
    LOCAL radius IS LANDING_CFG["SITE_GRID_RADIUS"].
    LOCAL step IS LANDING_CFG["SITE_GRID_STEP"].
    LOCAL maxSlope IS LANDING_CFG["SITE_MAX_SLOPE"].
    LOCAL bestScore IS 999999999.
    LOCAL samples IS 0.
    LOCAL known IS 0.

    FROM { LOCAL north_ IS -radius. } UNTIL north_ > radius STEP { SET north_ TO north_ + step. } DO {
        FROM { LOCAL east_ IS -radius. } UNTIL east_ > radius STEP { SET east_ TO east_ + step. } DO {
            LOCAL pos IS _assistOffsetLatLng(targetLat, targetLng, north_, east_).
            LOCAL geo IS LATLNG(pos["LAT"], pos["LNG"]).
            SET samples TO samples + 1.
            LOCAL elev IS ADDONS:SCANSAT:ELEVATION(SHIP:BODY, geo).
            IF elev >= 0 {
                SET known TO known + 1.
                LOCAL slope IS ADDONS:SCANSAT:SLOPE(SHIP:BODY, geo).
                IF slope >= 0 AND slope <= maxSlope {
                    LOCAL dist IS SQRT(north_^2 + east_^2).
                    LOCAL score IS slope * 100 + dist / 20.
                    IF score < bestScore {
                        SET bestScore TO score.
                        SET out["FOUND"] TO TRUE.
                        SET out["LAT"] TO pos["LAT"].
                        SET out["LNG"] TO pos["LNG"].
                        SET out["SLOPE"] TO slope.
                        SET out["DIST"] TO dist.
                    }
                }
            }
        }
        WAIT 0.01.
    }
    IF out["FOUND"] {
        mLogWarn("STATS assist-site result status=selected selected="
            + ROUND(out["LAT"],4) + "," + ROUND(out["LNG"],4)
            + " distM=" + ROUND(out["DIST"],0)
            + " slope=" + ROUND(out["SLOPE"],1)
            + " samples=" + samples
            + " known=" + known).
    } ELSE {
        mLogWarn("STATS assist-site result status=no-site samples="
            + samples + " known=" + known).
    }
    RETURN out.
}

LOCAL FUNCTION _assistGeoDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL oRad IS SHIP:BODY:RADIUS.
    LOCAL dLat IS lat2 - lat1.
    LOCAL dLng IS lng2 - lng1.
    LOCAL a IS SIN(dLat/2)^2
        + COS(lat1) * COS(lat2) * SIN(dLng/2)^2.
    LOCAL c IS 2 * ARCSIN(MIN(1, SQRT(a))).
    RETURN oRad * c * CONSTANT:PI / 180.
}

LOCAL FUNCTION _assistReleaseStable {
    PARAMETER hSpeed.
    PARAMETER vSpeed.
    PARAMETER radarAlt.

    RETURN ABS(radarAlt - LANDING_CFG["ASSIST_RELEASE_ALT"])
            <= LANDING_CFG["ASSIST_RELEASE_ALT_TOL"]
        AND hSpeed <= LANDING_CFG["ASSIST_RELEASE_HSPEED"]
            + LANDING_CFG["ASSIST_RELEASE_H_TOL"]
        AND ABS(vSpeed - LANDING_CFG["ASSIST_RELEASE_VSPEED"])
            <= LANDING_CFG["ASSIST_RELEASE_V_TOL"].
}

LOCAL FUNCTION _localGravity {
    LOCAL radiusNow IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    RETURN SHIP:BODY:MU / (radiusNow^2).
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}
