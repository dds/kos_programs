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
    "ASSIST_FLYAWAY_THROTTLE", 0.6
).

GLOBAL landingAbortFlag IS FALSE.

GLOBAL FUNCTION landingTargetedDeorbit {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLog("No landing target set - using blind deorbit.").
        RETURN.
    }

    SET LANDING_CFG["TARGET_LAT"] TO landingTarget["LAT"].
    SET LANDING_CFG["TARGET_LNG"] TO landingTarget["LNG"].
    mLog("Landing deorbit target: " + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)
        + " from " + landingTarget["SOURCE"] + ".").

    targetedDeorbitAt(
        landingTarget["LAT"],
        landingTarget["LNG"],
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

GLOBAL FUNCTION landingResolveTarget {
    LOCAL result IS LEXICON().
    result:ADD("FOUND", FALSE).
    result:ADD("LAT", 0).
    result:ADD("LNG", 0).
    result:ADD("SOURCE", "none").

    IF LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LANDING_CFG["TARGET_LAT"].
        SET result["LNG"] TO LANDING_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "LANDING_CFG".
        RETURN result.
    }

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
    LOCAL parts IS SHIP:PARTSTAGGED(tagName).
    IF parts:LENGTH = 0 { RETURN 0. }
    RETURN parts[0].
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
    LOCAL hVel IS SHIP:VELOCITY:SURFACE
        - (VDOT(SHIP:VELOCITY:SURFACE, SHIP:UP) * SHIP:UP).
    RETURN hVel.
}

LOCAL FUNCTION _assistSteering {
    PARAMETER hVel.
    PARAMETER hSpeed.

    LOCAL steerVec IS SHIP:UP.
    IF hSpeed > LANDING_CFG["ASSIST_RELEASE_HSPEED"] {
        LOCAL maxLean IS SIN(LANDING_CFG["ASSIST_MAX_TILT"]).
        LOCAL lean IS MIN(maxLean, hSpeed / 10).
        SET steerVec TO (SHIP:UP + (-hVel):NORMALIZED * lean):NORMALIZED.
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
