// ============================================================
// landing.ks  —  Powered descent + landing  (0:/lib/landing.ks)
// ============================================================

GLOBAL LANDING_CFG IS LEXICON(
    "DEORBIT_PE",        5000,
    "FINAL_ALT",          100,
    "FINAL_SPEED",        5.0,
    "TOUCHDOWN_SPEED",    1.5,
    "ABORT_ALT",        10000,
    "HOVER_THROTTLE",    0.35,
    "BURN_LEAD",          3.0,
    "MAX_TILT",          10.0,
    "USE_KE",            TRUE,
    "TARGET_LAT",           0,
    "TARGET_LNG",           0,
    "TARGET_BODY",         "",
    "TARGET_WAYPOINT",     "",
    "TARGET_TOLERANCE",  2500,
    "GUIDANCE_ALT",      5000,
    "GUIDANCE_MAX_TILT",   20,
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
    "ASSIST_FLYAWAY_THROTTLE", 0.6
).

GLOBAL landingAbortFlag IS FALSE.

GLOBAL FUNCTION landingExecute {
    mLogPhase("LANDING").
    SET landingAbortFlag TO FALSE.

    LOCAL useKE IS LANDING_CFG["USE_KE"] AND ADDONS:KE:AVAILABLE.
    LOCAL landingSystem IS "".
    IF useKE {
        SET landingSystem TO "KerbalEngineer".
    } ELSE {
        SET landingSystem TO "manual calculation".
    }
    mLog("Landing system: " + landingSystem).

    LOCAL landingTarget IS landingResolveTarget().
    IF landingTarget["FOUND"] {
        mLogWarn("STATS landing target source=" + landingTarget["SOURCE"]
            + " lat=" + ROUND(landingTarget["LAT"],4)
            + " lng=" + ROUND(landingTarget["LNG"],4)).
        SET LANDING_CFG["TARGET_LAT"] TO landingTarget["LAT"].
        SET LANDING_CFG["TARGET_LNG"] TO landingTarget["LNG"].
        mLog("Landing target: " + ROUND(landingTarget["LAT"],4)
            + "," + ROUND(landingTarget["LNG"],4)
            + " from " + landingTarget["SOURCE"] + ".").
        IF ADDONS:TR:AVAILABLE {
            ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
        }
    }

    WHEN (ABS(SHIP:FACING:PITCH) > LANDING_CFG["MAX_TILT"]
            OR ABS(SHIP:FACING:ROLL) > LANDING_CFG["MAX_TILT"])
            AND ALT:RADAR < LANDING_CFG["GUIDANCE_ALT"]
            AND SHIP:STATUS <> "ORBITING" THEN {
        IF NOT landingAbortFlag {
            mLogWarn("Excessive tilt — auto abort.").
            landingAbort().
        }
    }

    IF SHIP:ORBIT:BODY:ATM:EXISTS {
        WHEN SHIP:AIRSPEED < 100 AND ALT:RADAR < 20000 THEN {
            _deployAntennas().
            mLog("Antennas deployed — airspeed safe.").
        }
    }

    IF NOT _landDeorbit() {
        SET landingAbortFlag TO TRUE.
        RETURN.
    }
    IF landingAbortFlag { RETURN. }
    _landCoast(useKE).
    IF landingAbortFlag { RETURN. }
    _landSuicideBurn(useKE).
    IF landingAbortFlag { RETURN. }
    _landFinal().
    IF landingAbortFlag { RETURN. }
    _landTouchdown().
}

