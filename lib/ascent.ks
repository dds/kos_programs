// ============================================================
// ascent.ks  —  Airless-body ascent + ascent staging  (0:/lib/ascent.ks)
//
// Lifts off any airless body (Mun, Minmus, …) on our own guidance
// and circularizes into the configured PARKING_ALT / LAUNCH_AZIMUTH
// WITHOUT a maneuver node — so the LAUNCH band no longer has to load
// the maneuver/maneuver_plan executor just to park after ascent.
// Atmospheric (Kerbin) ascent still uses MechJeb in launch.ks; the
// auto-staging machinery lives here because it is shared by both.
//
// Reads ascent config (PARKING_ALT, LAUNCH_INCLINATION,
// LAUNCH_AZIMUTH, LAUNCH_SOLID_STAGE_FRAC, RECOVERY_PE) owned by
// launch.ks — both libs are always co-loaded in the LAUNCH band.
// ============================================================

LOCAL _stagingArmed IS FALSE.
LOCAL _noThrustStages IS 0.
LOCAL _solidStageNumber IS -1.
LOCAL _solidStagePeak IS 0.
LOCAL _ascentStageReason IS "".
LOCAL _ascentStageSolidFrac IS -1.

LOCAL FUNCTION _ascentOnSurface {
    RETURN SHIP:STATUS = "PRELAUNCH"
        OR SHIP:STATUS = "LANDED"
        OR SHIP:STATUS = "SPLASHED".
}

LOCAL FUNCTION _launchSolidStageFrac {
    LOCAL frac IS LAUNCH_SOLID_STAGE_FRAC.
    IF frac > 1 { SET frac TO frac / 100. }
    RETURN MAX(0, MIN(1, frac)).
}

// One cheap state read per tick for the ascent watcher's WHEN
// condition (was five) — also a mitigation candidate for the
// mainline starvation seen during MJ's coast (ANTS stall).
GLOBAL FUNCTION bootLibAscentWatchPhase {
    LOCAL ph IS stateGet("phase", "").
    RETURN ph = "LAUNCH" OR ph = "FAIR" OR ph = "ANTS"
        OR ph = "PARK" OR ph = "SUBORBIT".
}

GLOBAL FUNCTION ascentStageAttemptPending {
    IF NOT _stagingArmed { RETURN FALSE. }
    IF STAGE:NUMBER <= 0 { RETURN FALSE. }
    IF _noThrustStages >= 2 { RETURN FALSE. }
    IF NOT ADDONS:MJ:AVAILABLE { RETURN FALSE. }
    IF NOT ADDONS:MJ:ASCENT:ENABLED
            AND NOT bootLibAscentWatchPhase() { RETURN FALSE. }
    RETURN TRUE.
}

GLOBAL FUNCTION ascentRunPostStageHook {
    LOCAL postStageHook IS stateGet("post_stage_hook", ""):TRIM.
    IF postStageHook <> "" {
        IF EXISTS(postStageHook) {
            mLog("Running post-stage hook: " + postStageHook + ".").
            RUNPATH(postStageHook).
        } ELSE {
            mLogWarn("Post-stage hook not found: " + postStageHook + ".").
        }
    }
}

