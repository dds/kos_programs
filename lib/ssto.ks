// ============================================================
// ssto.ks  —  Spaceplane / SSTO mission phases  (0:/lib/ssto.ks)
//
// Bridges the AIR and orbital worlds. A round trip is just:
//   SEQUENCE = PREFLIGHT,AIRCLIMB,ROCKETCLIMB,
//              SSTO_DEORBIT,REENTRY,APPROACH,DONE
// with any orbital work (GOTO, RDV, SHAPE, payload phases)
// spliced between ROCKETCLIMB and SSTO_DEORBIT — once
// ROCKETCLIMB ends you are a normal orbital vessel.
//
// Phases:
//   AIRCLIMB     — airbreathing speedrun: heading/altitude hold at
//                  the rapier sweet spot, full throttle, switch
//                  when acceleration decays (or at a speed gate)
//   ROCKETCLIMB  — engine mode switch + closed intakes, fixed
//                  pitch program to target Ap, coast, circularize
//   SSTO_DEORBIT — retro burn timed by ground-track longitude
//                  lead ahead of the runway
//   REENTRY      — surface-prograde + AoA attitude hold through
//                  entry heating until subsonic-ish, then hands
//                  the airframe back to the airplane assists
//   APPROACH     — glideslope + localizer capture to the runway
//                  from PLANE_APPROACHES, callouts to decision
//                  height; auto reversers handle the rollout
//
// Global config keys (defaults in lib/config.ks):
//   SSTO_ASCENT_HDG (90)        SSTO_AIR_ALT (18000)
//   SSTO_SWITCH_ACCEL (0.2)     SSTO_SWITCH_MIN_SPEED (350)
//   SSTO_SWITCH_SPEED (1400)    SSTO_MODE_AG (3)
//   SSTO_CLOSE_INTAKES (1)      SSTO_ROCKET_PITCH (18)
//   SSTO_TARGET_AP (80000)      SSTO_REENTRY_PE (28000)
//   SSTO_DEORBIT_LEAD_DEG (70)  SSTO_REENTRY_AOA (8)
//   SSTO_REENTRY_END_ALT (22000) SSTO_REENTRY_END_SPEED (1100)
//   SSTO_RUNWAY ("KSC")         SSTO_DECISION_AGL (150)
//
// This is a flight-test program: every phase logs STATS lines and
// expects observation telemetry running. Gains and gates WILL
// need tuning per airframe — that's what cmd/airtest.ks and the
// archive obs logs are for.
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL SSTO_TARGET_AP IS 80000.
GLOBAL SSTO_REENTRY_PE IS 28000.
GLOBAL SSTO_DEORBIT_LEAD_DEG IS 70.
GLOBAL SSTO_RUNWAY IS "KSC".
GLOBAL SSTO_AIR_ALT IS 18000.
GLOBAL SSTO_SWITCH_SPEED IS 1200.
GLOBAL SSTO_SWITCH_ACCEL IS 0.
GLOBAL SSTO_MODE_AG IS 1.
GLOBAL SSTO_ASCENT_HDG IS 90.
GLOBAL SSTO_ROCKET_PITCH IS 12.
GLOBAL SSTO_REENTRY_AOA IS 25.
GLOBAL SSTO_DECISION_AGL IS 800.
GLOBAL SSTO_CLOSE_INTAKES IS 1.
GLOBAL SSTO_SWITCH_MIN_SPEED IS 350.
GLOBAL SSTO_REENTRY_END_ALT IS 22000.
GLOBAL SSTO_REENTRY_END_SPEED IS 1100.


LOCAL MAX_RETRIES IS 5.

LOCAL FUNCTION _wrap360 {
    PARAMETER a.
    UNTIL a >= 0   { SET a TO a + 360. }
    UNTIL a < 360  { SET a TO a - 360. }
    RETURN a.
}

// Compass heading and pitch of the surface velocity vector,
// using kOS's own HEADING frame to dodge handedness questions.
LOCAL FUNCTION _velHeading {
    LOCAL vel IS SHIP:VELOCITY:SURFACE.
    RETURN _wrap360(ARCTAN2(
        VDOT(vel, HEADING(90, 0):VECTOR),
        VDOT(vel, HEADING(0, 0):VECTOR))).
}

LOCAL FUNCTION _velPitch {
    RETURN 90 - VANG(SHIP:UP:VECTOR, SHIP:VELOCITY:SURFACE).
}

