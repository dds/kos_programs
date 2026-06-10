// ============================================================
// drone.ks  —  Hover drone guidance and modes  (0:/lib/drone.ks)
//
// Autonomous hover/transport drone for Kerbin AND airless
// bodies (Mun, Minmus). Guidance descends from the ozin370
// quadcopter (~/code/quadcopter_kos.ozin370, Reddit 2017):
// kept the acceleration-vector composition (horizontal velocity
// PID + vertical VS PID + gravity, capped with vertical
// priority), the sqrt braking law for approach, the tilt cap,
// and throttle compensation for attitude effort. Dropped the
// GUI/camera/race layers and the per-engine thrust mixer (a
// future DRONE_STYLE for true 4-motor quads — needs an airframe
// to tune against).
//
// Actuation styles (CFG DRONE_STYLE):
//   "TILT" — throttleable lift engines pointing along the probe
//            core's up axis (Juno/Wheesley pods on Kerbin, a
//            Spark/Ant on the Mun). Attitude via LOCK STEERING
//            (bring reaction wheels), throttle does the rest.
//   "RCS"  — attitude held LEVEL, vertical and horizontal motion
//            via RCS translation (plus main throttle for lift if
//            engines exist). No tilt: kerbal-friendly transport
//            on Mun/Minmus.
//
// Modes (driven by action groups, like the airplane assists):
//   AG7 — hover-hold here          AG9  — land here
//   AG8 — fly to the waypoint selected in Waypoint Manager
//   AG10 — return to the launch point and hover
//
// Phase: FLY — auto-takeoff to hover, then obey AGs; the phase
// ends after a commanded landing. restartflightplan flies the
// next sortie. Low fuel/EC forces a landing (legacy autoland).
//
// CFG keys (defaults):
//   DRONE_STYLE ("TILT")        DRONE_HOVER_AGL (15)
//   DRONE_CRUISE_AGL (60)       DRONE_CRUISE_SPEED (25)
//   DRONE_MAX_TILT (30)         DRONE_VS_CAP (8)
//   DRONE_KP_VEL (0.8)          DRONE_RCS_ACC (2.0)
//   DRONE_LOW_RESOURCE (15)     DRONE_ARRIVE_RADIUS (4)
// ============================================================

@LAZYGLOBAL OFF.

GLOBAL droneMode IS "IDLE".   // IDLE HOVER GOTO LAND RTB
GLOBAL droneActive IS FALSE.

LOCAL _dnTargetGeo IS 0.
LOCAL _dnTargetAgl IS 15.
LOCAL _dnHomeGeo IS 0.
LOCAL _dnHomeAlt IS 0.
LOCAL _dnVsPid IS 0.
LOCAL _dnSteerDir IS 0.
LOCAL _dnLowResWarned IS FALSE.
LOCAL _dnPrevAg7 IS FALSE.
LOCAL _dnPrevAg8 IS FALSE.
LOCAL _dnPrevAg9 IS FALSE.
LOCAL _dnPrevAg10 IS FALSE.