GLOBAL FUNCTION ascentNeedsStage {
    SET _ascentStageReason TO "".
    SET _ascentStageSolidFrac TO -1.

    LOCAL stageNum IS STAGE:NUMBER.
    IF stageNum <> _solidStageNumber {
        SET _solidStageNumber TO stageNum.
        SET _solidStagePeak TO 0.
    }

    LOCAL solidStageFrac IS _launchSolidStageFrac().
    IF solidStageFrac > 0 {
        LOCAL solidFuel IS STAGE:SOLIDFUEL.
        IF solidFuel > _solidStagePeak {
            SET _solidStagePeak TO solidFuel.
        }
        IF _solidStagePeak > 0 {
            SET _ascentStageSolidFrac TO solidFuel / _solidStagePeak.
            IF solidFuel <= _solidStagePeak * solidStageFrac {
                SET _ascentStageReason TO "solid-fuel-low".
                RETURN TRUE.
            }
        }
    }

    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs {
        IF eng:FLAMEOUT {
            SET _ascentStageReason TO "flameout".
            RETURN TRUE.
        }
    }
    IF SHIP:MAXTHRUST = 0 {
        SET _ascentStageReason TO "no-max-thrust".
        RETURN TRUE.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION armAscentStaging {
    IF _stagingArmed { RETURN. }
    SET _stagingArmed TO TRUE.

    WHEN ascentNeedsStage() THEN {
        LOCAL ph IS stateGet("phase","").
        IF ph = "DONE" OR ph = "ABORT" { RETURN. }
        // Null-safety order matters — flight-found: an
        // out-of-fuel final staging during PARK was followed by
        // 'object reference not set' (MJ suffixes can throw once
        // the unit's stage is gone) and, with no engines left,
        // needs-stage stays true forever and would machine-gun
        // STAGE through chute/decoupler stages.
        IF STAGE:NUMBER <= 0 { RETURN. }
        // Allow staging during any ascent phase even if MJ2 dropped
        // out mid-circularization (e.g. methane booster may burn past
        // the gravity turn all the way to near-orbit; MJ2 disables
        // itself when it detects no thrust, but we still need to
        // separate the spent stage and ignite the upper stage).
        IF NOT bootLibAscentWatchPhase() { RETURN. }
        IF _noThrustStages >= 2 {
            mLogError("Two stagings without thrust — no engines"
                + " left; disarming ascent staging.").
            RETURN.
        }
        LOCAL reason IS _ascentStageReason.
        IF reason = "" { SET reason TO "needs-stage". }
        LOCAL solidDetail IS "".
        IF _ascentStageSolidFrac >= 0 {
            SET solidDetail TO " solid="
                + ROUND(_ascentStageSolidFrac * 100, 1) + "%".
        }
        mLog("Ascent auto-stage (" + reason + solidDetail + ") at alt="
            + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
        HUDTEXT("Staging!", 2, 2, 14, YELLOW, FALSE).
        STAGE.
        SET _solidStageNumber TO -1.
        SET _solidStagePeak TO 0.
        SET _ascentStageReason TO "".
        SET _ascentStageSolidFrac TO -1.
        WAIT 0.5.
        IF SHIP:MAXTHRUST > 0 {
            SET _noThrustStages TO 0.
            // MJ2 may have disabled itself when the booster flamed
            // out — re-enable so it finishes the circularization with
            // the freshly-ignited upper stage.
            IF SHIP:BODY:ATM:EXISTS
                    AND ADDONS:MJ:AVAILABLE
                    AND NOT ADDONS:MJ:ASCENT:ENABLED
                    AND bootLibAscentWatchPhase() {
                SET ADDONS:MJ:ASCENT:ENABLED TO TRUE.
                mLog("MJ2 ascent re-enabled after mid-circ staging.").
            }
        } ELSE {
            SET _noThrustStages TO _noThrustStages + 1.
        }
        PRESERVE.
    }

    IF RECOVERY_PE >= 0 {
        WHEN SHIP:PERIAPSIS >= RECOVERY_PE
                AND ADDONS:MJ:AVAILABLE AND ADDONS:MJ:ASCENT:ENABLED THEN {
            mLog("Recovery staging: Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km, ejecting stage.").
            HUDTEXT("Recovery staging!", 3, 2, 14, YELLOW, FALSE).
            SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
            LOCK THROTTLE TO 0.
            WAIT 0.3.
            STAGE.
            WAIT 0.5.
            mLog("Ascent complete post-staging, raising Pe now.").
            LOCK STEERING TO SHIP:PROGRADE.
            LOCK THROTTLE TO 1.
            WAIT UNTIL SHIP:PERIAPSIS >= PARKING_ALT * 0.95.
            LOCK THROTTLE TO 0.
            UNLOCK THROTTLE.
            UNLOCK STEERING.
            SET SAS TO TRUE.
            orbitSummary().
            stateSet("phase", "PARK").
        }
    }

    mLog("Ascent staging armed.").
}

// ── Airless ascent guidance ─────────────────────────────────

LOCAL FUNCTION _vacuumTargetOrbitalVelocity {
    LOCAL targetRadius IS SHIP:BODY:RADIUS + PARKING_ALT.
    RETURN SQRT(SHIP:BODY:MU / targetRadius).
}

LOCAL FUNCTION _vacuumAscentPitch {
    PARAMETER targetVel.
    LOCAL speedFrac IS SHIP:VELOCITY:ORBIT:MAG / MAX(1, targetVel).
    SET speedFrac TO MAX(0, MIN(1, speedFrac)).

    LOCAL pitch IS 90 * (1 - speedFrac).
    IF SHIP:VERTICALSPEED < 10 AND SHIP:APOAPSIS < PARKING_ALT * 0.95 {
        SET pitch TO MAX(pitch, 20).
    }
    IF SHIP:VERTICALSPEED < 0 AND SHIP:APOAPSIS < PARKING_ALT {
        SET pitch TO MAX(pitch, 45).
    }
    RETURN MAX(0, MIN(90, pitch)).
}

LOCAL FUNCTION _logVacuumAscentTelemetry {
    PARAMETER pitchAngle.
    mLog("Vacuum ascent: radar="
        + ROUND(ALT:RADAR, 0) + "m Ap="
        + ROUND(SHIP:APOAPSIS / 1000, 2) + "km pitch="
        + ROUND(pitchAngle, 1) + "deg vOrb="
        + ROUND(SHIP:VELOCITY:ORBIT:MAG, 1) + "m/s.").
}

// Compass heading to reach LAUNCH_INCLINATION from the launch
// latitude (standard launch-azimuth identity sin(az)=cos(i)/cos(lat),
// az measured from north). Eastward/prograde solutions only — the
// surface-return case wants a prograde orbit aligned with the Mun's
// motion. A target inclination below the launch latitude is
// unreachable by direct ascent, so fly due east (90) for the minimum
// (inclination = latitude); a plane-change burn would be needed to go
// lower. Body rotation is ignored (negligible on Mun/Minmus).
LOCAL FUNCTION _ascentAzimuth {
    LOCAL phi IS ABS(SHIP:LATITUDE).
    LOCAL denom IS COS(phi).
    IF denom < 0.0001 { RETURN 90. }
    LOCAL ratio IS COS(ABS(LAUNCH_INCLINATION)) / denom.
    IF ratio >= 1 { RETURN 90. }
    IF ratio <= -1 { RETURN 90. }
    RETURN ARCSIN(ratio).
}

// Horizontal (circularization) burn direction at the current point:
// orbital velocity with its radial component removed — perpendicular
// to "up", in-plane, prograde. Burning THIS raises periapsis toward
// apoapsis without the radial component that live SHIP:PROGRADE gains
// once past apoapsis (which would pour dV into apoapsis instead).
LOCAL FUNCTION _circBurnVec {
    LOCAL horiz IS VXCL(SHIP:UP:VECTOR, SHIP:VELOCITY:ORBIT).
    IF horiz:MAG < 1 { RETURN SHIP:VELOCITY:ORBIT. }
    RETURN horiz.
}

// HUD countdown cadence: tighten as ignition nears (mirrors the
// landing HUD notices).
LOCAL FUNCTION _circHudInterval {
    PARAMETER etaSeconds.
    IF etaSeconds <= 10 { RETURN 1. }
    IF etaSeconds <= 30 { RETURN 5. }
    RETURN 10.
}

// Circularize at apoapsis with a direct burn — no maneuver node, no
// executeManeuver. Steers the horizontal circularization vector (NOT
// live prograde) centered on apoapsis, and terminates when periapsis
// reaches PARKING_ALT, with an integrated-dV cap as a runaway guard.
// Auto-staging is handled by the armAscentStaging WHEN already armed.
LOCAL FUNCTION _ascentCircularize {
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL bodyR IS SHIP:BODY:RADIUS.
    LOCAL targetPe IS PARKING_ALT * 0.99.

    LOCAL rAp IS bodyR + SHIP:APOAPSIS.
    LOCAL vApCirc IS SQRT(mu / rAp).
    LOCAL vApNow IS SQRT(MAX(0, mu * (2 / rAp - 1 / SHIP:ORBIT:SEMIMAJORAXIS))).
    LOCAL dv IS MAX(0, vApCirc - vApNow).
    LOCAL acc0 IS SHIP:AVAILABLETHRUST / MAX(0.01, SHIP:MASS).
    LOCAL burnTime IS 0.
    IF acc0 > 0 { SET burnTime TO dv / acc0. }
    LOCAL lead IS MIN(burnTime / 2, MAX(0, ETA:APOAPSIS)).
    LOCAL igniteUt IS TIME:SECONDS + MAX(0, ETA:APOAPSIS - lead).
    LOCAL dvCap IS dv * 1.5 + 20.

    mLog("Circularize: dv=" + ROUND(dv, 1) + "m/s burnT="
        + ROUND(burnTime, 1) + "s lead=" + ROUND(lead, 1)
        + "s etaAp=" + ROUND(ETA:APOAPSIS, 0) + "s.").
    mLogWarn("STATS ascent circularize plan dv=" + ROUND(dv, 1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 2)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 2)
        + " targetPeKm=" + ROUND(targetPe / 1000, 2)).

    SAS OFF.
    LOCK STEERING TO _circBurnVec().
    IF igniteUt > TIME:SECONDS + 5 {
        coastAutoWarp(igniteUt, "Circularize coast", "").
    }
    LOCAL nextHud IS 0.
    UNTIL TIME:SECONDS >= igniteUt OR ABORT OR SHIP:PERIAPSIS >= targetPe {
        IF TIME:SECONDS >= nextHud {
            LOCAL etaIg IS MAX(0, igniteUt - TIME:SECONDS).
            HUDTEXT("Circularize burn in " + ROUND(etaIg, 0) + "s",
                2, 2, 16, YELLOW, FALSE).
            SET nextHud TO TIME:SECONDS + _circHudInterval(etaIg).
        }
        WAIT 0.5.
    }
    IF ABORT {
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        RETURN FALSE.
    }

    HUDTEXT("Circularizing", 5, 2, 16, GREEN, FALSE).
    // Drive toward the circular-velocity VECTOR at the current radius
    // (horizontal at circular speed); steering the remaining-dV vector
    // also nulls any residual vertical speed, and tapering throttle as
    // it shrinks settles onto the circle instead of overshooting Ap.
    LOCAL appliedDv IS 0.
    LOCAL lastT IS TIME:SECONDS.
    LOCAL nextLog IS TIME:SECONDS.
    LOCAL throt IS 1.
    LOCK THROTTLE TO throt.
    UNTIL ABORT OR appliedDv >= dvCap {
        LOCAL rMag IS bodyR + SHIP:ALTITUDE.
        LOCAL vCircVec IS VXCL(SHIP:UP:VECTOR, SHIP:VELOCITY:ORBIT):NORMALIZED
            * SQRT(mu / rMag).
        LOCAL remVec IS vCircVec - SHIP:VELOCITY:ORBIT.
        LOCAL remDv IS remVec:MAG.
        IF remDv <= 0.3 { BREAK. }
        IF remDv > 1 { LOCK STEERING TO remVec. }
        SET throt TO MAX(0.05, MIN(1, remDv / 40)).
        LOCK THROTTLE TO throt.
        LOCAL nowT IS TIME:SECONDS.
        SET appliedDv TO appliedDv
            + (SHIP:AVAILABLETHRUST / MAX(0.01, SHIP:MASS)) * throt * (nowT - lastT).
        SET lastT TO nowT.
        IF SHIP:MAXTHRUST <= 0 AND NOT ascentStageAttemptPending() {
            mLogWarn("Circularize: no thrust and no stage pending; stopping.").
            BREAK.
        }
        IF TIME:SECONDS >= nextLog {
            SET nextLog TO TIME:SECONDS + 2.
            mLog("Circularize: Pe=" + ROUND(SHIP:PERIAPSIS / 1000, 2)
                + "km Ap=" + ROUND(SHIP:APOAPSIS / 1000, 2)
                + "km remDv=" + ROUND(remDv, 1)
                + " thr=" + ROUND(throt, 2)
                + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 3) + ".").
        }
        WAIT 0.05.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    orbitSummary().
    IF appliedDv >= dvCap {
        mLogWarn("Circularize: hit dV cap (" + ROUND(dvCap, 0)
            + "m/s) before target — check ascent profile.").
    }
    mLogWarn("STATS ascent circularize result PeKm="
        + ROUND(SHIP:PERIAPSIS / 1000, 2)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 2)
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 4)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION, 2)
        + " appliedDv=" + ROUND(appliedDv, 1)).
    RETURN NOT ABORT AND SHIP:PERIAPSIS >= PARKING_ALT * 0.9.
}

