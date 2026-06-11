// ============================================================
// suborbit.ks  —  Suborbital cutoff + return arc  (0:/lib/suborbit.ks)
//
// SUBORBIT phase: plain ballistic hop cutoff, or — with
// SUBORBIT_RETURN = 1 — a round-the-world arc back to the launch
// site. Own lib so the LAUNCH band doesn't carry it for every
// rocket; suborbital missions bring it in with LIBS_EXTRA =
// suborbit, descent (loaded at the pad, every band, so the whole
// flight runs in one band without reboots).
//
// Return-arc strategy (v3 — first two were flight-failures):
//   1. Arc burn BY ELEMENTS ONLY: horizontal at apoapsis until
//      Pe reaches SUBORBIT_ARC_PE (~68km). A clean Kepler arc,
//      barely suborbital, negligible drag. No Trajectories in
//      the loop — flight-found twice that the impact prediction
//      in the drag-decay regime (Pe 45-65km) is multi-pass mush:
//      cutting on it gave Pe 47/235 deg short one flight and
//      Pe 62/'unknowable' the next.
//   2. Coast the arc around the planet: attitude free (battery),
//      KAC-alarmed, warp-friendly.
//   3. Targeted retro burn when the site is SUBORBIT_DEORBIT_LEAD
//      (~60) deg ahead: from a stable Kepler arc Trajectories is
//      trustworthy again — walk the predicted impact onto the
//      site, cut at closest approach (the landatksc deorbit
//      concept, minus the orbit).
// ============================================================

LOCAL FUNCTION _norm360 {
    PARAMETER angle.
    LOCAL result IS angle.
    UNTIL result >= 0 { SET result TO result + 360. }
    UNTIL result < 360 { SET result TO result - 360. }
    RETURN result.
}

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

// dv needed at apoapsis to stretch the arc to the target Pe —
// vis-viva on elements only, no position predictions.
LOCAL FUNCTION _suborbitArcDvRequired {
    PARAMETER rPeTargetAlt.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL rAp IS SHIP:BODY:RADIUS + SHIP:APOAPSIS.
    LOCAL rPeTarget IS SHIP:BODY:RADIUS + rPeTargetAlt.
    LOCAL vNeed IS SQRT(mu * (2 / rAp - 2 / (rAp + rPeTarget))).
    LOCAL vAp IS SQRT(MAX(0, mu * (2 / rAp - 1 / SHIP:ORBIT:SEMIMAJORAXIS))).
    RETURN MAX(0, vNeed - vAp).
}

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

// Degrees of eastward ground track between the ship and the site.
LOCAL FUNCTION _suborbitGroundRemaining {
    PARAMETER siteGeo.
    RETURN _norm360(siteGeo:LNG - SHIP:GEOPOSITION:LNG).
}

LOCAL FUNCTION _norm180 {
    PARAMETER angle.
    RETURN _norm360(angle + 180) - 180.
}

