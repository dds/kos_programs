// ============================================================
// suborbit.ks  —  Suborbital cutoff + return arc  (0:/lib/suborbit.ks)
//
// SUBORBIT phase: plain ballistic hop cutoff, or — with
// SUBORBIT_RETURN = 1 — the round-the-world drag-grazing arc
// back to the launch site. Own lib so the LAUNCH band doesn't
// carry it for every rocket; suborbital missions bring it in
// with LIBS_EXTRA = suborbit, descent (loaded at the pad, every
// band, so the whole flight runs without a band-change reboot).
// ============================================================

LOCAL FUNCTION _launchCfgNum {
    PARAMETER key.
    PARAMETER defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _norm360 {
    PARAMETER angle.
    LOCAL result IS angle.
    UNTIL result >= 0 { SET result TO result + 360. }
    UNTIL result < 360 { SET result TO result - 360. }
    RETURN result.
}

LOCAL FUNCTION _norm180 {
    PARAMETER angle.
    RETURN _norm360(angle + 180) - 180.
}

// ── Suborbital return arc (SUBORBIT_RETURN = 1) ──────────────
// "Very long arc in space, land where we started": fly JUST
// below orbital speed. After the MechJeb boost, keep burning
// prograde while the Trajectories impact prediction sweeps east
// around the globe; cut the engine when the predicted impact
// arrives back at the launch site, then trim the arc with small
// prograde/retrograde burns above the atmosphere. Knobs:
// SUBORBIT_RETURN_TOL (40km). NOT YET FLIGHT-PROVEN.

LOCAL FUNCTION _suborbitSiteGeo {
    LOCAL siteLat IS stateGetNum("launch_site_lat", 9999).
    LOCAL siteLng IS stateGetNum("launch_site_lng", 9999).
    IF siteLat <> 9999 { RETURN LATLNG(siteLat, siteLng). }
    IF CFG:HASKEY("LANDING_TARGET_LAT") AND CFG:HASKEY("LANDING_TARGET_LNG") {
        RETURN LATLNG(CFG["LANDING_TARGET_LAT"], CFG["LANDING_TARGET_LNG"]).
    }
    RETURN LATLNG(-0.0972, -74.5577).   // KSC pad
}

// Chord distance from the predicted impact to the site (same-time
// positions, so the chord is frame-safe). -1 = no impact.
LOCAL FUNCTION _suborbitImpactDist {
    PARAMETER siteGeo.
    IF NOT (ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT) { RETURN -1. }
    LOCAL impactGeo IS ADDONS:TR:IMPACTPOS.
    RETURN (LATLNG(impactGeo:LAT, impactGeo:LNG):POSITION
        - LATLNG(siteGeo:LAT, siteGeo:LNG):POSITION):MAG.
}

// Deliver a small dv on orbit prograde/retrograde, gently.
LOCAL FUNCTION _suborbitTrimBurn {
    PARAMETER dvMag.
    PARAMETER pro.
    LOCAL startVel IS SHIP:VELOCITY:ORBIT.
    IF pro { LOCK STEERING TO SHIP:PROGRADE. }
    ELSE { LOCK STEERING TO SHIP:RETROGRADE. }
    LOCAL alignDeadline IS TIME:SECONDS + 45.
    UNTIL VANG(SHIP:FACING:FOREVECTOR,
            (CHOOSE 1 IF pro ELSE -1) * SHIP:VELOCITY:ORBIT) < 5
            OR TIME:SECONDS > alignDeadline {
        WAIT 0.1.
    }
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL burnDeadline IS TIME:SECONDS + 60.
    UNTIL (SHIP:VELOCITY:ORBIT - startVel):MAG >= dvMag
            OR TIME:SECONDS > burnDeadline
            OR ABORT OR AG10 {
        LOCAL acc IS MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
        LOCAL remaining IS dvMag - (SHIP:VELOCITY:ORBIT - startVel):MAG.
        SET throttleCmd TO MIN(1, MAX(0.02, remaining / acc / 0.6)).
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
}

// Safe-to-burn check for the return arc: above the atmosphere
// and not falling back into it (flight-found: the first attempt
// kept trimming retrograde all the way down to 45km).
LOCAL FUNCTION _suborbitCanBurn {
    IF SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT + 1000 {
        RETURN SHIP:VERTICALSPEED > 0.
    }
    RETURN TRUE.
}

// Closed-loop trim: measure impact-to-site distance, burn a small
// step, re-measure, learn the sensitivity (m of impact motion per
// m/s), repeat. Only touches SMALL residuals — a grossly wrong
// arc is ridden down as-is, never "fixed" with blind burns.
LOCAL FUNCTION _suborbitTrimArc {
    PARAMETER siteGeo.
    PARAMETER tol.
    LOCAL sens IS 30000.
    LOCAL iter IS 0.
    // 12 passes: the sweep now hands off ~20 deg (~200km) early
    // and this loop owns the whole final approach.
    UNTIL iter >= 12 {
        SET iter TO iter + 1.
        IF ABORT OR AG10 { launchAbort(). RETURN. }
        IF NOT _suborbitCanBurn() {
            mLogWarn("Trim stopped: descending into the atmosphere.").
            BREAK.
        }
        IF SHIP:AVAILABLETHRUST <= 0 {
            mLogWarn("Trim stopped: no thrust (stage spent).").
            BREAK.
        }
        WAIT 2.
        LOCAL d0 IS _suborbitImpactDist(siteGeo).
        LOCAL pro IS TRUE.
        LOCAL step IS 2.
        IF d0 < 0 {
            // No impact at all: we ended up orbital — pull Pe down.
            SET pro TO FALSE.
            SET step TO 5.
            mLog("Trim " + iter + ": no impact (orbital) — retro 5 m/s.").
        } ELSE {
            IF d0 <= tol {
                mLog("Trim done: impact " + ROUND(d0 / 1000, 0)
                    + "km from site (tol " + ROUND(tol / 1000, 0) + "km).").
                BREAK.
            }
            LOCAL alongErr IS _norm180(siteGeo:LNG - ADDONS:TR:IMPACTPOS:LNG).
            IF ABS(alongErr) > 45 {
                mLogError("Trim refused: impact " + ROUND(alongErr, 0)
                    + " deg off — arc badly wrong, riding it down.").
                BREAK.
            }
            // Short (site east of impact) → prograde extends the arc.
            SET pro TO alongErr > 0.
            SET step TO MIN(10, MAX(0.5, d0 / sens)).
            mLog("Trim " + iter + ": impact " + ROUND(d0 / 1000, 0)
                + "km " + (CHOOSE "short" IF pro ELSE "long")
                + " — " + (CHOOSE "prograde " IF pro ELSE "retrograde ")
                + ROUND(step, 1) + " m/s.").
        }
        _suborbitTrimBurn(step, pro).
        WAIT 2.
        LOCAL d1 IS _suborbitImpactDist(siteGeo).
        IF d0 > 0 AND d1 > 0 AND ABS(d0 - d1) > 1000 {
            SET sens TO MAX(5000, ABS(d0 - d1) / step).
        }
    }
    UNLOCK STEERING.
    mLogWarn("STATS suborbit-return trim result dist="
        + ROUND(_suborbitImpactDist(siteGeo) / 1000, 1)
        + "km PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)).
}

// dv needed at apoapsis to stretch the arc to a Pe of ~50km (the
// flight regime of a full-circle drag-grazing return) — vis-viva
// on elements only, no position predictions.
LOCAL FUNCTION _suborbitArcDvRequired {
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL rAp IS SHIP:BODY:RADIUS + SHIP:APOAPSIS.
    LOCAL rPeTarget IS SHIP:BODY:RADIUS + 50000.
    LOCAL vNeed IS SQRT(mu * (2 / rAp - 2 / (rAp + rPeTarget))).
    LOCAL vAp IS SQRT(MAX(0, mu * (2 / rAp - 1 / SHIP:ORBIT:SEMIMAJORAXIS))).
    RETURN MAX(0, vNeed - vAp).
}

// Stage dv estimate from the rocket equation. Stock LF+Ox mass
// 5 kg/unit; ISP from the best active engine. 0 = unknown.
LOCAL FUNCTION _suborbitArcDvBudget {
    LOCAL fuelMass IS (STAGE:LIQUIDFUEL + STAGE:OXIDIZER) * 0.005.
    LOCAL bestIsp IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT {
            SET bestIsp TO MAX(bestIsp, eng:VISP).
        }
    }
    IF bestIsp <= 0 OR fuelMass <= 0 OR fuelMass >= SHIP:MASS {
        RETURN 0.
    }
    RETURN bestIsp * 9.81 * LN(SHIP:MASS / (SHIP:MASS - fuelMass)).
}

LOCAL FUNCTION _suborbitReturnArc {
    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("SUBORBIT return mode needs Trajectories — holding.").
        yieldToPrompt().
        RETURN.
    }
    LOCAL siteGeo IS _suborbitSiteGeo().
    LOCAL tol IS _launchCfgNum("SUBORBIT_RETURN_TOL", 40000).
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.
    // MechJeb must NOT circularize — the sweep burn is ours.
    IF ADDONS:MJ:AVAILABLE {
        SET ADDONS:MJ:ASCENT:SKIPCIRCULARIZATION TO TRUE.
    }
    mLog("Return arc: target site " + ROUND(siteGeo:LAT, 3) + ","
        + ROUND(siteGeo:LNG, 3) + " tol " + ROUND(tol / 1000, 0) + "km.").

    // Ride the MechJeb boost, then take over above the atmosphere.
    WAIT UNTIL SHIP:ALTITUDE >= atmTop
        OR ABORT OR AG10.
    IF ABORT OR AG10 { launchAbort(). RETURN. }
    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }

    // Budget check first (elements are fixed while coasting):
    // vis-viva dv to the drag-grazing return arc vs the
    // rocket-equation estimate for the stage. Not enough → fly
    // the plain hop, don't waste fuel on half an arc.
    LOCAL needDv IS _suborbitArcDvRequired().
    LOCAL haveDv IS _suborbitArcDvBudget().
    LOCAL burnAcc IS MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
    LOCAL burnTime IS needDv / burnAcc.
    mLog("Return arc burn: need ~" + ROUND(needDv, 0) + " m/s (~"
        + ROUND(burnTime, 0) + "s); stage holds ~"
        + ROUND(haveDv, 0) + " m/s.").
    IF haveDv > 0 AND haveDv < needDv * 1.05 + 20 {
        mLogError("Insufficient dV for the return arc — flying the"
            + " plain hop to descent instead.").
        mLogWarn("STATS suborbit-return abort reason=insufficient-dv"
            + " need=" + ROUND(needDv, 0)
            + " have=" + ROUND(haveDv, 0)).
        UNLOCK STEERING.
        SET SAS TO TRUE.
        nextPhase(launchSeq).
        RETURN.
    }

    // Start the burn HALF ITS DURATION before apoapsis, like a
    // MechJeb circularization — flight-found: starting at Ap puts
    // half the dv in while already descending, too late.
    LOCAL burnStartUt IS TIME:SECONDS + ETA:APOAPSIS - burnTime / 2.
    IF SHIP:VERTICALSPEED < 0 OR ETA:APOAPSIS > 600 {
        SET burnStartUt TO TIME:SECONDS.
    }
    LOCAL alarmId IS "".
    IF ADDONS:KAC:AVAILABLE AND burnStartUt - TIME:SECONDS > 90 {
        LOCAL alm IS ADDALARM("Raw", burnStartUt - 30,
            "Arc burn: " + SHIP:NAME, "Auto-created by SUBORBIT").
        SET alm:ACTION TO "KillWarp".
        SET alarmId TO alm:ID.
    }
    mLog("Arc burn starts in " + ROUND(burnStartUt - TIME:SECONDS, 0)
        + "s (Ap in " + ROUND(ETA:APOAPSIS, 0) + "s, burn ~"
        + ROUND(burnTime, 0) + "s).").
    LOCK STEERING TO VXCL(UP:VECTOR, SHIP:VELOCITY:ORBIT).
    WAIT UNTIL TIME:SECONDS >= burnStartUt OR ABORT OR AG10.
    SET WARP TO 0.
    IF alarmId <> "" { DELETEALARM(alarmId). }
    IF ABORT OR AG10 { launchAbort(). RETURN. }

    // Sweep burn: HORIZONTAL, until the predicted impact point
    // has swept east AROUND THE GLOBE back to the site. Tracked
    // as remaining eastward longitude (starts ~357 deg, decreases
    // monotonically to 0), NOT distance — flight-found: the
    // initial impact is just downrange, a few hundred km from the
    // site by chord, and a distance trigger cut the burn at
    // 1350 m/s then 'fixed' the hop retrograde into the ground.
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL prevRemaining IS 999.
    LOCAL noImpactSince IS -1.
    LOCAL nextProgressLog IS 0.
    LOCAL sweepDeadline IS TIME:SECONDS + 600.
    LOCAL cutReason IS "".
    UNTIL cutReason <> "" {
        IF ABORT OR AG10 { launchAbort(). RETURN. }
        IF NOT _suborbitCanBurn() {
            SET cutReason TO "fell-into-atmosphere".
        } ELSE IF SHIP:AVAILABLETHRUST <= 0 {
            // Flameout / spent stage — flight-found: the first
            // attempts never noticed and kept 'burning' nothing.
            SET cutReason TO "out-of-fuel".
        } ELSE IF TIME:SECONDS > sweepDeadline {
            SET cutReason TO "timeout".
        } ELSE IF NOT ADDONS:TR:HASIMPACT {
            // No impact + Pe above the atmosphere = genuinely
            // orbital. Below that it's a transient Trajectories
            // gap — keep going briefly, don't cut on it.
            IF SHIP:PERIAPSIS > atmTop {
                SET cutReason TO "impact-lost-orbital".
            } ELSE {
                IF noImpactSince < 0 { SET noImpactSince TO TIME:SECONDS. }
                IF TIME:SECONDS - noImpactSince > 15 {
                    SET cutReason TO "impact-lost".
                }
                SET throttleCmd TO 0.
            }
        } ELSE {
            SET noImpactSince TO -1.
            // The return arc LIVES at Pe 45-55km (drag-grazing) —
            // flight-found: a 45km ceiling cut the sweep at 235
            // deg to go, but past ~58km the prediction is a
            // multi-pass decay and goes mushy (flight-found: a
            // Pe 62km cut left the landing point unknowable).
            // Stop EARLY (20 deg short) on purpose: the trim loop
            // with its measured sensitivity is the precision
            // instrument; the sweep is just the bulk burn.
            IF SHIP:PERIAPSIS > atmTop {
                SET cutReason TO "pe-too-high".
            } ELSE IF SHIP:PERIAPSIS > 58000 {
                SET cutReason TO "pe-soft-ceiling".
            } ELSE {
                LOCAL remainingEast IS
                    _norm360(siteGeo:LNG - ADDONS:TR:IMPACTPOS:LNG).
                IF remainingEast < 20 {
                    SET cutReason TO "handoff-to-trim".
                } ELSE IF prevRemaining < 90
                        AND remainingEast > prevRemaining + 180 {
                    // Jumped past the site between ticks.
                    SET cutReason TO "overshot-crossing".
                }
                SET prevRemaining TO remainingEast.
                SET throttleCmd TO
                    CHOOSE 0.05 IF remainingEast < 45
                    ELSE CHOOSE 0.3 IF remainingEast < 90 ELSE 1.
                IF TIME:SECONDS > nextProgressLog {
                    SET nextProgressLog TO TIME:SECONDS + 12.
                    mLog("Sweep: " + ROUND(remainingEast, 0)
                        + " deg to go  Pe="
                        + ROUND(SHIP:PERIAPSIS / 1000, 1)
                        + "km  vSurf="
                        + ROUND(SHIP:VELOCITY:SURFACE:MAG, 0) + ".").
                }
            }
        }
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    mLogWarn("STATS suborbit-return cutoff reason=" + cutReason
        + " remaining=" + ROUND(prevRemaining, 1)
        + " dist=" + ROUND(MAX(-1, _suborbitImpactDist(siteGeo)) / 1000, 0)
        + "km ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
        + " vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 0)).

    IF cutReason = "fell-into-atmosphere" OR cutReason = "out-of-fuel"
            OR cutReason = "timeout" OR cutReason = "impact-lost" {
        // Auto-bailout: the arc cannot be completed (or fixed).
        // Stop flying it and hand straight off to DESCENT, which
        // arms the chutes — never try to burn a bad trajectory
        // better, and never assume there is fuel left to do it.
        mLogError("Return arc abandoned (" + cutReason
            + ") — proceeding directly to descent.").
        UNLOCK STEERING.
        SET SAS TO TRUE.
        nextPhase(launchSeq).
        RETURN.
    }

    _suborbitTrimArc(siteGeo, tol).
    IF ABORT { RETURN. }
    SET SAS TO TRUE.
    LOCAL finalDist IS _suborbitImpactDist(siteGeo).
    IF finalDist >= 0 AND finalDist <= tol {
        mLog("ON TARGET: predicted impact "
            + ROUND(finalDist / 1000, 0) + "km from the site.").
    } ELSE IF finalDist >= 0 {
        mLogWarn("OFF TARGET: predicted impact "
            + ROUND(finalDist / 1000, 0) + "km from the site (tol "
            + ROUND(tol / 1000, 0) + "km) — descent flies it anyway.").
    } ELSE {
        mLogWarn("No impact prediction — descent will manage entry.").
    }
    nextPhase(launchSeq).
}

// ── Descent watchdog ─────────────────────────────────────────
// The SUBORBIT -> DESCENT handoff must NEVER be missed. This is
// the backstop for the backstops: if the ship is falling inside
// the atmosphere and the phase is still SUBORBIT — whatever loop
// or wait the main code is wedged in — force the transition and
// reboot into the descent band. kOS WHEN triggers run every
// tick, even while the main thread sits in a WAIT.
LOCAL _descentWatchdogArmed IS FALSE.
LOCAL FUNCTION _armDescentWatchdog {
    IF _descentWatchdogArmed { RETURN. }
    SET _descentWatchdogArmed TO TRUE.
    WHEN SHIP:VERTICALSPEED < -50
            AND SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT - 5000
            AND stateGet("phase", "") = "SUBORBIT" THEN {
        mLogError("DESCENT WATCHDOG: falling in atmosphere with"
            + " phase=SUBORBIT — forcing descent and rebooting.").
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        stateSet("phase", "DESCENT").
        stateSet("reload_required", "true").
        stateSet("reload_reason", "DESCENT_WATCHDOG").
        stateSet("reload_next_phase", "DESCENT").
        stateSet("reload_next_band",
            bootLibBandForPhase("DESCENT", "AEROBRAKE")).
        WAIT 0.5.
        REBOOT.
    }
}

// ── Suborbital cutoff ────────────────────────────────────────
// For crewed suborbital hops (SEQUENCE LAUNCH,SUBORBIT,DESCENT,
// DONE): lets the MechJeb ascent boost until apoapsis reaches
// PARKING_ALT, then kills the autopilot and coasts ballistic —
// no circularization, the ship falls back for a chute landing
// downrange. With SUBORBIT_RETURN = 1 it instead flies the
// round-the-world arc back to the launch site (above).
// Resume-safe: re-running just re-disables MechJeb.
GLOBAL FUNCTION phaseSuborbit {
    _armDescentWatchdog().
    IF _launchCfgNum("SUBORBIT_RETURN", 0) > 0 {
        _suborbitReturnArc().
        RETURN.
    }
    LOCAL targetAp IS _launchCfgNum("PARKING_ALT", 80000).
    mLog("Suborbital: boosting to Ap " + ROUND(targetAp/1000, 0)
        + "km, then engine cutoff (no circularization).").

    IF SHIP:APOAPSIS < targetAp * 0.95 {
        WAIT UNTIL SHIP:APOAPSIS >= targetAp * 0.95
            OR NOT (ADDONS:MJ:AVAILABLE AND ADDONS:MJ:ASCENT:ENABLED)
            OR ABORT OR AG10.
    }
    IF ABORT OR AG10 {
        launchAbort().
        RETURN.
    }

    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    mLogWarn("STATS suborbit cutoff ApKm=" + ROUND(SHIP:APOAPSIS/1000, 1)
        + " altKm=" + ROUND(SHIP:ALTITUDE/1000, 1)
        + " vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)).

    // Hold surface prograde for the rest of the climb out of the
    // atmosphere so the stack stays stable after cutoff.
    IF SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT
            AND SHIP:VERTICALSPEED > 0 {
        LOCK STEERING TO SHIP:SRFPROGRADE.
        WAIT UNTIL SHIP:ALTITUDE >= SHIP:BODY:ATM:HEIGHT
            OR SHIP:VERTICALSPEED < 0 OR ABORT.
        UNLOCK STEERING.
    }
    IF ABORT { RETURN. }
    SET SAS TO TRUE.
    mLog("Suborbital cutoff complete: Ap=" + ROUND(SHIP:APOAPSIS/1000, 1)
        + "km. Falling back for descent.").
    nextPhase(launchSeq).
}
