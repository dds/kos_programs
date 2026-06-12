// ============================================================
// aerobrake.ks  —  Aerobrake entry phase  (0:/lib/aerobrake.ks)
//
// Two responsibilities:
//   1. Precision reentry targeting using Trajectories addon
//      (coordinate search over radial/normal to steer impact
//      point toward KSC)
//   2. Vessel prep for atmospheric entry (retract antennas,
//      decouple transfer stage, orient retrograde, arm chutes)
//
// Loaded as an implicit single-phase band (like MCC).
// Depends on: utils (geoDistance)
// ============================================================

LOCAL KSC_LAT IS -0.10.
LOCAL KSC_LNG IS -74.25.
LOCAL CORRECTION_TOLERANCE IS 50000.   // 50km default
LOCAL MAX_CORRECTION_DV IS 20.         // cap total correction burn

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

    // --- Step 1: Reentry targeting ---
    IF CFG:HASKEY("ESCAPE_KSC_TARGET") AND ADDONS:TR:AVAILABLE {
        _aerobrakeReentryTargeting().
    } ELSE {
        IF NOT ADDONS:TR:AVAILABLE {
            mLog("Trajectories not available — skipping reentry targeting.").
        }
    }

    // --- Step 2: Vessel prep (pre-coast) ---
    _aerobrakeRetractAntennas().
    _aerobrakeDecouple().
    // Chutes are armed in descent phase after atmosphere entry.

    // --- Step 3: KAC alarm for atmosphere entry ---
    _aerobrakeSetEntryAlarm().

    mLog("Aerobrake prep complete.").
    mLogWarn("STATS aerobrake status=complete body=" + SHIP:BODY:NAME).

    // --- Step 4: Wait for atmosphere, then orient ---
    IF SHIP:BODY:ATM:EXISTS {
        LOCAL atmHeight IS SHIP:BODY:ATM:HEIGHT.
        IF ATM_HEIGHTS:HASKEY(SHIP:BODY:NAME) {
            SET atmHeight TO ATM_HEIGHTS[SHIP:BODY:NAME].
        }
        IF SHIP:ALTITUDE > atmHeight {
            mLog("Waiting for atmosphere (" + ROUND(atmHeight/1000, 0) + "km)...").
            WAIT UNTIL SHIP:ALTITUDE < atmHeight.
            mLog("Atmosphere entry at " + ROUND(SHIP:ALTITUDE/1000, 1) + "km.").
        }
    }
    _aerobrakeOrient().

    nextPhase(xferSeq).
}

// Set a KAC alarm before atmospheric interface so time warp
// stops automatically. Uses the ATM_HEIGHTS table; falls back
// to the body's own ATM:HEIGHT if not in the table.
LOCAL FUNCTION _aerobrakeSetEntryAlarm {
    IF NOT ADDONS:KAC:AVAILABLE { RETURN. }
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN. }

    LOCAL atmAlt IS SHIP:BODY:ATM:HEIGHT.
    IF ATM_HEIGHTS:HASKEY(SHIP:BODY:NAME) {
        SET atmAlt TO ATM_HEIGHTS[SHIP:BODY:NAME].
    }

    // Estimate time to atmosphere from current orbit
    // Use periapsis ETA as a rough guide — atmosphere entry
    // happens shortly before periapsis on a suborbital/aerobrake trajectory
    LOCAL entryUt IS TIME:SECONDS + ETA:PERIAPSIS.
    IF SHIP:ORBIT:PERIAPSIS < atmAlt {
        // We'll hit atmosphere before periapsis. Estimate using
        // current descent rate or just put the alarm 2 minutes before PE.
        SET entryUt TO entryUt - 120.
    }
    SET entryUt TO MAX(entryUt, TIME:SECONDS + 30).

    LOCAL alm IS ADDALARM("Raw", entryUt, "Atmo entry: " + SHIP:BODY:NAME,
        "Atmosphere at " + ROUND(atmAlt/1000, 0) + "km").
    IF alm <> 0 {
        SET alm:ACTION TO warpKillAction().
        mLog("KAC alarm set for atmosphere entry in "
            + ROUND(entryUt - TIME:SECONDS, 0) + "s"
            + " (" + SHIP:BODY:NAME + " atmo=" + ROUND(atmAlt/1000, 0) + "km).").
    }
}