LOCAL FUNCTION _dnCfg {
    PARAMETER key, defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _dnGravity {
    RETURN SHIP:BODY:MU / (SHIP:BODY:POSITION:MAG ^ 2).
}

LOCAL FUNCTION _dnMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0.1. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

// Terrain-following altitude floor: the higher of here and a
// few seconds ahead along the velocity vector (v1 of the legacy
// five-point terrain predictor).
LOCAL FUNCTION _dnTerrainAhead {
    LOCAL hNow IS SHIP:GEOPOSITION:TERRAINHEIGHT.
    LOCAL vH IS VXCL(UP:VECTOR, SHIP:VELOCITY:SURFACE).
    IF vH:MAG < 2 { RETURN hNow. }
    LOCAL ahead IS SHIP:BODY:GEOPOSITIONOF(SHIP:POSITION + vH * 4).
    RETURN MAX(hNow, ahead:TERRAINHEIGHT).
}

// ============================================================
// droneInit — call once (FLY phase does). Sets home, PIDs, AGs.
// ============================================================
GLOBAL FUNCTION droneInit {
    SET _dnHomeGeo TO SHIP:GEOPOSITION.
    SET _dnHomeAlt TO SHIP:ALTITUDE.
    SET _dnVsPid TO PIDLOOP(0.6, 0.08, 0.15,
        -_dnGravity() * 0.9, MAX(0.5, _dnMaxAcc())).
    SET _dnPrevAg7 TO AG7.
    SET _dnPrevAg8 TO AG8.
    SET _dnPrevAg9 TO AG9.
    SET _dnPrevAg10 TO AG10.
    SET droneMode TO "IDLE".
    SET droneActive TO TRUE.
    IF _dnCfg("DRONE_STYLE", "TILT") = "RCS" { RCS ON. }
    mLog("Drone init: style=" + _dnCfg("DRONE_STYLE", "TILT")
        + " g=" + ROUND(_dnGravity(), 2)
        + " maxAcc=" + ROUND(_dnMaxAcc(), 1)
        + " home=" + ROUND(_dnHomeGeo:LAT, 4) + "," + ROUND(_dnHomeGeo:LNG, 4)).
    HUDTEXT("Drone ready — AG7 hover  AG8 waypoint  AG9 land  AG10 home",
        8, 2, 14, GREEN, FALSE).
}

GLOBAL FUNCTION droneShutdown {
    UNLOCK STEERING.
    UNLOCK THROTTLE.
    SET SHIP:CONTROL:NEUTRALIZE TO TRUE.
    SET droneActive TO FALSE.
    SET droneMode TO "IDLE".
    mLog("Drone shutdown.").
}

// ============================================================
// Mode commands
// ============================================================
GLOBAL FUNCTION droneHoverHere {
    PARAMETER agl IS _dnCfg("DRONE_HOVER_AGL", 15).
    SET _dnTargetGeo TO SHIP:GEOPOSITION.
    SET _dnTargetAgl TO agl.
    SET droneMode TO "HOVER".
    _dnVsPid:RESET().
    mLog("Drone HOVER at " + agl + "m AGL.").
    HUDTEXT("HOVER " + agl + "m", 3, 2, 14, CYAN, FALSE).
}

GLOBAL FUNCTION droneGoto {
    PARAMETER geo.
    PARAMETER agl IS _dnCfg("DRONE_CRUISE_AGL", 60).
    SET _dnTargetGeo TO geo.
    SET _dnTargetAgl TO agl.
    SET droneMode TO "GOTO".
    mLog("Drone GOTO " + ROUND(geo:LAT, 4) + "," + ROUND(geo:LNG, 4)
        + " (" + ROUND(geo:DISTANCE, 0) + "m) at " + agl + "m AGL.").
    HUDTEXT("GOTO " + ROUND(geo:DISTANCE / 1000, 1) + "km", 3, 2, 14, CYAN, FALSE).
}

GLOBAL FUNCTION droneGotoWaypoint {
    LOCAL best IS 0.
    FOR wp IN ALLWAYPOINTS() {
        IF wp:BODY = SHIP:BODY AND wp:ISSELECTED { SET best TO wp. }
    }
    IF best = 0 {
        mLogWarn("Drone: no waypoint selected on " + SHIP:BODY:NAME + ".").
        HUDTEXT("Select a waypoint first", 3, 2, 14, RED, FALSE).
        RETURN.
    }
    mLog("Drone waypoint: " + best:NAME).
    droneGoto(best:GEOPOSITION).
}

GLOBAL FUNCTION droneLandHere {
    SET _dnTargetGeo TO SHIP:GEOPOSITION.
    SET droneMode TO "LAND".
    GEAR ON.
    mLog("Drone LAND.").
    HUDTEXT("LANDING", 3, 2, 14, YELLOW, FALSE).
}

GLOBAL FUNCTION droneReturnHome {
    SET _dnTargetGeo TO _dnHomeGeo.
    SET _dnTargetAgl TO _dnCfg("DRONE_CRUISE_AGL", 60).
    SET droneMode TO "RTB".
    mLog("Drone RTB (" + ROUND(_dnHomeGeo:DISTANCE, 0) + "m).").
    HUDTEXT("RETURN TO BASE", 3, 2, 14, CYAN, FALSE).
}

// ============================================================
// Guidance core — one call per tick (~20Hz from the FLY loop).
// Position error -> capped velocity target (sqrt braking law)
// -> acceleration command -> actuation per DRONE_STYLE.
// ============================================================
GLOBAL FUNCTION droneUpdate {
    IF NOT droneActive { RETURN. }
    // AGs work even while parked, so a sortie can resume after a
    // landing (pick up the kerbal, AG8 onward).
    _dnCheckAgs().
    IF droneMode = "IDLE" { RETURN. }
    _dnCheckResources().

    LOCAL g IS _dnGravity().
    LOCAL maxAcc IS _dnMaxAcc().
    LOCAL style IS _dnCfg("DRONE_STYLE", "TILT").
    LOCAL upV IS UP:VECTOR.
    LOCAL vSurf IS SHIP:VELOCITY:SURFACE.
    LOCAL vH IS VXCL(upV, vSurf).

    // --- Horizontal velocity target ---
    LOCAL posErr IS V(0, 0, 0).
    IF _dnTargetGeo <> 0 {
        SET posErr TO VXCL(upV, _dnTargetGeo:POSITION).
    }
    LOCAL maxTilt IS _dnCfg("DRONE_MAX_TILT", 30).
    LOCAL maxHAcc IS maxAcc * SIN(maxTilt).
    IF style = "RCS" { SET maxHAcc TO _dnCfg("DRONE_RCS_ACC", 2.0). }

    LOCAL cruise IS _dnCfg("DRONE_CRUISE_SPEED", 25).
    IF droneMode = "HOVER" OR droneMode = "LAND" { SET cruise TO 8. }
    // sqrt braking law (legacy): never approach faster than you
    // can stop with ~60% of available horizontal acceleration.
    LOCAL vCap IS MIN(cruise, SQRT(2 * MAX(0.01, posErr:MAG) * maxHAcc * 0.6)).
    LOCAL vTarget IS posErr:NORMALIZED * MIN(vCap, posErr:MAG).

    // --- Vertical speed target ---
    LOCAL vsCap IS _dnCfg("DRONE_VS_CAP", 8).
    LOCAL targetAltAbs IS 0.
    IF droneMode = "LAND" {
        // Radar-scheduled flare: -radar/4 down to a gentle touch.
        LOCAL vsTarget IS -MAX(0.6, MIN(vsCap, ALT:RADAR / 4)).
        SET targetAltAbs TO SHIP:ALTITUDE - 10.
        _dnApplyControl(style, vTarget, vH, vsTarget, g, maxAcc, maxHAcc, upV).
        _dnCheckTouchdown().
        RETURN.
    }
    LOCAL floorAlt IS _dnTerrainAhead() + _dnCfg("DRONE_HOVER_AGL", 15) * 0.6.
    IF _dnTargetGeo <> 0 {
        SET targetAltAbs TO MAX(
            _dnTargetGeo:TERRAINHEIGHT + _dnTargetAgl, floorAlt).
    } ELSE {
        SET targetAltAbs TO MAX(SHIP:ALTITUDE, floorAlt).
    }
    LOCAL vsTarget IS MAX(-vsCap, MIN(vsCap, (targetAltAbs - SHIP:ALTITUDE) * 0.5)).

    _dnApplyControl(style, vTarget, vH, vsTarget, g, maxAcc, maxHAcc, upV).

    // --- Arrival: GOTO/RTB become HOVER on station ---
    IF (droneMode = "GOTO" OR droneMode = "RTB")
            AND posErr:MAG < _dnCfg("DRONE_ARRIVE_RADIUS", 4)
            AND vH:MAG < 1.5 {
        mLog("Drone on station (" + droneMode + " complete).").
        HUDTEXT("ON STATION", 3, 2, 14, GREEN, FALSE).
        SET _dnTargetAgl TO _dnCfg("DRONE_HOVER_AGL", 15).
        SET droneMode TO "HOVER".
    }
}

// ============================================================
// Actuation
// ============================================================
LOCAL FUNCTION _dnApplyControl {
    PARAMETER style, vTarget, vH, vsTarget, g, maxAcc, maxHAcc, upV.

    // Acceleration commands from velocity errors.
    LOCAL kpV IS _dnCfg("DRONE_KP_VEL", 0.8).
    LOCAL aH IS (vTarget - vH) * kpV.
    IF aH:MAG > maxHAcc { SET aH TO aH:NORMALIZED * maxHAcc. }

    SET _dnVsPid:MAXOUTPUT TO MAX(0.5, maxAcc - g).
    SET _dnVsPid:MINOUTPUT TO -g * 0.9.
    SET _dnVsPid:SETPOINT TO vsTarget.
    LOCAL aV IS _dnVsPid:UPDATE(TIME:SECONDS, SHIP:VERTICALSPEED).

    IF style = "RCS" {
        // Stay level; translate with RCS. Throttle helps with lift
        // when a main engine exists (hybrid hopper).
        LOCAL fwd IS VXCL(upV, SHIP:FACING:TOPVECTOR).
        IF vH:MAG > 3 { SET fwd TO VXCL(upV, vH). }
        SET _dnSteerDir TO LOOKDIRUP(upV, fwd).
        LOCK STEERING TO _dnSteerDir.

        LOCAL liftAcc IS g + aV.
        IF maxAcc > 0.5 {
            LOCK THROTTLE TO MAX(0, MIN(1, liftAcc / maxAcc)).
            SET SHIP:CONTROL:TOP TO 0.
        } ELSE {
            // Pure RCS lift: trim with the translation channel.
            UNLOCK THROTTLE.
            SET SHIP:CONTROL:TOP TO
                MAX(-1, MIN(1, liftAcc / MAX(0.1, _dnCfg("DRONE_RCS_ACC", 2.0)))).
        }
        // Lateral RCS in the ship's level frame (fore = topvector
        // when the core points up).
        LOCAL aRcs IS _dnCfg("DRONE_RCS_ACC", 2.0).
        SET SHIP:CONTROL:FORE TO
            MAX(-1, MIN(1, VDOT(aH, SHIP:FACING:TOPVECTOR) / aRcs)).
        SET SHIP:CONTROL:STARBOARD TO
            MAX(-1, MIN(1, VDOT(aH, SHIP:FACING:STARVECTOR) / aRcs)).
        RETURN.
    }

    // TILT: compose the full acceleration vector and point the
    // lift axis along it (legacy composition, vertical priority).
    LOCAL accVec IS aH + upV * (g + aV).
    IF accVec:MAG > maxAcc {
        IF (g + aV) > maxAcc {
            SET accVec TO upV * (g + aV) + aH * 0.25.
        } ELSE {
            LOCAL hMag IS SQRT(MAX(0, maxAcc ^ 2 - (g + aV) ^ 2)).
            SET accVec TO upV * (g + aV) + aH:NORMALIZED * hMag.
        }
    }
    // Tilt cap keeps the airframe honest (and the kerbal calm).
    LOCAL maxTilt IS _dnCfg("DRONE_MAX_TILT", 30).
    IF VANG(upV, accVec) > maxTilt {
        SET accVec TO ANGLEAXIS(maxTilt, -VCRS(accVec, upV)) * upV * accVec:MAG.
    }

    LOCAL fwd IS VXCL(accVec, SHIP:FACING:TOPVECTOR).
    IF vH:MAG > 3 { SET fwd TO VXCL(accVec, vH). }
    SET _dnSteerDir TO LOOKDIRUP(accVec:NORMALIZED, fwd).
    LOCK STEERING TO _dnSteerDir.

    // Throttle: meet the VERTICAL demand with the current real
    // tilt (legacy formula) — misalignment costs lateral, not lift.
    LOCAL cosTilt IS MAX(0.2, VDOT(upV, SHIP:FACING:VECTOR)).
    LOCK THROTTLE TO MAX(0, MIN(1, (g + aV) / MAX(0.1, maxAcc * cosTilt))).
}

// ============================================================
// Mode plumbing
// ============================================================
LOCAL FUNCTION _dnCheckAgs {
    IF AG7 <> _dnPrevAg7 { SET _dnPrevAg7 TO AG7. droneHoverHere(). }
    IF AG8 <> _dnPrevAg8 { SET _dnPrevAg8 TO AG8. droneGotoWaypoint(). }
    IF AG9 <> _dnPrevAg9 { SET _dnPrevAg9 TO AG9. droneLandHere(). }
    IF AG10 <> _dnPrevAg10 { SET _dnPrevAg10 TO AG10. droneReturnHome(). }
}

// Legacy autoland: force a landing while there is still margin.
LOCAL FUNCTION _dnCheckResources {
    IF droneMode = "LAND" OR _dnLowResWarned { RETURN. }
    LOCAL worst IS 100.
    FOR res IN SHIP:RESOURCES {
        IF (res:NAME = "LIQUIDFUEL" OR res:NAME = "ELECTRICCHARGE"
                OR res:NAME = "MONOPROPELLANT")
                AND res:CAPACITY > 0 {
            LOCAL pct IS 100 * res:AMOUNT / res:CAPACITY.
            IF pct < worst { SET worst TO pct. }
        }
    }
    IF worst < _dnCfg("DRONE_LOW_RESOURCE", 15) {
        SET _dnLowResWarned TO TRUE.
        mLogWarn("Drone: low resources (" + ROUND(worst, 0) + "%) — landing.").
        HUDTEXT("LOW FUEL/EC — AUTOLAND", 8, 2, 16, RED, FALSE).
        droneLandHere().
    }
}

LOCAL FUNCTION _dnCheckTouchdown {
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED"
            OR (ALT:RADAR < 1.5 AND ABS(SHIP:VERTICALSPEED) < 0.3) {
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        SET SHIP:CONTROL:NEUTRALIZE TO TRUE.
        SET droneMode TO "IDLE".
        mLog("Drone touchdown.").
        HUDTEXT("TOUCHDOWN", 5, 2, 14, GREEN, FALSE).
    }
}

// ============================================================
// phaseArm — preflight checklist; auto-stages lift engines if
// nothing is producing thrust yet.
// ============================================================
GLOBAL FUNCTION phaseArm {
    mLogPhase("ARM").
    flightPlanTitle("DRONE FLIGHT PLAN", SHIP:NAME).
    flightPlanIdentity().
    flightPlanSection("DRONE").
    flightPlanRow("STYLE", _dnCfg("DRONE_STYLE", "TILT")).
    flightPlanRow("CRUISE", _dnCfg("DRONE_CRUISE_AGL", 60) + "m AGL / "
        + _dnCfg("DRONE_CRUISE_SPEED", 25) + " m/s").
    flightPlanRow("MODES", "AG7 hover AG8 wpt AG9 land AG10 home").

    flightPlanChecklist("DRONE PREFLIGHT", LIST(
        "Payload/kerbal - secured",
        "Waypoint Manager - select destination",
        "RCS - fueled (vacuum ops)",
        "Engines - staged (auto if needed)",
        "Launch clamps/clamps - none"
    ), LIST(
        "Body ........ " + SHIP:BODY:NAME,
        "Gravity ..... " + ROUND(_dnGravity(), 2) + " m/s2",
        "Max accel ... " + ROUND(_dnMaxAcc(), 1) + " m/s2",
        "Storage ..... " + CORE:VOLUME:FREESPACE + " bytes free"
    ), "Press any key to launch").

    IF _dnCfg("DRONE_STYLE", "TILT") = "TILT" AND SHIP:AVAILABLETHRUST <= 0 {
        mLog("No thrust — staging lift engines.").
        STAGE.
        WAIT 1.
    }
    IF _dnMaxAcc() <= _dnGravity() AND _dnCfg("DRONE_STYLE", "TILT") = "TILT" {
        mLogWarn("Drone TWR below 1 (" + ROUND(_dnMaxAcc() / _dnGravity(), 2)
            + ") — it will not hover. Check engines/mass.").
    }
    nextPhase(launchSeq).
}

// ============================================================
// phaseFly — auto-takeoff to hover, then obey the AGs. Ends
// after a commanded landing settles. restartflightplan re-arms.
// ============================================================
GLOBAL FUNCTION phaseFly {
    mLogPhase("FLY").
    droneInit().
    observeStart().

    mLog("Takeoff to hover.").
    GEAR OFF.
    droneHoverHere().

    LOCAL landedSince IS -1.
    UNTIL FALSE {
        droneUpdate().
        IF droneMode = "IDLE" {
            IF landedSince < 0 { SET landedSince TO TIME:SECONDS. }
            // Re-armed by any AG; otherwise end the sortie.
            IF TIME:SECONDS - landedSince > 8 { BREAK. }
        } ELSE {
            SET landedSince TO -1.
        }
        WAIT 0.05.
    }

    droneShutdown().
    observeStop().
    mLog("Sortie complete.").
    nextPhase(launchSeq).
}
