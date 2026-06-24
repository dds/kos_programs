// ============================================================
// aerobrake.ks  —  Aerobrake entry phase  (0:/lib/aerobrake.ks)
//
// Two responsibilities:
//   1. Precision reentry targeting using Trajectories addon
//      (coordinate search over radial/normal to steer impact
//      point toward KSC)
//   2. Vessel prep for atmospheric entry (decouple transfer
//      stage, retract antennas after entry, orient retrograde,
//      arm chutes)
//
// Loaded as an implicit single-phase band (like MCC).
// Depends on: utils (geoDistance)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL AEROBRAKE_DECOUPLE_TAG IS "".
GLOBAL AEROBRAKE_REENTRY_DIR IS "".
GLOBAL AEROBRAKE_ARM_CHUTES IS 0.
GLOBAL AEROBRAKE_TARGETING IS 1.
// Pe-trim is opt-in (off by default) so it can't fight a body that
// sets its own aerobrake periapsis elsewhere (e.g. Duna aerocapture /
// DUNA_ENTRY_LOWER_PE). When on, it deepens to AEROBRAKE_PE, or
// REENTRY_PE if AEROBRAKE_PE is unset.
GLOBAL AEROBRAKE_PE_TARGETING IS 0.
GLOBAL AEROBRAKE_PE IS -1.
// Multi-pass aerobrake: hold heat-shield-forward through each pass and
// stay in this phase until captured AND slowed below this airspeed (m/s)
// — i.e. through the fast/thick part — before handing to DESCENT. We never
// reboot into DESCENT at orbital speed where a brief loss of control on a
// not-yet-stable craft could tumble it.
GLOBAL AEROBRAKE_HANDOFF_SPEED IS 600.
// The capture braking burn stops once periapsis is this deep (m over
// surface); -1 => auto (0.4 * atmosphere height). Keeps it from driving
// Pe negative if it ever runs to fuel exhaustion.
GLOBAL AEROBRAKE_BRAKE_PE_FLOOR IS -1.
// Hold the solar attitude through the long coast and only wake to get
// ready for entry this many seconds before the atmosphere (default 15 min).
GLOBAL AEROBRAKE_ENTRY_LEAD IS 900.

LOCAL KSC_LAT IS -0.10.
LOCAL KSC_LNG IS -74.25.
LOCAL CORRECTION_TOLERANCE IS 50000.   // 50km default
LOCAL MAX_CORRECTION_DV IS 20.         // cap total correction burn
LOCAL PE_CORRECTION_TOLERANCE IS 1000. // 1km final reentry Pe cleanup
LOCAL MAX_PE_CORRECTION_FRACTION IS 0.05.
LOCAL MAX_TARGETING_SCANS IS 5.
LOCAL TARGETING_ATMO_SKIP_MULT IS 1.1.

// Atmosphere heights by body (meters). Stock + OPM.
LOCAL ATM_HEIGHTS IS LEXICON(
    "KERBIN", 70000,
    "DUNA",   50000,
    "EVE",    90000,
    "JOOL",   200000,
    "LAYTHE", 50000,
    "SARNUS", 580000,
    "URLUM",  325000,
    "NEIDON", 260000,
    "TEKTO",  95000
).