LOCAL FUNCTION _sstoModeSwitch {
    LOCAL ag IS SSTO_MODE_AG.
    IF ag = 1 { TOGGLE AG1. }
    ELSE IF ag = 2 { TOGGLE AG2. }
    ELSE IF ag = 3 { TOGGLE AG3. }
    ELSE IF ag = 4 { TOGGLE AG4. }
    ELSE IF ag = 5 { TOGGLE AG5. }
    IF SSTO_CLOSE_INTAKES > 0 { INTAKES OFF. }
    mLog("Engine mode switch: AG" + ag + " toggled, intakes "
        + (CHOOSE "closed" IF SSTO_CLOSE_INTAKES > 0 ELSE "open") + ".").
}

// ============================================================
// AIRCLIMB — airbreathing speedrun
// ============================================================
GLOBAL FUNCTION phaseAirclimb {
    mLogPhase("AIRCLIMB").
    IF NOT planeActive { planeInit(). }

    LOCAL airAlt IS SSTO_AIR_ALT.
    LOCAL hdg IS SSTO_ASCENT_HDG.
    LOCAL switchAccel IS SSTO_SWITCH_ACCEL.
    LOCAL minSpeed IS SSTO_SWITCH_MIN_SPEED.
    LOCAL maxSpeed IS SSTO_SWITCH_SPEED.

    hdgHoldOn(hdg).
    altHoldOn(airAlt).
    LOCK THROTTLE TO 1.
    mLog("Speedrun: hdg=" + hdg + " alt=" + airAlt
        + " switch at accel<" + switchAccel + " or spd>" + maxSpeed + ".").

    LOCAL lastSpd IS SHIP:AIRSPEED.
    LOCAL lastT IS TIME:SECONDS.
    LOCAL accel IS 10.
    LOCAL done IS FALSE.
    UNTIL done {
        planeUpdate().
        IF TIME:SECONDS - lastT >= 2 {
            LOCAL raw IS (SHIP:AIRSPEED - lastSpd) / (TIME:SECONDS - lastT).
            SET accel TO accel * 0.6 + raw * 0.4.
            SET lastSpd TO SHIP:AIRSPEED.
            SET lastT TO TIME:SECONDS.
            IF SHIP:AIRSPEED >= maxSpeed {
                SET done TO TRUE.
                mLog("Switch gate: speed " + ROUND(SHIP:AIRSPEED, 0) + " m/s.").
            } ELSE IF SHIP:ALTITUDE > airAlt * 0.9
                    AND SHIP:AIRSPEED > minSpeed
                    AND accel < switchAccel {
                SET done TO TRUE.
                mLog("Switch gate: thrust decay (accel="
                    + ROUND(accel, 2) + " m/s2 at "
                    + ROUND(SHIP:AIRSPEED, 0) + " m/s).").
            }
        }
        WAIT 0.05.
    }

    mLog("STATS airclimb result spd=" + ROUND(SHIP:AIRSPEED, 0)
        + " alt=" + ROUND(SHIP:ALTITUDE, 0)
        + " accel=" + ROUND(accel, 2)).
    altHoldOff().
    hdgHoldOff().
    nextPhase(launchSeq).
}

// ============================================================
// ROCKETCLIMB — closed cycle to orbit
// ============================================================
GLOBAL FUNCTION phaseRocketclimb {
    mLogPhase("ROCKETCLIMB").
    LOCAL hdg IS SSTO_ASCENT_HDG.
    LOCAL pitch IS SSTO_ROCKET_PITCH.
    LOCAL targetAp IS SSTO_TARGET_AP.
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.

    _sstoModeSwitch().
    SET SAS TO FALSE.
    LOCK THROTTLE TO 1.
    LOCK STEERING TO HEADING(hdg, pitch).
    mLog("Rocket climb: pitch " + pitch + " to Ap " + ROUND(targetAp / 1000, 0) + "km.").

    UNTIL SHIP:APOAPSIS >= targetAp {
        IF SHIP:AVAILABLETHRUST <= 0 {
            mLogError("ROCKETCLIMB: no thrust after mode switch — yielding.").
            LOCK THROTTLE TO 0.
            yieldToPrompt().
            RETURN.
        }
        // Ease the nose down as Ap approaches to limit gravity losses.
        IF SHIP:APOAPSIS > targetAp * 0.85 {
            LOCK STEERING TO HEADING(hdg, MAX(5, pitch * 0.4)).
        }
        WAIT 0.1.
    }
    LOCK THROTTLE TO 0.
    mLog("Ap reached: " + ROUND(SHIP:APOAPSIS / 1000, 1) + "km. Coasting out of atmosphere.").

    // Hold prograde and top up Ap against drag until clear.
    LOCK STEERING TO SHIP:SRFPROGRADE.
    UNTIL SHIP:ALTITUDE > atmTop {
        IF SHIP:APOAPSIS < targetAp * 0.995 {
            LOCK THROTTLE TO 0.2.
        } ELSE {
            LOCK THROTTLE TO 0.
        }
        WAIT 0.2.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.

    // Circularize at Ap — after this we are a normal orbital vessel.
    LOCAL success IS FALSE.
    LOCAL retries IS 0.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planCircularize().
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            IF retries >= MAX_RETRIES {
                mLogError("ROCKETCLIMB: circularization failed after "
                    + retries + " attempts — halting.").
                RETURN.
            }
            mLog("Circularization missed (attempt " + retries + ") — retrying.").
            WAIT 10.
        }
    }
    orbitSummary().
    mLog("STATS rocketclimb result PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)).
    nextPhase(launchSeq).
}