GLOBAL FUNCTION landingAbort {
    SET landingAbortFlag TO TRUE.
    LOCK THROTTLE TO 1.0.
    LOCK STEERING TO SHIP:UP.
    mLogError("LANDING ABORT — climbing to "
        + ROUND(LANDING_CFG["ABORT_ALT"]/1000,0) + "km.").
    HUDTEXT("ABORT — CLIMBING!", 5, 2, 18, RED, FALSE).
    WAIT UNTIL SHIP:VERTICALSPEED > 0
            AND ALT:RADAR > LANDING_CFG["ABORT_ALT"].
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLog("Abort complete. Alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
}

// Use an attached descent stage for the landing burn, then release it.
// Intended sequence:
//   LAND_DEORBIT -> LAND_ASSIST -> LAND
//
// The stage carries the rover down to a controlled release hover:
//   ASSIST_RELEASE_ALT radar altitude
//   ASSIST_RELEASE_HSPEED horizontal speed
//   ASSIST_RELEASE_VSPEED vertical speed
// After decoupling, this CPU may still be on the assist stage; if so, the
// flyaway burn points sideways/up to avoid the lander before impact.
GLOBAL FUNCTION landingAssistStage {
    mLogPhase("LANDING ASSIST").

    LOCAL decoupler IS _taggedDecoupler(LANDING_CFG["ASSIST_DECOUPLER_TAG"]).
    IF decoupler = 0 {
        mLogWarn("No assist decoupler tagged '"
            + LANDING_CFG["ASSIST_DECOUPLER_TAG"] + "' — skipping assist.").
        RETURN FALSE.
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
            mLogWarn("Assist stage needs staging before release target — separating now.").
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

LOCAL FUNCTION _landDeorbit {
    IF SHIP:PERIAPSIS <= LANDING_CFG["DEORBIT_PE"] {
        mLog("Already suborbital (Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km) — skipping deorbit.").
        RETURN TRUE.
    }

    LOCAL landingTarget IS landingResolveTarget().
    IF landingTarget["FOUND"] {
        LOCAL deorbitOk IS landingTargetedDeorbit().
        orbitSummary().
        RETURN deorbitOk.
    }

    mLogError("No landing target set — refusing blind landing deorbit.").
    RETURN FALSE.
}

LOCAL FUNCTION _landCoast {
    PARAMETER useKE.

    SET SAS TO TRUE.
    LOCK STEERING TO SHIP:RETROGRADE.
    mLog("Coasting to suicide burn point...").
    HUDTEXT("Coasting to burn point", 3, 2, 13, WHITE, FALSE).

    IF useKE {
        mLog("Using KerbalEngineer suicide burn countdown.").
        WAIT UNTIL ADDONS:KE:SUICIDEBURNCOUNTDOWN <= LANDING_CFG["BURN_LEAD"]
                OR landingAbortFlag.
        mLog("KE burn countdown reached. Alt=" + ROUND(ALT:RADAR,0)
            + "m  countdown=" + ROUND(ADDONS:KE:SUICIDEBURNCOUNTDOWN,1) + "s"
            + "  burnLength=" + ROUND(ADDONS:KE:SUICIDEBURNLENGTH,1) + "s"
            + "  burnDv=" + ROUND(ADDONS:KE:SUICIDEBURNDELTAV,1) + "m/s").
    } ELSE {
        mLog("Using manual suicide burn calculation.").
        WAIT UNTIL ALT:RADAR <= _manualBurnAlt()
                OR landingAbortFlag.
        mLog("Manual burn point reached. Alt=" + ROUND(ALT:RADAR,0) + "m").
    }
}

LOCAL FUNCTION _landSuicideBurn {
    PARAMETER useKE.

    LOCAL landingTarget IS landingResolveTarget().
    mLog("Suicide burn start.").
    HUDTEXT("SUICIDE BURN", 3, 2, 16, YELLOW, FALSE).
    LOCK STEERING TO SHIP:RETROGRADE.

    UNTIL ALT:RADAR <= LANDING_CFG["FINAL_ALT"] OR landingAbortFlag {
        IF landingTarget["FOUND"] AND ALT:RADAR < LANDING_CFG["GUIDANCE_ALT"] {
            LOCK STEERING TO _landingGuidanceVector(landingTarget, SHIP:RETROGRADE).
        } ELSE {
            LOCK STEERING TO SHIP:RETROGRADE.
        }

        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
        }

        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            IF useKE AND ADDONS:KE:AVAILABLE {
                LOCAL remaining IS ADDONS:KE:SUICIDEBURNDELTAV.
                LOCAL ratio     IS remaining / (maxAcc * ADDONS:KE:SUICIDEBURNLENGTH).
                LOCK THROTTLE TO MAX(0.05, MIN(1.0, ratio)).
            } ELSE {
                LOCAL targetDecel IS (SHIP:VERTICALSPEED^2) / (2 * ALT:RADAR).
                LOCK THROTTLE TO MAX(0.05, MIN(1.0, targetDecel / maxAcc)).
            }
        }

        LOCAL tDV IS "".
        IF (useKE AND ADDONS:KE:AVAILABLE) {
           SET tDV  TO "  dV:" + ROUND(ADDONS:KE:SUICIDEBURNDELTAV, 1).
        }
        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s" + tDV,
            1, 2, 13, YELLOW, FALSE).

        WAIT 0.05.
    }

    mLog("Suicide burn complete. Alt=" + ROUND(ALT:RADAR,0)
        + "m  vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s").
}