GLOBAL FUNCTION phaseAerobrake {
    mLogPhase("AEROBRAKE").

    // If entered while still coasting through an AIRLESS SOI (a Mun
    // flyby's outbound leg hands off mid-escape), wait until we're at
    // the body we'll actually aerobrake. Otherwise the Pe-trim and
    // targeting run against the wrong orbit — flight-found: it tried to
    // deepen the *Mun* Pe (2146km) to 25km and capped out.
    IF NOT SHIP:BODY:ATM:EXISTS {
        mLog("Aerobrake: in airless " + SHIP:BODY:NAME
            + " SOI — coasting until at an atmosphere body...").
        WAIT UNTIL SHIP:BODY:ATM:EXISTS
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
        mLog("Aerobrake: now at " + SHIP:BODY:NAME + ".").
    }

    LOCAL atmHeight IS _aerobrakeAtmoHeight().

    // --- Long-term setup: alarm the atmosphere entry, then orient for
    // solar and hold (charging, panels still out) until 15 min before it. ---
    LOCAL entryUt IS _aerobrakeSetEntryAlarm().
    IF entryUt > 0 {
        _aerobrakeSolarWait(entryUt - AEROBRAKE_ENTRY_LEAD).
    }

    // --- Wake up and get ready (~15 min before entry) ---
    // Aim the periapsis at the aerobrake corridor (shallow enough that the
    // craft stays controllable at orbital speed).
    IF AEROBRAKE_PE_TARGETING > 0 {
        _aerobrakeTrimReentryPe().
    }
    // One opportunistic impact nudge if Trajectories already resolves one;
    // a missing impact is NOT a reason to bail to DESCENT — the multi-pass
    // loop below carries on regardless.
    IF AEROBRAKE_TARGETING <= 0 {
        mLog("Aerobrake impact-site targeting disabled by config.").
    } ELSE IF ADDONS:TR:AVAILABLE {
        _aerobrakeReentryTargeting().
    } ELSE {
        mLog("Trajectories not available — skipping impact-site targeting.").
    }
    _aerobrakeDecouple().
    // Deployable antennas/panels break in the airstream and open bays add
    // unwanted torque; stow everything now. (Fixed panels, e.g. FTSV1's,
    // ride through fine.) DESCENT re-extends them once it's slow enough.
    _aerobrakeRetractSolarPanels().
    _aerobrakeRetractAntennas().
    _aerobrakeCloseExtendBays().

    mLog("Aerobrake: multi-pass braking. Holding heat-shield-forward "
        + "through each pass; staying until captured and slowed below "
        + AEROBRAKE_HANDOFF_SPEED + " m/s before DESCENT.").

    // If we somehow begin already inside the atmosphere, get oriented now.
    IF SHIP:ALTITUDE < atmHeight { _aerobrakeOrient(). }

    // --- Multi-pass aerobrake loop ---
    LOCAL passNum IS 0.
    LOCAL inPass IS FALSE.
    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        IF _aerobrakeThroughThickPart(atmHeight) {
            mLog("Aerobrake: captured (Ap "
                + ROUND(SHIP:APOAPSIS / 1000, 1) + "km) and slowed to "
                + ROUND(SHIP:AIRSPEED, 0)
                + " m/s — through the thick part. Handing to DESCENT.").
            BREAK.
        }
        IF SHIP:ALTITUDE > atmHeight {
            IF inPass {
                SET inPass TO FALSE.
                mLog("STATS aerobrake pass=" + passNum + " out"
                    + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
                    + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
                    + " vel=" + ROUND(SHIP:VELOCITY:ORBIT:MAG, 0)).
                // A pass that left us still hyperbolic would sail back out
                // and escape — spend fuel to secure capture (the braking
                // burn lives only in AEROBRAKE now). Stops as soon as the
                // orbit is bound; aerobraking finishes the rest.
                IF SHIP:ORBIT:ECCENTRICITY >= 1 {
                    mLog("Aerobrake: pass " + passNum + " left ecc "
                        + ROUND(SHIP:ORBIT:ECCENTRICITY, 3)
                        + " (hyperbolic) — braking burn to secure capture.").
                    _aerobrakeBrakingBurn().
                }
            }
            // Between passes: solar-hold + warp the high coast, then orient
            // heat-shield-forward ~15 min before the next pass.
            _aerobrakeSolarWait(TIME:SECONDS + ETA:PERIAPSIS - AEROBRAKE_ENTRY_LEAD).
            _aerobrakeOrient().
            WAIT UNTIL SHIP:ALTITUDE < atmHeight
                OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
        } ELSE {
            IF NOT inPass {
                SET inPass TO TRUE.
                SET passNum TO passNum + 1.
                mLog("STATS aerobrake pass=" + passNum + " in"
                    + " entryKm=" + ROUND(SHIP:ALTITUDE / 1000, 1)
                    + " vel=" + ROUND(SHIP:VELOCITY:ORBIT:MAG, 0)).
            }
            // In a pass: heat-shield-forward, let drag bleed the energy.
            UNTIL SHIP:ALTITUDE > atmHeight
                OR _aerobrakeThroughThickPart(atmHeight)
                OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
                _aerobrakeOrient().
                WAIT 1.
            }
        }
    }

    mLog("STATS aerobrake status=complete passes=" + passNum
        + " body=" + SHIP:BODY:NAME).
    _aerobrakeAdvance().
}