// ============================================================
// SSTO_DEORBIT — retro burn timed by ground-track lead
//
// Future ground longitude of the ship: the geoposition of the
// inertial point drifts west as the body rotates east, so
// lng(t) = GEOPOSITIONOF(POSITIONAT(t)):LNG - rot*(t-now).
// Burn when the runway sits SSTO_DEORBIT_LEAD_DEG east of us.
// ============================================================
GLOBAL FUNCTION phaseSstoDeorbit {
    mLogPhase("SSTO_DEORBIT").
    LOCAL ap_ IS planeApproachFor(SSTO_RUNWAY).
    IF ap_ = 0 {
        mLogError("SSTO_DEORBIT: no runway data for '"
            + SSTO_RUNWAY + "' — yielding.").
        yieldToPrompt().
        RETURN.
    }
    LOCAL rwLng IS ap_["lng"].
    LOCAL lead IS SSTO_DEORBIT_LEAD_DEG.
    LOCAL reentryPe IS SSTO_REENTRY_PE.
    LOCAL rotRate IS 360 / SHIP:BODY:ROTATIONPERIOD.

    // Scan the next orbit and a half for the burn point.
    LOCAL burnUt IS -1.
    LOCAL step IS SHIP:ORBIT:PERIOD / 360.
    LOCAL t IS TIME:SECONDS + 60.
    LOCAL tEnd IS TIME:SECONDS + SHIP:ORBIT:PERIOD * 1.5.
    UNTIL t > tEnd OR burnUt > 0 {
        LOCAL geoLng IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, t)):LNG
            - rotRate * (t - TIME:SECONDS).
        LOCAL ahead IS _wrap360(rwLng - geoLng).
        IF ABS(ahead - lead) < 1.5 { SET burnUt TO t. }
        SET t TO t + step.
    }
    IF burnUt < 0 {
        mLogError("SSTO_DEORBIT: no burn window found in 1.5 orbits — yielding.").
        yieldToPrompt().
        RETURN.
    }

    // Retro burn at burnUt lowering Pe to the reentry corridor.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL rBurn IS (POSITIONAT(SHIP, burnUt) - POSITIONAT(SHIP:BODY, burnUt)):MAG.
    LOCAL rPe IS SHIP:BODY:RADIUS + reentryPe.
    LOCAL tSMA IS (rBurn + rPe) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUt):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(burnUt, 0, 0, vNew - vNow).
    ADD nd.
    mLog("Deorbit: dV=" + ROUND(nd:DELTAV:MAG, 1)
        + " m/s in " + ROUND(burnUt - TIME:SECONDS, 0)
        + "s, Pe -> " + ROUND(reentryPe / 1000, 0) + "km, lead "
        + lead + "deg ahead of " + ap_["name"] + ".").
    mLog("STATS ssto-deorbit plan dv=" + ROUND(nd:DELTAV:MAG, 1)
        + " lead=" + lead
        + " reentryPeKm=" + ROUND(reentryPe / 1000, 1)).
    maneuverUiArchiveLog("ssto-deorbit").

    IF NOT executeManeuver() {
        mLogError("SSTO_DEORBIT: burn failed — yielding for operator.").
        yieldToPrompt().
        RETURN.
    }
    nextPhase(launchSeq).
}