LOCAL FUNCTION _landFinal {
    LOCAL landingTarget IS landingResolveTarget().
    LOCAL legs IS SHIP:MODULESNAMED("ModuleWheelDeployment").
    LOCAL legsMLD IS SHIP:MODULESNAMED("ModuleLandingLeg").
    FOR m IN legsMLD { legs:ADD(m). }
    IF legs:LENGTH > 0 {
        FOR m IN legs {
            IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
        }
        mLog("Landing legs deployed.").
    }

    mLog("Final approach. Target descent "
        + LANDING_CFG["FINAL_SPEED"] + "m/s.").
    HUDTEXT("Final approach", 3, 2, 14, GREEN, FALSE).

    UNTIL ALT:RADAR < 5 OR landingAbortFlag {
        LOCAL hVel IS SHIP:VELOCITY:SURFACE
            - (VDOT(SHIP:VELOCITY:SURFACE, SHIP:UP:VECTOR) * SHIP:UP:VECTOR).
        IF landingTarget["FOUND"] AND ALT:RADAR < LANDING_CFG["GUIDANCE_ALT"] {
            LOCAL targetDist IS _landingTargetDistance(landingTarget).
            IF targetDist > 25 {
                LOCK STEERING TO _landingGuidanceVector(landingTarget, SHIP:UP).
            } ELSE IF hVel:MAG > 0.5 {
                LOCK STEERING TO (-hVel):NORMALIZED.
            } ELSE {
                LOCK STEERING TO SHIP:UP.
            }
        } ELSE IF hVel:MAG > 0.5 {
            LOCK STEERING TO (-hVel):NORMALIZED.
        } ELSE {
            LOCK STEERING TO SHIP:UP.
        }

        LOCAL vspd  IS SHIP:VERTICALSPEED.
        LOCAL error IS -LANDING_CFG["FINAL_SPEED"] - vspd.
        LOCAL maxAcc IS _safeMaxAcc().
        IF maxAcc > 0 {
            LOCAL thrott IS LANDING_CFG["HOVER_THROTTLE"] + (error * 0.1).
            LOCK THROTTLE TO MAX(0, MIN(1.0, thrott)).
        }

        LOCAL targetMsg IS "".
        IF landingTarget["FOUND"] {
            SET targetMsg TO " tgt:" + ROUND(_landingTargetDistance(landingTarget),0) + "m".
        }
        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "m/s" + targetMsg,
            1, 2, 13, GREEN, FALSE).
        WAIT 0.05.
    }
}

LOCAL FUNCTION _landTouchdown {
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    WAIT UNTIL SHIP:STATUS = "LANDED"
            OR SHIP:STATUS = "SPLASHED"
            OR landingAbortFlag.

    IF NOT landingAbortFlag {
        mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
            + "  lat=" + ROUND(SHIP:LATITUDE,4)
            + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
        HUDTEXT("TOUCHDOWN!", 8, 2, 20, GREEN, FALSE).
        stateSet("landing_lat",  SHIP:LATITUDE).
        stateSet("landing_lng",  SHIP:LONGITUDE).
        stateSet("landing_time", TIME:SECONDS).
        _deployAntennas().
        _deploySolarPanels().
    }
}

GLOBAL FUNCTION landingTargetedDeorbit {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set — refusing blind landing deorbit.").
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

    RETURN targetedDeorbitAt(
        landingTarget["LAT"],
        landingTarget["LNG"],
        LANDING_CFG["DEORBIT_PE"],
        LANDING_CFG["TARGET_TOLERANCE"]).
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
            IF wp:NAME:TOUPPER = targetName {
                RETURN wp.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _selectedWaypoint {
    LOCAL allWps IS ALLWAYPOINTS().
    FOR wp IN allWps {
        IF wp:ISSELECTED {
            IF wp:BODY:NAME = SHIP:BODY:NAME {
                RETURN wp.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _landingTargetDistance {
    PARAMETER landingTarget.
    RETURN _landingGeoDistance(
        SHIP:LATITUDE,
        SHIP:LONGITUDE,
        landingTarget["LAT"],
        landingTarget["LNG"]).
}

LOCAL FUNCTION _landingGuidanceVector {
    PARAMETER landingTarget.
    PARAMETER fallbackVec.

    LOCAL targetGeo IS LATLNG(landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL targetDist IS _landingTargetDistance(landingTarget).
    IF targetDist < 25 { RETURN fallbackVec. }

    LOCAL toTarget IS targetGeo:POSITION - SHIP:GEOPOSITION:POSITION.
    LOCAL lateral IS VXCL(SHIP:UP:VECTOR, toTarget).
    IF lateral:MAG < 0.001 { RETURN fallbackVec. }

    LOCAL maxLean IS SIN(LANDING_CFG["GUIDANCE_MAX_TILT"]).
    LOCAL lean IS MIN(maxLean, targetDist / 500).
    RETURN (fallbackVec:NORMALIZED + lateral:NORMALIZED * lean):NORMALIZED.
}

LOCAL FUNCTION _landingGeoDistance {
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

LOCAL FUNCTION _deployAntennas {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableAntenna") {
        IF m:HASEVENT("Extend Antenna") { m:DOEVENT("Extend Antenna"). }
    }
}

LOCAL FUNCTION _deploySolarPanels {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
        IF m:HASEVENT("Extend Solar Panel") { m:DOEVENT("Extend Solar Panel"). }
    }
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

LOCAL FUNCTION _manualBurnAlt {
    LOCAL maxAcc IS _safeMaxAcc().
    IF maxAcc <= 0 { RETURN 0. }
    RETURN (SHIP:VERTICALSPEED^2) / (2 * maxAcc).
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