// Through the dangerous fast/thick regime: captured into a sub-atmosphere
// orbit (won't climb back out) AND slowed below the safe handoff speed.
// A negative/huge apoapsis (still hyperbolic, or a high ellipse needing
// more passes) reads as NOT yet captured.
LOCAL FUNCTION _aerobrakeThroughThickPart {
    PARAMETER atmHeight.
    IF SHIP:ALTITUDE > atmHeight { RETURN FALSE. }
    LOCAL ap IS SHIP:ORBIT:APOAPSIS.
    LOCAL captured IS ap > 0 AND ap < atmHeight.
    RETURN captured AND SHIP:AIRSPEED < AEROBRAKE_HANDOFF_SPEED.
}

// Retract deployable antennas before the airstream snaps them off.
LOCAL FUNCTION _aerobrakeRetractAntennas {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL m IS p:GETMODULE("ModuleDeployableAntenna").
            IF m:HASEVENT("retract antenna") {
                m:DOEVENT("retract antenna").
                SET retracted TO retracted + 1.
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " antenna(s) before aerobraking.").
        WAIT 3.
    }
}

// Retract deployable solar panels before the airstream snaps them off.
LOCAL FUNCTION _aerobrakeRetractSolarPanels {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL m IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF m:HASEVENT("Retract Solar Panel") {
                m:DOEVENT("Retract Solar Panel").
                SET retracted TO retracted + 1.
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " solar panel(s) before aerobraking.").
        WAIT 3.
    }
}

// Close tagged ('extend_bay') service bays before entry.
LOCAL FUNCTION _aerobrakeCloseExtendBays {
    LOCAL closed IS 0.
    FOR p IN SHIP:PARTSTAGGED("extend_bay") {
        IF p:HASMODULE("ModuleAnimateGeneric") {
            LOCAL bm IS p:GETMODULE("ModuleAnimateGeneric").
            IF bm:HASEVENT("Close") { bm:DOEVENT("Close"). SET closed TO closed + 1. }
            ELSE IF bm:HASEVENT("Close Doors") { bm:DOEVENT("Close Doors"). SET closed TO closed + 1. }
            ELSE IF bm:HASEVENT("Retract") { bm:DOEVENT("Retract"). SET closed TO closed + 1. }
        }
    }
    IF closed > 0 {
        mLog("Closed " + closed + " extend bay(s) before aerobraking.").
        WAIT 1.
    }
}

// Capture braking burn (AEROBRAKE-only): burn retrograde just long enough
// to drop from a hyperbolic pass into a bound orbit, then let aerobraking
// finish. Stops on capture (ecc<1), fuel exhaustion, the Pe floor, or
// landing — so it can't run away and drive Pe negative.
LOCAL FUNCTION _aerobrakeBrakingBurn {
    IF SHIP:AVAILABLETHRUST <= 0 { RETURN. }
    IF (STAGE:LIQUIDFUEL + STAGE:OXIDIZER) <= 0.1 {
        mLog("Aerobrake braking burn: no fuel remaining.").
        RETURN.
    }
    LOCAL atmHeight IS _aerobrakeAtmoHeight().
    LOCAL peFloor IS atmHeight * 0.4.
    IF AEROBRAKE_BRAKE_PE_FLOOR >= 0 { SET peFloor TO AEROBRAKE_BRAKE_PE_FLOOR. }

    mLog("Aerobrake braking burn: ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 3)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " peFloorKm=" + ROUND(peFloor / 1000, 1)).
    LOCK THROTTLE TO 1.
    LOCK STEERING TO RETROGRADE.
    LOCAL reason IS "".
    UNTIL reason <> "" {
        IF (STAGE:LIQUIDFUEL + STAGE:OXIDIZER) <= 0.1
                OR SHIP:AVAILABLETHRUST <= 0 {
            SET reason TO "fuel-exhausted".
        } ELSE IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            SET reason TO "landed".
        } ELSE IF SHIP:ORBIT:ECCENTRICITY < 1 {
            SET reason TO "captured".
        } ELSE IF atmHeight > 0 AND SHIP:ORBIT:PERIAPSIS < peFloor {
            SET reason TO "pe-below-reentry-floor".
        }
        WAIT 0.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    mLog("Aerobrake braking burn complete: " + reason
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 3)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)).
}