// ============================================================
// REENTRY — AoA attitude hold through entry heating
// ============================================================
GLOBAL FUNCTION phaseReentry {
    mLogPhase("REENTRY").
    LOCAL aoa IS SSTO_REENTRY_AOA.
    LOCAL endAlt IS SSTO_REENTRY_END_ALT.
    LOCAL endSpeed IS SSTO_REENTRY_END_SPEED.
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.

    SET SAS TO TRUE.
    UNLOCK STEERING.
    mLog("Coasting to entry interface (" + ROUND(atmTop / 1000, 0) + "km). Warp at will.").
    WAIT UNTIL SHIP:ALTITUDE < atmTop - 2000.

    SET SAS TO FALSE.
    // LOCK re-evaluates each tick, so this tracks the velocity vector.
    LOCK STEERING TO HEADING(_velHeading(), _velPitch() + aoa).
    mLog("Entry interface: holding " + aoa + "deg AoA above surface prograde.").
    mLog("STATS reentry start spd=" + ROUND(SHIP:AIRSPEED, 0)
        + " alt=" + ROUND(SHIP:ALTITUDE, 0)).

    UNTIL SHIP:ALTITUDE < endAlt AND SHIP:AIRSPEED < endSpeed {
        WAIT 0.2.
    }
    UNLOCK STEERING.
    mLog("STATS reentry end spd=" + ROUND(SHIP:AIRSPEED, 0)
        + " alt=" + ROUND(SHIP:ALTITUDE, 0)).
    mLog("Through entry — handing airframe to airplane assists.").
    IF NOT planeActive { planeInit(). }
    nextPhase(launchSeq).
}

// ============================================================
// APPROACH — glideslope + localizer to the runway, with
// callouts down to decision height. The phase keeps flying the
// assists after DH (take over with AG7 any time); touchdown +
// brakes hands the rollout to the auto thrust reversers.
// ============================================================
GLOBAL FUNCTION phaseApproach {
    mLogPhase("APPROACH").
    LOCAL ap_ IS planeApproachFor(SSTO_RUNWAY).
    IF ap_ = 0 {
        mLogError("APPROACH: no runway data — yielding (land manually).").
        yieldToPrompt().
        RETURN.
    }
    LOCAL rwGeo IS LATLNG(ap_["lat"], ap_["lng"]).
    LOCAL gs IS ap_["gs"].
    LOCAL elev IS ap_["elev"].
    LOCAL decisionAgl IS SSTO_DECISION_AGL.

    IF NOT planeActive { planeInit(). }
    planeApproachBrief(ap_["lat"], ap_["lng"], ap_["name"]).
    altHoldOn(SHIP:ALTITUDE).
    hdgHoldOn(rwGeo:HEADING).

    LOCAL calledDh IS FALSE.
    LOCAL nextCallKm IS 20.
    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        LOCAL dist IS rwGeo:DISTANCE.

        // Glideslope: never command a climb on a dead-stick glide;
        // hold at least pattern height until the slope comes up.
        LOCAL glideAlt IS elev + TAN(gs) * MAX(0, dist).
        SET targetAlt TO MIN(SHIP:ALTITUDE + 100, MAX(glideAlt, elev + 30)).

        // Localizer: fly to the threshold, then down the runway axis.
        IF dist > 4000 {
            SET targetHdg TO rwGeo:HEADING.
        } ELSE {
            SET targetHdg TO planeRunwayHeading(ap_, rwGeo:HEADING).
        }

        IF dist / 1000 < nextCallKm {
            HUDTEXT(ap_["name"] + " " + ROUND(dist / 1000, 1) + "km  gs-alt "
                + ROUND(glideAlt, 0) + "m", 4, 2, 14, CYAN, FALSE).
            mLog("Approach: " + ROUND(dist / 1000, 1) + "km, glide alt "
                + ROUND(glideAlt, 0) + "m, spd " + ROUND(SHIP:AIRSPEED, 0) + ".").
            SET nextCallKm TO CHOOSE 10 IF nextCallKm = 20
                ELSE (CHOOSE 5 IF nextCallKm = 10 ELSE (CHOOSE 2 IF nextCallKm = 5 ELSE 0)).
        }
        IF NOT calledDh AND ALT:RADAR < decisionAgl AND dist < 6000 {
            SET calledDh TO TRUE.
            HUDTEXT("DECISION HEIGHT — your airplane (AG7 drops assists)",
                8, 2, 16, YELLOW, FALSE).
            mLog("Decision height " + decisionAgl + "m AGL called.").
        }

        planeUpdate().
        WAIT 0.1.
    }

    // Rollout: brakes on, let the reverser state machine work.
    mLog("Touchdown at " + ROUND(SHIP:GROUNDSPEED, 0) + " m/s.").
    SET BRAKES TO TRUE.
    altHoldOff().
    hdgHoldOff().
    UNTIL SHIP:GROUNDSPEED < PLANE_BRAKE_STOP_SPEED {
        planeUpdate().
        WAIT 0.1.
    }
    planeShutdown().
    mLog("STATS approach result runway=" + ap_["name"]
        + " stopDist=" + ROUND(rwGeo:DISTANCE, 0)).
    mLog("Wheels stopped. " + SHIP:NAME + " home.").
    nextPhase(launchSeq).
}