// Full airless ascent: liftoff (or resume), gravity-program climb to
// apoapsis = PARKING_ALT, then self-circularize. Returns TRUE only on
// a confirmed parking orbit. Caller (launch.ks) advances the phase.
GLOBAL FUNCTION ascentAirlessToOrbit {
    IF SHIP:BODY:ATM:EXISTS {
        mLogError("ascentAirlessToOrbit called on an atmospheric body; refusing.").
        RETURN FALSE.
    }

    LOCAL clearAlt IS 150.
    LOCAL targetVel IS _vacuumTargetOrbitalVelocity().
    LOCAL nextTelemetry IS TIME:SECONDS.
    LOCAL ascentAz IS _ascentAzimuth().
    LOCAL achInc IS MAX(ABS(LAUNCH_INCLINATION), ABS(SHIP:LATITUDE)).

    mLog("Vacuum ascent armed. Alt=" + ROUND(PARKING_ALT / 1000, 1)
        + "km targetInc=" + LAUNCH_INCLINATION
        + " lat=" + ROUND(SHIP:LATITUDE, 1)
        + " -> az=" + ROUND(ascentAz, 1)
        + " achInc=" + ROUND(achInc, 1)
        + " targetV=" + ROUND(targetVel, 1) + "m/s.").
    IF ABS(LAUNCH_INCLINATION) < ABS(SHIP:LATITUDE) - 0.5 {
        mLogWarn("Ascent: target inc " + ROUND(ABS(LAUNCH_INCLINATION), 1)
            + " below launch latitude " + ROUND(ABS(SHIP:LATITUDE), 1)
            + " — unreachable by direct ascent; flying due east for "
            + "minimum inclination (plane change needed to go lower).").
    }

    IF NOT _ascentOnSurface() {
        mLogWarn("Vacuum LAUNCH entered while already " + SHIP:STATUS
            + "; resuming ascent guidance.").
        IF stateGetNum("launch_time", 0) = 0 {
            stateSet("launch_time", TIME:SECONDS).
        }
        armAscentStaging().
    } ELSE {
        stateSet("launch_time", TIME:SECONDS).
        stateSet("launch_site_lat", SHIP:GEOPOSITION:LAT).
        stateSet("launch_site_lng", SHIP:GEOPOSITION:LNG).
        stateSet("launch_vs_nonpos_logged", "false").

        LOCK THROTTLE TO 0.
        LOCK STEERING TO SHIP:UP:VECTOR.
        mLog("Press ABORT within 5s to hold launch.").
        HUDTEXT("T-5: ABORT to hold", 5, 2, 16, YELLOW, FALSE).
        LOCAL tEnd IS TIME:SECONDS + 5.
        WAIT UNTIL TIME:SECONDS >= tEnd OR ABORT.
        IF ABORT {
            mLog("Launch hold — operator abort.").
            LOCK THROTTLE TO 0.
            UNLOCK THROTTLE.
            UNLOCK STEERING.
            RETURN FALSE.
        }
        countdown(3).

        IF ABORT OR stateGet("phase", "") = "ABORT" {
            mLogWarn("Vacuum launch countdown interrupted by abort.").
            LOCK THROTTLE TO 0.
            UNLOCK THROTTLE.
            UNLOCK STEERING.
            RETURN FALSE.
        }

        STAGE.
        mLog("Vacuum launch — STAGE fired.").
        HUDTEXT("Launch!", 3, 2, 18, YELLOW, FALSE).
        WAIT 0.5.
        ascentRunPostStageHook().
        armAscentStaging().
    }

    LOCK STEERING TO SHIP:UP:VECTOR.
    LOCK THROTTLE TO 1.0.
    mLog("Vacuum ascent clearing terrain to " + clearAlt + "m AGL.").
    UNTIL ALT:RADAR > clearAlt OR SHIP:APOAPSIS >= PARKING_ALT OR ABORT {
        IF TIME:SECONDS >= nextTelemetry {
            _logVacuumAscentTelemetry(90).
            SET nextTelemetry TO TIME:SECONDS + 5.
        }
        WAIT 0.1.
    }

    LOCAL currentPitch IS 90.
    UNTIL SHIP:APOAPSIS >= PARKING_ALT OR ABORT {
        SET currentPitch TO _vacuumAscentPitch(targetVel).
        LOCK STEERING TO HEADING(ascentAz, currentPitch).
        IF TIME:SECONDS >= nextTelemetry {
            _logVacuumAscentTelemetry(currentPitch).
            SET nextTelemetry TO TIME:SECONDS + 5.
        }
        WAIT 0.1.
    }

    LOCK THROTTLE TO 0.
    IF ABORT {
        mLogWarn("Vacuum ascent aborted; holding launch phase.").
        UNLOCK THROTTLE.
        RETURN FALSE.
    }

    mLog("Vacuum ascent cutoff: Ap="
        + ROUND(SHIP:APOAPSIS / 1000, 2) + "km, circularizing.").
    HUDTEXT("Vacuum ascent cutoff", 3, 2, 15, GREEN, FALSE).

    RETURN _ascentCircularize().
}