// Set a KAC alarm before atmospheric interface so time warp
// stops automatically. Uses the ATM_HEIGHTS table; falls back
// to the body's own ATM:HEIGHT if not in the table.
// Set the atmosphere-entry KAC alarm and RETURN the entry UT (periapsis
// ETA, nudged earlier when Pe is already inside the atmosphere). -1 on an
// airless body. Reliable — pure orbit ETA, no POSITIONAT prediction.
LOCAL FUNCTION _aerobrakeSetEntryAlarm {
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN -1. }

    LOCAL atmAlt IS SHIP:BODY:ATM:HEIGHT.
    IF ATM_HEIGHTS:HASKEY(SHIP:BODY:NAME) {
        SET atmAlt TO ATM_HEIGHTS[SHIP:BODY:NAME].
    }

    // Atmosphere entry happens shortly before periapsis on a reentry arc.
    LOCAL entryUt IS TIME:SECONDS + ETA:PERIAPSIS.
    IF SHIP:ORBIT:PERIAPSIS < atmAlt {
        SET entryUt TO entryUt - 120.
    }
    SET entryUt TO MAX(entryUt, TIME:SECONDS + 30).

    IF ADDONS:KAC:AVAILABLE {
        LOCAL alarmId IS kacEnsureAlarm("Atmo entry: " + SHIP:BODY:NAME,
            entryUt,
            "Atmosphere at " + ROUND(atmAlt/1000, 0) + "km").
        IF alarmId <> "" {
            mLog("KAC alarm set for atmosphere entry in "
                + ROUND(entryUt - TIME:SECONDS, 0) + "s"
                + " (" + SHIP:BODY:NAME + " atmo=" + ROUND(atmAlt/1000, 0) + "km).").
        }
    }
    RETURN entryUt.
}

// Orient for solar and hold (auto-warping) until `wakeUt`, then return so
// the caller can get ready for entry. No-op if already in the atmosphere
// or wakeUt is already here.
LOCAL FUNCTION _aerobrakeSolarWait {
    PARAMETER wakeUt.
    LOCAL atmHeight IS _aerobrakeAtmoHeight().
    IF atmHeight > 0 AND SHIP:ALTITUDE < atmHeight { RETURN. }
    IF wakeUt <= TIME:SECONDS + 30 { RETURN. }

    mLog("Aerobrake: orienting for solar — holding until "
        + ROUND(AEROBRAKE_ENTRY_LEAD / 60, 0)
        + " min before atmosphere entry (wake in T+"
        + ROUND(wakeUt - TIME:SECONDS, 0) + "s) to get ready.").
    UNLOCK STEERING.
    LOCAL solarRef IS trySolarHoldTick(-1).
    coastAutoWarp(wakeUt, "Aerobrake coast", "").
    UNTIL TIME:SECONDS >= wakeUt
            OR (atmHeight > 0 AND SHIP:ALTITUDE < atmHeight)
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        SET solarRef TO trySolarHoldTick(solarRef).
        WAIT MIN(10, MAX(1, wakeUt - TIME:SECONDS)).
    }
    IF WARP > 0 {
        SET WARP TO 0.
        WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
        WAIT 1.
    }
    mLog("Aerobrake: waking up to get ready for entry.").
}

LOCAL FUNCTION _aerobrakeAtmoHeight {
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN -1. }

    LOCAL atmAlt IS SHIP:BODY:ATM:HEIGHT.
    IF ATM_HEIGHTS:HASKEY(SHIP:BODY:NAME) {
        SET atmAlt TO ATM_HEIGHTS[SHIP:BODY:NAME].
    }
    RETURN atmAlt.
}