// Step 3: coast the arc, then the targeted deorbit burn.
LOCAL FUNCTION _suborbitCoastAndDeorbit {
    PARAMETER siteGeo.
    PARAMETER tol.
    PARAMETER arcPe.
    LOCAL lead IS cfgNum("SUBORBIT_DEORBIT_LEAD", 60).
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    // Ground-relative track rate: orbital motion minus the planet
    // turning underneath.
    LOCAL groundRate IS 360 / SHIP:ORBIT:PERIOD
        - 360 / SHIP:BODY:ROTATIONPERIOD.
    LOCAL remaining IS _suborbitGroundRemaining(siteGeo).
    LOCAL waitSecs IS MAX(0, (remaining - lead) / MAX(0.01, groundRate)).
    mLog("Coasting the arc: " + ROUND(remaining, 0)
        + " deg of ground track to the site; deorbit burn in ~"
        + ROUND(waitSecs, 0) + "s. Warp away.").
    // The deorbit ETA is re-estimated every 10s and the alarm
    // moved when it drifts — flight-found: drag decay brought
    // reentry early while a one-shot alarm still claimed the
    // burn was 2 minutes away at 35km altitude.
    LOCAL alarmId IS "".
    LOCAL alarmUt IS 0.
    LOCAL nextEtaCheck IS 0.
    // The arc dips below the atmosphere line around Pe BY DESIGN —
    // flight-found: an altitude < atmTop exit ended a 1531s coast
    // at 612s on the routine descent toward Pe 66km. Only well
    // below the planned Pe is the arc genuinely decaying.
    UNTIL _suborbitGroundRemaining(siteGeo) <= lead
            OR (SHIP:VERTICALSPEED < 0
                AND SHIP:ALTITUDE < arcPe - 8000)
            OR ABORT OR AG10 {
        IF TIME:SECONDS > nextEtaCheck {
            SET nextEtaCheck TO TIME:SECONDS + 10.
            LOCAL liveRate IS 360 / SHIP:ORBIT:PERIOD
                - 360 / SHIP:BODY:ROTATIONPERIOD.
            LOCAL liveEta IS MAX(0,
                (_suborbitGroundRemaining(siteGeo) - lead)
                / MAX(0.01, liveRate)).
            LOCAL newUt IS TIME:SECONDS + liveEta - 60.
            IF ADDONS:KAC:AVAILABLE AND liveEta > 70
                    AND ABS(newUt - alarmUt) > 45 {
                IF alarmId <> "" { DELETEALARM(alarmId). }
                LOCAL alm IS ADDALARM("Raw", newUt,
                    "Deorbit burn: " + SHIP:NAME,
                    "Auto-created by SUBORBIT").
                SET alm:ACTION TO "KillWarp".
                SET alarmId TO alm:ID.
                SET alarmUt TO newUt.
            }
        }
        WAIT 1.
    }
    SET WARP TO 0.
    IF alarmId <> "" { DELETEALARM(alarmId). }
    IF ABORT OR AG10 { launchAbort(). RETURN. }
    IF SHIP:ALTITUDE < arcPe - 8000 AND SHIP:VERTICALSPEED < 0 {
        mLogWarn("Arc decayed early — straight to descent.").
        nextPhase(launchSeq).
        RETURN.
    }

    // Direction: drag on the Pe dip may have already pulled the
    // unpowered impact SHORT of the site — then the burn must
    // EXTEND the arc (prograde), not shorten it (retrograde).
    WAIT 2.
    LOCAL goPro IS FALSE.
    IF ADDONS:TR:HASIMPACT {
        LOCAL alongErr IS _norm180(siteGeo:LNG - ADDONS:TR:IMPACTPOS:LNG).
        SET goPro TO alongErr > 0.
    }
    mLog("Deorbit burn ("
        + (CHOOSE "prograde: extending a short arc" IF goPro
           ELSE "retrograde: pulling the impact back")
        + ") — walking the predicted impact onto the site.").
    IF goPro { LOCK STEERING TO SHIP:PROGRADE. }
    ELSE { LOCK STEERING TO SHIP:RETROGRADE. }
    WAIT 5.
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL dMin IS 1e12.
    LOCAL nextLog IS 0.
    LOCAL walkDeadline IS TIME:SECONDS + 240.
    LOCAL reason IS "".
    UNTIL reason <> "" {
        IF ABORT OR AG10 { launchAbort(). RETURN. }
        LOCAL d IS _suborbitImpactDist(siteGeo).
        IF SHIP:AVAILABLETHRUST <= 0 {
            SET reason TO "out-of-fuel".
        } ELSE IF TIME:SECONDS > walkDeadline {
            SET reason TO "timeout".
        } ELSE IF NOT goPro AND SHIP:PERIAPSIS < 10000 {
            SET reason TO "pe-floor".
        } ELSE IF goPro AND SHIP:PERIAPSIS > atmTop - 1000 {
            SET reason TO "pe-ceiling".
        } ELSE IF d >= 0 {
            IF d < dMin { SET dMin TO d. }
            IF d <= tol {
                SET reason TO "on-target".
            } ELSE IF dMin < tol * 4 AND d > dMin * 1.3 {
                SET reason TO "past-closest".
            }
        }
        SET throttleCmd TO CHOOSE 0.05 IF d >= 0 AND d < tol * 5 ELSE 0.2.
        IF TIME:SECONDS > nextLog {
            SET nextLog TO TIME:SECONDS + 8.
            mLog("Deorbit: impact "
                + (CHOOSE ROUND(d / 1000, 0) + "km from site" IF d >= 0
                   ELSE "(no prediction yet)")
                + "  Pe=" + ROUND(SHIP:PERIAPSIS / 1000, 1) + "km.").
        }
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.

    LOCAL finalDist IS _suborbitImpactDist(siteGeo).
    mLogWarn("STATS suborbit-return deorbit reason=" + reason
        + " dist=" + ROUND(MAX(-1, finalDist) / 1000, 0)
        + "km PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)).
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

LOCAL FUNCTION _suborbitReturnArc {
    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("SUBORBIT return mode needs Trajectories — holding.").
        yieldToPrompt().
        RETURN.
    }
    LOCAL siteGeo IS _suborbitSiteGeo().
    LOCAL tol IS cfgNum("SUBORBIT_RETURN_TOL", 40000).
    LOCAL arcPe IS cfgNum("SUBORBIT_ARC_PE", 68000).
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.
    // MechJeb must NOT circularize — the arc burn is ours.
    IF ADDONS:MJ:AVAILABLE {
        SET ADDONS:MJ:ASCENT:SKIPCIRCULARIZATION TO TRUE.
    }
    mLog("Return arc: site " + ROUND(siteGeo:LAT, 3) + ","
        + ROUND(siteGeo:LNG, 3) + "  arc Pe "
        + ROUND(arcPe / 1000, 0) + "km  tol "
        + ROUND(tol / 1000, 0) + "km.").

    // Ride the MechJeb boost, then take over above the atmosphere.
    WAIT UNTIL SHIP:ALTITUDE >= atmTop OR ABORT OR AG10.
    IF ABORT OR AG10 { launchAbort(). RETURN. }
    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }

    // The arc must CLEAR the atmosphere except for the Pe dip —
    // flight-found: a 74km Ap arc skimmed drag the entire
    // revolution and decayed down at the Desert Airfield.
    IF SHIP:APOAPSIS < atmTop + 10000 {
        mLogWarn("Ap " + ROUND(SHIP:APOAPSIS / 1000, 1)
            + "km barely clears the atmosphere — the whole arc"
            + " will skim and decay early. PARKING_ALT >= "
            + ROUND((atmTop + 15000) / 1000, 0) + "km recommended.").
    }

    // Budget check (elements are fixed while coasting). Reserve
    // ~80 m/s on top for the targeted deorbit burn.
    LOCAL needDv IS _suborbitArcDvRequired(arcPe).
    LOCAL haveDv IS _suborbitArcDvBudget().
    LOCAL burnAcc IS MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
    LOCAL burnTime IS needDv / burnAcc.
    mLog("Arc burn: need ~" + ROUND(needDv, 0) + " m/s (~"
        + ROUND(burnTime, 0) + "s) + ~80 deorbit; stage holds ~"
        + ROUND(haveDv, 0) + " m/s.").
    IF haveDv > 0 AND haveDv < needDv * 1.05 + 80 {
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
    // Even a short wait gets the alarm — flight-found: a 57s wait
    // fell under the old 90s threshold, so the burn arrived with
    // no warning at all.
    IF ADDONS:KAC:AVAILABLE AND burnStartUt - TIME:SECONDS > 35 {
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

    // Arc burn: horizontal until Pe reaches the target. Elements
    // only — Trajectories has no business here.
    LOCAL throttleCmd IS 0.
    LOCK THROTTLE TO throttleCmd.
    LOCAL nextProgressLog IS 0.
    LOCAL sweepDeadline IS TIME:SECONDS + 600.
    LOCAL cutReason IS "".
    UNTIL cutReason <> "" {
        IF ABORT OR AG10 { launchAbort(). RETURN. }
        IF NOT _suborbitCanBurn() {
            SET cutReason TO "fell-into-atmosphere".
        } ELSE IF SHIP:AVAILABLETHRUST <= 0 {
            SET cutReason TO "out-of-fuel".
        } ELSE IF TIME:SECONDS > sweepDeadline {
            SET cutReason TO "timeout".
        } ELSE IF SHIP:PERIAPSIS >= arcPe {
            SET cutReason TO "arc-set".
        } ELSE {
            SET throttleCmd TO
                CHOOSE 0.05 IF SHIP:PERIAPSIS > arcPe - 1500
                ELSE CHOOSE 0.25 IF SHIP:PERIAPSIS > arcPe - 8000
                ELSE 1.
            IF TIME:SECONDS > nextProgressLog {
                SET nextProgressLog TO TIME:SECONDS + 12.
                mLog("Arc burn: Pe=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
                    + "km of " + ROUND(arcPe / 1000, 0)
                    + "km  vSurf="
                    + ROUND(SHIP:VELOCITY:SURFACE:MAG, 0) + ".").
            }
        }
        WAIT 0.05.
    }
    SET throttleCmd TO 0.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    mLogWarn("STATS suborbit-return arc reason=" + cutReason
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
        + " vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 0)).

    IF cutReason <> "arc-set" {
        // Auto-bailout: stop flying the arc, hand off to DESCENT
        // (chutes armed) — never burn a bad trajectory better,
        // never assume there is fuel left to do it.
        mLogError("Return arc abandoned (" + cutReason
            + ") — proceeding directly to descent.").
        UNLOCK STEERING.
        SET SAS TO TRUE.
        nextPhase(launchSeq).
        RETURN.
    }

    _suborbitCoastAndDeorbit(siteGeo, tol, arcPe).
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
    IF cfgNum("SUBORBIT_RETURN", 0) > 0 {
        _suborbitReturnArc().
        RETURN.
    }
    LOCAL targetAp IS cfgNum("PARKING_ALT", 80000).
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