// ============================================================
// Reentry targeting — Trajectories-based correction burn
//
// Creates a small correction node and uses coordinate search
// over TIME, RADIAL, NORMAL to minimize distance to KSC.
// ============================================================
LOCAL FUNCTION _aerobrakeReentryTargeting {
    LOCAL targetGeo IS LATLNG(KSC_LAT, KSC_LNG).
    ADDONS:TR:SETTARGET(targetGeo).
    WAIT 0.5.

    IF NOT ADDONS:TR:HASIMPACT {
        mLogWarn("Trajectories has no impact prediction — skipping reentry correction.").
        RETURN.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS geoDistance(impactPos:LAT, impactPos:LNG, KSC_LAT, KSC_LNG).
    mLog("Reentry: current impact " + ROUND(impactPos:LAT, 2) + "," + ROUND(impactPos:LNG, 2)
        + "  dist=" + ROUND(dist/1000, 1) + "km from KSC.").
    mLogWarn("STATS aerobrake pre-correction distKm=" + ROUND(dist/1000, 1)
        + " impact=" + ROUND(impactPos:LAT, 4) + "," + ROUND(impactPos:LNG, 4)).

    IF dist < CORRECTION_TOLERANCE {
        mLog("Impact already within tolerance — no correction needed.").
        RETURN.
    }

    // Create correction node 60s from now
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + 60, 0, 0, 0).
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

    FROM { LOCAL iter IS 0. } UNTIL iter >= 50 STEP { SET iter TO iter + 1. } DO {
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
                        LOCAL tryDist IS geoDistance(tryImpact:LAT, tryImpact:LNG, KSC_LAT, KSC_LNG).
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
    mLogWarn("STATS aerobrake correction distKm=" + ROUND(bestDist/1000, 1)
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
        LOCAL finalDist IS geoDistance(finalImpact:LAT, finalImpact:LNG, KSC_LAT, KSC_LNG).
        mLog("Post-correction impact: " + ROUND(finalImpact:LAT, 2) + "," + ROUND(finalImpact:LNG, 2)
            + "  dist=" + ROUND(finalDist/1000, 1) + "km from KSC.").
        mLogWarn("STATS aerobrake postburn distKm=" + ROUND(finalDist/1000, 1)
            + " impact=" + ROUND(finalImpact:LAT, 4) + "," + ROUND(finalImpact:LNG, 4)).
    }
}

// ============================================================
// Vessel prep helpers
// ============================================================

LOCAL FUNCTION _aerobrakeRetractAntennas {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL m IS p:GETMODULE("ModuleDeployableAntenna").
            IF m:HASEVENT("retract antenna") {
                m:DOEVENT("retract antenna").
                SET retracted TO retracted + 1.
                mLog("Retracted antenna: " + p:TITLE).
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " antenna(s).").
        WAIT 3.
    } ELSE {
        mLog("No deployable antennas to retract.").
    }
}

LOCAL FUNCTION _aerobrakeDecouple {
    IF NOT CFG:HASKEY("AEROBRAKE_DECOUPLE_TAG") { RETURN. }
    LOCAL tag IS CFG["AEROBRAKE_DECOUPLE_TAG"].
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
    LOCAL dir IS "RETROGRADE".
    IF CFG:HASKEY("AEROBRAKE_REENTRY_DIR") { SET dir TO CFG["AEROBRAKE_REENTRY_DIR"]. }

    LOCAL steerDir IS RETROGRADE.
    LOCAL refVec IS -SHIP:VELOCITY:ORBIT.
    IF dir = "PROGRADE" {
        SET steerDir TO PROGRADE.
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
    IF NOT CFG:HASKEY("AEROBRAKE_ARM_CHUTES") { RETURN. }
    IF CFG["AEROBRAKE_ARM_CHUTES"] <= 0 { RETURN. }

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