LOCAL FUNCTION _aerobrakeTargetingWindowOk {
    PARAMETER label.

    LOCAL atmAlt IS _aerobrakeAtmoHeight().
    IF atmAlt < 0 { RETURN TRUE. }

    LOCAL skipAlt IS atmAlt * TARGETING_ATMO_SKIP_MULT.
    IF SHIP:ALTITUDE <= skipAlt {
        mLog(label + " skipped: already within 10% of atmosphere altitude "
            + "(alt=" + ROUND(SHIP:ALTITUDE/1000, 1)
            + "km atmo=" + ROUND(atmAlt/1000, 1) + "km).").
        RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _aerobrakeAdvance {
    LOCAL current IS stateGet("phase", "AEROBRAKE").
    IF xferSeq:CONTAINS(current) {
        RETURN nextPhase(xferSeq).
    }

    LOCAL fallback IS "DESCENT".
    LOCAL requiredBand IS bootLibBandForPhase(fallback, fallback).
    mLogWarn("AEROBRAKE phase is not in the active sequence; "
        + "falling through to " + fallback + ".").
    archivePhaseLog().
    stateSet("phase", fallback).
    stateSaveReloadState("AEROBRAKE_FALLBACK", fallback, requiredBand).
    mLogWarn("Aerobrake complete; rebooting into band " + requiredBand + ".").
    WAIT 2.
    REBOOT.
    RETURN fallback.
}

// ============================================================
// Reentry targeting — small Pe cleanup plus Trajectories impact burn
//
// Pe cleanup uses a tiny prograde-only node. Impact-site targeting
// creates a small correction node and uses coordinate search over
// TIME, RADIAL, NORMAL to minimize distance to KSC.
// ============================================================
LOCAL FUNCTION _aerobrakeTrimReentryPe {
    IF NOT _aerobrakeTargetingWindowOk("Aerobrake Pe trim") { RETURN. }

    LOCAL targetPe IS REENTRY_PE.
    IF AEROBRAKE_PE >= 0 { SET targetPe TO AEROBRAKE_PE. }
    IF targetPe < 0 {
        mLog("Aerobrake Pe trim disabled: target Pe < 0.").
        RETURN.
    }

    LOCAL currentPe IS SHIP:PERIAPSIS.
    LOCAL peErr IS currentPe - targetPe.
    IF ABS(peErr) <= PE_CORRECTION_TOLERANCE {
        mLog("Reentry Pe already within tolerance: Pe="
            + ROUND(currentPe/1000, 1) + "km target="
            + ROUND(targetPe/1000, 1) + "km.").
        RETURN.
    }

    LOCAL maxPeChange IS SHIP:BODY:RADIUS * MAX_PE_CORRECTION_FRACTION.
    IF ABS(peErr) > maxPeChange {
        mLogWarn("Aerobrake Pe trim skipped: requested Pe change "
            + ROUND(ABS(peErr)/1000, 1) + "km exceeds "
            + ROUND(maxPeChange/1000, 1) + "km cap ("
            + ROUND(MAX_PE_CORRECTION_FRACTION * 100, 1)
            + "% body radius).").
        mLog("STATS aerobrake pe-trim status=skipped reason=pe-change-cap"
            + " startPeKm=" + ROUND(currentPe/1000, 1)
            + " targetPeKm=" + ROUND(targetPe/1000, 1)
            + " maxChangeKm=" + ROUND(maxPeChange/1000, 1)).
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + 60, 0, 0, 0).
    ADD nd.
    WAIT 0.2.

    LOCAL bestPro IS 0.
    LOCAL bestPe IS nd:ORBIT:PERIAPSIS.
    LOCAL bestErr IS ABS(bestPe - targetPe).
    LOCAL startPe IS bestPe.
    LOCAL startErr IS bestErr.
    LOCAL proStep IS 2.
    LOCAL signs IS LIST(1, -1).

    mLog("Reentry Pe trim: current=" + ROUND(currentPe/1000, 1)
        + "km target=" + ROUND(targetPe/1000, 1)
        + "km.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= MAX_TARGETING_SCANS STEP { SET iter TO iter + 1. } DO {
        LOCAL improved IS FALSE.
        LOCAL trialBestPro IS bestPro.
        LOCAL trialBestPe IS bestPe.
        LOCAL trialBestErr IS bestErr.

        FOR sign IN signs {
            LOCAL tryPro IS bestPro + sign * proStep.
            IF ABS(tryPro) <= MAX_CORRECTION_DV {
                SET nd:PROGRADE TO tryPro.
                WAIT 0.1.
                LOCAL tryPe IS nd:ORBIT:PERIAPSIS.
                LOCAL tryErr IS ABS(tryPe - targetPe).
                IF tryErr < trialBestErr {
                    SET trialBestPro TO tryPro.
                    SET trialBestPe TO tryPe.
                    SET trialBestErr TO tryErr.
                }
            }
        }

        IF trialBestErr < bestErr {
            SET bestPro TO trialBestPro.
            SET bestPe TO trialBestPe.
            SET bestErr TO trialBestErr.
            SET improved TO TRUE.
            mLog("  pe-trim[" + iter + "] Pe=" + ROUND(bestPe/1000, 2)
                + "km err=" + ROUND(bestErr/1000, 2)
                + "km P=" + ROUND(bestPro, 2)).
        }

        IF bestErr <= PE_CORRECTION_TOLERANCE { BREAK. }

        IF NOT improved {
            SET proStep TO proStep / 2.
            IF proStep < 0.02 { BREAK. }
        }
    }

    SET nd:PROGRADE TO bestPro.
    WAIT 0.2.

    LOCAL totalDv IS nd:DELTAV:MAG.
    IF bestErr >= startErr OR totalDv < 0.2 {
        mLog("Reentry Pe trim not useful — skipping burn.").
        mLog("STATS aerobrake pe-trim status=skipped reason=no-useful-node"
            + " startPeKm=" + ROUND(startPe/1000, 1)
            + " targetPeKm=" + ROUND(targetPe/1000, 1)
            + " predictPeKm=" + ROUND(bestPe/1000, 1)
            + " dv=" + ROUND(totalDv, 2)).
        REMOVE nd.
        RETURN.
    }

    mLog("Reentry Pe trim: predicted Pe=" + ROUND(bestPe/1000, 1)
        + "km dV=" + ROUND(totalDv, 2) + " m/s.").
    mLog("STATS aerobrake pe-trim status=planned"
        + " startPeKm=" + ROUND(currentPe/1000, 1)
        + " targetPeKm=" + ROUND(targetPe/1000, 1)
        + " predictPeKm=" + ROUND(bestPe/1000, 1)
        + " errKm=" + ROUND(bestErr/1000, 2)
        + " dv=" + ROUND(totalDv, 2)
        + " prograde=" + ROUND(bestPro, 2)).

    LOCAL success IS executeManeuver().
    IF NOT success {
        mLogWarn("Reentry Pe trim burn failed.").
        IF HASNODE { REMOVE NEXTNODE. }
        RETURN.
    }

    WAIT 1.
    mLog("Post-trim Pe=" + ROUND(SHIP:PERIAPSIS/1000, 1)
        + "km target=" + ROUND(targetPe/1000, 1) + "km.").
    mLog("STATS aerobrake pe-trim status=complete"
        + " finalPeKm=" + ROUND(SHIP:PERIAPSIS/1000, 1)
        + " targetPeKm=" + ROUND(targetPe/1000, 1)
        + " dv=" + ROUND(totalDv, 2)).
}

LOCAL FUNCTION _aerobrakeReentryTargeting {
    IF NOT _aerobrakeTargetingWindowOk("Aerobrake reentry targeting") { RETURN. }

    // Resolve the landing target (waypoint / locked / config). On
    // Kerbin with nothing set, default to KSC (preserves return-to-
    // Kerbin behavior); on any other body refuse to target without an
    // explicit site rather than blindly aiming at KSC's coordinates
    // on, e.g., Duna.
    LOCAL tgt IS landingResolveTarget().
    LOCAL tgtLat IS KSC_LAT.
    LOCAL tgtLng IS KSC_LNG.
    IF tgt["FOUND"] {
        SET tgtLat TO tgt["LAT"].
        SET tgtLng TO tgt["LNG"].
        mLog("Aerobrake target: " + tgt["SOURCE"] + " "
            + ROUND(tgtLat, 3) + "," + ROUND(tgtLng, 3) + ".").
    } ELSE IF SHIP:BODY:NAME = "Kerbin" {
        mLog("Aerobrake target: KSC default.").
    } ELSE {
        mLogWarn("Aerobrake: no landing target on " + SHIP:BODY:NAME
            + " — skipping reentry targeting (untargeted entry).").
        RETURN.
    }
    LOCAL targetGeo IS LATLNG(tgtLat, tgtLng).
    ADDONS:TR:SETTARGET(targetGeo).
    WAIT 0.5.

    IF NOT ADDONS:TR:HASIMPACT {
        // Don't warp/wait for a TR impact. Far out on a fast return TR
        // can't resolve one, and we're committed to entering the
        // atmosphere regardless — sitting here warping the approach down
        // just delays orienting for reentry. Skip the KSC impact-site
        // correction; the phase orients and hands off to DESCENT. The
        // correction only runs when TR already has an impact in hand.
        mLogWarn("Aerobrake: Trajectories has no impact prediction — "
            + "skipping KSC impact-site correction (committed to entry).").
        RETURN.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS geoDistance(impactPos:LAT, impactPos:LNG, tgtLat, tgtLng).
    mLog("Reentry: current impact " + ROUND(impactPos:LAT, 2) + "," + ROUND(impactPos:LNG, 2)
        + "  dist=" + ROUND(dist/1000, 1) + "km from target.").
    mLog("STATS aerobrake pre-correction distKm=" + ROUND(dist/1000, 1)
        + " impact=" + ROUND(impactPos:LAT, 4) + "," + ROUND(impactPos:LNG, 4)).

    IF dist < CORRECTION_TOLERANCE {
        mLog("Impact already within tolerance — no correction needed.").
        RETURN.
    }

    // Correction node well ahead of now: the coordinate search below
    // takes ~70s, and a 60s node had its window pass before executing
    // (flight-found "burn window already passed by 15s").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + 240, 0, 0, 0).
    ADD nd.
    WAIT 0.3.

    // Coordinate search over TIME, RADIAL, NORMAL
    LOCAL bestDist IS dist.
    LOCAL bestTime IS nd:TIME.
    LOCAL bestRad IS 0.
    LOCAL bestNor IS 0.
    LOCAL bestPro IS 0.

    LOCAL timeStep IS 30.
    LOCAL radialStep IS 2.
    LOCAL normalStep IS 2.
    LOCAL progradeStep IS 1.

    LOCAL axes IS LIST("TIME", "RADIAL", "NORMAL", "PROGRADE").
    LOCAL signs IS LIST(1, -1).

    mLog("Reentry correction: coordinate search from dist=" + ROUND(bestDist/1000, 1) + "km.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= MAX_TARGETING_SCANS STEP { SET iter TO iter + 1. } DO {
        LOCAL improved IS FALSE.
        LOCAL trialBestDist IS bestDist.
        LOCAL trialBestTime IS bestTime.
        LOCAL trialBestRad IS bestRad.
        LOCAL trialBestNor IS bestNor.
        LOCAL trialBestPro IS bestPro.

        FOR axis IN axes {
            FOR sign IN signs {
                LOCAL tryTime IS bestTime.
                LOCAL tryRad IS bestRad.
                LOCAL tryNor IS bestNor.
                LOCAL tryPro IS bestPro.

                IF axis = "TIME" { SET tryTime TO tryTime + sign * timeStep. }
                IF axis = "RADIAL" { SET tryRad TO tryRad + sign * radialStep. }
                IF axis = "NORMAL" { SET tryNor TO tryNor + sign * normalStep. }
                IF axis = "PROGRADE" { SET tryPro TO tryPro + sign * progradeStep. }

                // dV cap check
                IF SQRT(tryRad^2 + tryNor^2 + tryPro^2) > MAX_CORRECTION_DV {
                    // skip — would exceed correction budget
                } ELSE IF tryTime <= TIME:SECONDS + 30 {
                    // skip — too soon
                } ELSE {
                    SET nd:TIME TO tryTime.
                    SET nd:RADIALOUT TO tryRad.
                    SET nd:NORMAL TO tryNor.
                    SET nd:PROGRADE TO tryPro.
                    WAIT 0.2.

                    IF ADDONS:TR:HASIMPACT {
                        LOCAL tryImpact IS ADDONS:TR:IMPACTPOS.
                        LOCAL tryDist IS geoDistance(tryImpact:LAT, tryImpact:LNG, tgtLat, tgtLng).
                        IF tryDist < trialBestDist {
                            SET trialBestDist TO tryDist.
                            SET trialBestTime TO tryTime.
                            SET trialBestRad TO tryRad.
                            SET trialBestNor TO tryNor.
                            SET trialBestPro TO tryPro.
                        }
                    }
                }
            }
        }

        IF trialBestDist < bestDist {
            SET bestDist TO trialBestDist.
            SET bestTime TO trialBestTime.
            SET bestRad TO trialBestRad.
            SET bestNor TO trialBestNor.
            SET bestPro TO trialBestPro.
            SET improved TO TRUE.
            mLog("  reentry[" + iter + "] dist=" + ROUND(bestDist/1000, 1) + "km"
                + " R=" + ROUND(bestRad, 2) + " N=" + ROUND(bestNor, 2)
                + " P=" + ROUND(bestPro, 2)).
        }

        IF bestDist < CORRECTION_TOLERANCE { BREAK. }

        IF NOT improved {
            SET timeStep TO timeStep / 2.
            SET radialStep TO radialStep / 2.
            SET normalStep TO normalStep / 2.
            SET progradeStep TO progradeStep / 2.
            IF timeStep < 0.5 AND radialStep < 0.05
                    AND normalStep < 0.05 AND progradeStep < 0.02 { BREAK. }
        }
    }

    // Apply best solution
    SET nd:TIME TO bestTime.
    SET nd:RADIALOUT TO bestRad.
    SET nd:NORMAL TO bestNor.
    SET nd:PROGRADE TO bestPro.
    WAIT 0.2.

    LOCAL totalDv IS nd:DELTAV:MAG.
    mLog("Reentry correction: dist=" + ROUND(bestDist/1000, 1) + "km"
        + "  dV=" + ROUND(totalDv, 1) + " m/s").
    mLog("STATS aerobrake correction distKm=" + ROUND(bestDist/1000, 1)
        + " dv=" + ROUND(totalDv, 1)
        + " radial=" + ROUND(bestRad, 2)
        + " normal=" + ROUND(bestNor, 2)
        + " prograde=" + ROUND(bestPro, 2)).

    IF totalDv < 0.5 {
        mLog("Correction too small — skipping burn.").
        REMOVE nd.
        RETURN.
    }

    // Execute the correction burn
    LOCAL success IS executeManeuver().
    IF NOT success {
        mLogWarn("Reentry correction burn failed.").
        IF HASNODE { REMOVE NEXTNODE. }
    }

    // Post-burn verification
    WAIT 1.
    IF ADDONS:TR:HASIMPACT {
        LOCAL finalImpact IS ADDONS:TR:IMPACTPOS.
        LOCAL finalDist IS geoDistance(finalImpact:LAT, finalImpact:LNG, tgtLat, tgtLng).
        mLog("Post-correction impact: " + ROUND(finalImpact:LAT, 2) + "," + ROUND(finalImpact:LNG, 2)
            + "  dist=" + ROUND(finalDist/1000, 1) + "km from target.").
        mLog("STATS aerobrake postburn distKm=" + ROUND(finalDist/1000, 1)
            + " impact=" + ROUND(finalImpact:LAT, 4) + "," + ROUND(finalImpact:LNG, 4)).
    }
}

// ============================================================
// Vessel prep helpers
// ============================================================

LOCAL FUNCTION _aerobrakeDecouple {
    IF AEROBRAKE_DECOUPLE_TAG = "" { RETURN. }
    LOCAL tag IS AEROBRAKE_DECOUPLE_TAG.
    LOCAL decouplers IS SHIP:PARTSTAGGED(tag).
    IF decouplers:LENGTH = 0 {
        mLogWarn("Decouple tag '" + tag + "' not found — skipping decouple.").
        RETURN.
    }
    FOR dc IN decouplers {
        IF dc:HASMODULE("ModuleDecouple") {
            dc:GETMODULE("ModuleDecouple"):DOEVENT("decouple").
            mLog("Decoupled: " + dc:TITLE + " (tag=" + tag + ")").
        } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
            dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("decouple").
            mLog("Decoupled: " + dc:TITLE + " (tag=" + tag + ")").
        }
    }
    WAIT 2.
}

LOCAL FUNCTION _aerobrakeOrient {
    SET dir TO AEROBRAKE_REENTRY_DIR.

    LOCAL steerDir IS SHIP:SRFRETROGRADE.
    LOCAL refVec IS -SHIP:VELOCITY:ORBIT.
    IF dir = "PROGRADE" {
        SET steerDir TO SHIP:SRFPROGRADE.
        SET refVec TO SHIP:VELOCITY:ORBIT.
    }

    mLog("Orienting " + dir + " for entry.").
    SAS OFF.
    LOCK STEERING TO steerDir.
    LOCAL startTime IS TIME:SECONDS.
    LOCAL timeout IS 60.
    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, refVec) < 2
        OR TIME:SECONDS > startTime + timeout.
    IF VANG(SHIP:FACING:FOREVECTOR, refVec) < 2 {
        mLog("Oriented " + dir + " (error < 2°).").
    } ELSE {
        mLogWarn(dir + " alignment timed out.").
    }

    // LOCK STEERING stays active — phaseAerobrake will wait for
    // atmosphere entry and hand off to SAS before advancing.
    mLog(dir + " steering lock active.").
}

LOCAL FUNCTION _aerobrakeArmChutes {
    IF AEROBRAKE_ARM_CHUTES <= 0 { RETURN. }

    LOCAL armed IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleParachute") {
            LOCAL m IS p:GETMODULE("ModuleParachute").
            IF m:HASEVENT("arm parachute") {
                m:DOEVENT("arm parachute").
                SET armed TO armed + 1.
            }
        }
    }
    IF armed > 0 {
        mLog("Armed " + armed + " parachute(s).").
    }
}
