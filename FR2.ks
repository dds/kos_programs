// ============================================================
// FR2.ks  —  FR2 vehicle flight computer  (0:/FR2.ks)
//
// Ship name format:  FR2-TARGET-TYPE1-TYPE2-...
// e.g.  FR2-MUN-CRASHPROBE1-RELAY1
//
// Payload types (order in name = execution order):
//   RELAY1       — relay station keeping after circularization
//   CRASHPROBE1  — lower Pe, release probe, recircularize relay
//   STKSAT1      — deploy satellite (stub, future)
//
// Tagged parts required in VAB:
//   probe_decoupler   — decoupler between relay and impactor
//   main_fairing      — fairing
//
// Phase sequence:
//   LAUNCH → FAIRING → EXTEND_ANTS → PARKING 
//   If leaving Kerbin, PARKING → TRANSFER → COAST → CAPTURE 
//   Otherwise, skip the transfer, coast, and capture. 
//   [payload phases derived from ship name tokens] → CIRC → DONE
// ============================================================

// ============================================================
// CONFIG — adjust per launch, sane FR2 defaults here
// ============================================================
GLOBAL CFG IS LEXICON(
    // Ascent
    "PARKING_ALT",         100000,  // m — MJ target orbit altitude
    "LAUNCH_INCLINATION",      90,  // deg — 0 = equatorial
    "LAUNCH_AZIMUTH",           0,  // deg — 90 = due east from KSC
    "LAUNCH_STAGE_LIMIT",       3,  // MJ AutoStageLimit
    "FAIRING_ALT",          68000,  // m — jettison main_fairing
    "EXTEND_ALT",           72000,  // m - extend panels & attenae 

    // Transfer + capture
    "RELAY_ALT",           1000000,  // m above target body
    "CAPTURE_PE",            20000,  // m — arrival Pe aim point
    "CIRC_ECC_TOL",          0.005,  // ~2.5km at 500km
    "TARGET_INCLINATION",    90,     // deg — 0=equatorial, 90=polar, -1=match vessel
    "INCL_MATCH_TARGET",     "",     // vessel name to match if TARGET_INCLINATION=-1
    "INCL_TOLERANCE",        0.01,   // deg
    "MAX_INCL_CHANGE_DV",    200,  // m/s — skip if correction would cost more

    // Probe impact
    "PROBE_TARGET_LAT",        80.0,
    "PROBE_TARGET_LNG",         0.0,
    "PROBE_ENTRY_PE",         30000,
    "PROBE_TARGET_TOL",        5000 // m  - acceptable miss distance
).
// ============================================================

// ── Phase sequence builder ─────────────────────────────────
LOCAL FUNCTION buildPhaseSequence {
    LOCAL seq IS LIST(
        "LAUNCH",
        "FAIRING",
        "EXTEND_ANTS",
        "PARKING"
    ).
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        seq.ADD("TRANSFER").
        seq.ADD("COAST").
        seq.ADD("CAPTURE").
    }
    FOR ptype IN missionPayloads() {
        LOCAL t IS _normalizePayloadType(ptype).
        IF t = "CRASHPROBE" OR t = "PROBE" {
            seq:ADD("TARGETED_DEORBIT").
            seq:ADD("RELEASE_PROBE").
        }
    }

    seq:ADD("CIRC").
    seq:ADD("RAISE_ALT").
    seq:ADD("INCL_CORRECT").

    FOR ptype IN missionPayloads() {
        LOCAL t IS _normalizePayloadType(ptype).
        IF t = "RELAY" OR t = "SCANSAT" OR t = "SCISAT" {
            seq:ADD("RELAY_OPS").
        }
    }
    seq:ADD("DONE").
    RETURN seq.
}

LOCAL FUNCTION _normalizePayloadType {
    PARAMETER raw.
    // Strip trailing digits and hyphens.
    LOCAL result IS raw:TOUPPER.
    UNTIL result:LENGTH = 0 {
        LOCAL last IS result:SUBSTRING(result:LENGTH - 1, 1).
        IF last:MATCHESPATTERN("[0-9]") OR last = "-" {
            SET result TO result:SUBSTRING(0, result:LENGTH - 1).
        } ELSE { 
            BREAK.
        }
    }
    RETURN result.
}

// ── Phase advance ──────────────────────────────────────────
LOCAL FUNCTION nextPhase {
    LOCAL seq IS buildPhaseSequence().
    LOCAL current IS stateGet("phase", seq[0]).
    LOCAL i IS 0.
    UNTIL i >= seq:LENGTH {
        IF seq[i] = current {
            IF i + 1 < seq:LENGTH {
                LOCAL nxt IS seq[i + 1].
                stateSet("phase", nxt).
                mLog("Phase: " + current + " → " + nxt).
                RETURN nxt.
            } ELSE {
                stateSet("phase", "DONE").
                RETURN "DONE".
            }
        }
        SET i TO i + 1.
    }
    mLogWarn("Phase " + current + " not in sequence — advancing to DONE.").
    stateSet("phase", "DONE").
    RETURN "DONE".
}

// ── Main entry ─────────────────────────────────────────────
GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    mLogPhase("FR2 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" → ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }
    _runPhaseLoop().
}

LOCAL FUNCTION _runPhaseLoop {
    UNTIL FALSE {
        LOCAL phase IS stateGet("phase","DONE").
        mLogPhase(phase).
        IF      phase = "LAUNCH"       { _phaseLaunch().       }
        ELSE IF phase = "PARKING"      { _phaseParking().      }
        ELSE IF phase = "FAIRING"      { _phaseFairing().      }
        ELSE IF phase = "EXTEND_ANTS"  { _phaseExtendAnts().   }
        ELSE IF phase = "TRANSFER"     { _phaseTransfer().     }
        ELSE IF phase = "COAST"        { _phaseCoast().        }
        ELSE IF phase = "CAPTURE"      { _phaseCapture().      }
        ELSE IF phase = "CIRC"         { _phaseCirc().         }
        ELSE IF phase = "RAISE_ALT"    { _phaseRaiseAlt().         }
        ELSE IF phase = "INCL_CORRECT" { _phaseInclCorrect().  }
        ELSE IF phase = "TARGETED_DEORBIT" { _phaseTargetedDeorbit(). }
        ELSE IF phase = "RELEASE_PROBE"{ _phaseReleaseProbe(). }
        ELSE IF phase = "RECIRC"       { _phaseRecirc().       }
        ELSE IF phase = "RELAY_OPS"    { _phaseRelayOps().     }
        ELSE IF phase = "DEPLOY_SAT"   { _phaseDeploySat().    }
        ELSE IF phase = "DONE"         { _phaseDone(). RETURN. }
        ELSE {
            mLogError("Unknown phase: " + phase + " — halting.").
            stateSet("phase","DONE").
        }
    }
}

// ── LAUNCH ─────────────────────────────────────────────────
LOCAL FUNCTION _phaseLaunch {
    mLog("Configuring MechJeb ascent...").

    IF NOT ADDONS:MJ:AVAILABLE {
        mLogError("MechJeb not available — cannot auto-launch.").
        HUDTEXT("ERROR: MechJeb unavailable!", 10, 2, 18, RED, FALSE).
        RETURN.  // stay in LAUNCH — operator must intervene
    }

    LOCAL mjCore IS ADDONS:MJ:CORE.
    mLog("MechJeb core running: " + mjCore:RUNNING).

    LOCAL asc IS ADDONS:MJ:ASCENT.
    SET asc:ENABLED               TO TRUE.
    SET asc:DESIREDALTITUDE       TO CFG["PARKING_ALT"].
    SET asc:DESIREDINCLINATION    TO CFG["LAUNCH_INCLINATION"].
    SET asc:AUTOSTAGE             TO FALSE.
    SET asc:AUTOSTAGELIMIT        TO CFG["LAUNCH_STAGE_LIMIT"].
    SET asc:AUTODEPLOYANTENNAS    TO FALSE.
    SET asc:AUTODEPLOYSOLARPANELS TO FALSE.
    SET asc:AUTOWARP              TO FALSE.
    SET asc:SKIPCIRCULARIZATION   TO FALSE.

    mLog("MechJeb ascent armed. Alt=" + ROUND(CFG["PARKING_ALT"]/1000,0)
        + "km  inc=" + CFG["LAUNCH_INCLINATION"]
        + "°  az=" + CFG["LAUNCH_AZIMUTH"] + "°").

    // Launch abort monitor. Arms at launch, stays active through PARKING.
    WHEN stateGet("phase","") = "LAUNCH" OR stateGet("phase","") = "PARKING" THEN {
        LOCAL abortTriggered IS FALSE.
        
        // Anomalous trajectory — falling back with low Ap after 15s
        IF TIME:SECONDS > (stateGetNum("launch_time",0) + 15)
                AND SHIP:APOAPSIS < 30000
                AND SHIP:VERTICALSPEED < 0 {
            SET abortTriggered TO TRUE.
            mLogError("Abort: anomalous trajectory — Ap=" + ROUND(SHIP:APOAPSIS/1000,1) + "km").
        }
        

        // Unrecoverable attitude — only check below 40km and moving
        IF SHIP:ALTITUDE < 40000
                AND SHIP:VELOCITY:SURFACE:MAG > 10
                AND VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE) > 45 {
            SET abortTriggered TO TRUE.
            mLogError("Abort: attitude divergence — "
                + ROUND(VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:SURFACE),1) + "deg off prograde").
        }
        
        // Manual abort keypress
        IF ABORT { SET abortTriggered TO TRUE. mLogError("Abort: manual trigger."). }
        
        IF abortTriggered {
            _launchAbort().
            RETURN.  // disarm trigger
        }
        
        PRESERVE.
    }
    
    // Store launch time for trajectory check
    stateSetNum("launch_time", TIME:SECONDS).

    // Ignition
    mLog("Press ABORT within 5s to hold launch.").
    HUDTEXT("T-5: press ABORT to hold", 5, 2, 16, YELLOW, FALSE).
    LOCAL aborted IS FALSE.
    LOCAL tEnd IS TIME:SECONDS + 5.
    WAIT UNTIL TIME:SECONDS >= tEnd OR ABORT.
    IF ABORT { SET aborted TO TRUE. }
    IF aborted {
        mLog("Launch hold — operator abort.").
        SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
        RETURN.  // stays in LAUNCH phase — reboot or manual resumeMission() to retry
    }
    countdown(3).
    
    STAGE.
    mLog("Launch — STAGE fired.").
    HUDTEXT("Launch!", 3, 2, 18, YELLOW, FALSE).

    // Arm staging monitor — stays active through entire ascent
    WHEN _ascentNeedsStage() THEN {
        IF stateGet("phase","") = "DONE" { RETURN. }  // disarm after mission
        mLog("Ascent auto-stage at alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
        HUDTEXT("Staging!", 2, 2, 14, YELLOW, FALSE).
        STAGE.
        WAIT 0.5.
        PRESERVE.
    }

    nextPhase().
}

LOCAL FUNCTION _launchAbort {
    mLogError("LAUNCH ABORT TRIGGERED.").
    HUDTEXT("ABORT — CUT ENGINES", 5, 2, 20, RED, FALSE).
    
    // Cut engines immediately
    SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    
    // Deploy all parachutes
    LOCAL chutes IS SHIP:PARTSTAGGED("chute_main").
    IF chutes:LENGTH > 0 {
        FOR c IN chutes {
            IF c:HASMODULE("ModuleParachute") {
                LOCAL modu IS c:GETMODULE("ModuleParachute").
                IF modu:HASEVENT("Deploy Chute") {
                    modu:DOEVENT("Deploy Chute").
                } ELSE IF modu:HASEVENT("Arm Parachute") {
                    modu:DOEVENT("Arm Parachute").
                }
            }
        }
        mLog("Parachutes deployed.").
    } ELSE {
        // No tagged chutes — try action group 6 as fallback
        AG6 ON.
        mLogWarn("No tagged chutes found — fired AG6.").
    }
    
    HUDTEXT("ABORT — CHUTES DEPLOYED", 8, 2, 18, ORANGE, FALSE).
    stateSet("phase", "ABORT").
    mLog("Abort complete. Awaiting landing.").
}

LOCAL FUNCTION _ascentNeedsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

// ── PARKING ────────────────────────────────────────────────
LOCAL FUNCTION _phaseParking {
    mLog("Waiting for stable parking orbit...").
    WAIT UNTIL _isParkingOrbitStable(). 
    orbitSummary().
    mLog("Stable parking orbit confirmed.").
    nextPhase().
}

LOCAL FUNCTION _isParkingOrbitStable {
    LOCAL target IS CFG["PARKING_ALT"].
    LOCAL tol IS target * 0.10.
    RETURN SHIP:PERIAPSIS > (target - tol) 
        AND SHIP:APOAPSIS < (target + tol)
        AND SHIP:APOAPSIS > (target - tol).
}

// ── FAIRING ────────────────────────────────────────────────
LOCAL FUNCTION _phaseFairing {
    IF stateGet("fairing_deployed","false") = "true" {
        mLog("Fairing already deployed.").
        nextPhase().
        RETURN.
    }
    IF SHIP:ALTITUDE < CFG["FAIRING_ALT"] {
        mLog("Waiting for fairing alt " + ROUND(CFG["FAIRING_ALT"]/1000,0) + "km...").
        WAIT UNTIL SHIP:ALTITUDE >= CFG["FAIRING_ALT"].
    }
    _deployFairing().
    nextPhase().
}

// ── Transfer ────────────────────────────────────────────────
LOCAL FUNCTION _phaseTransfer {

    LOCAL target IS missionTargetBody().
    orbitSummary().
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL success IS FALSE.
    UNTIL success {
        planTransfer(target, CFG["CAPTURE_PE"]).
        SET success TO executeManeuver().
        IF NOT success {
            mLog("Transfer missed — waiting one orbit and replanning.").
            WAIT UNTIL NOT HASNODE.
        }
    }
    nextPhase().
}

// ── COAST ──────────────────────────────────────────────────
LOCAL FUNCTION _phaseCoast {
    LOCAL target IS missionTargetBody().
    SET SAS TO TRUE.
    UNLOCK STEERING.
    mLog("Coasting to " + target:NAME + " SOI.").
    waitForSOI(target).
    orbitSummary().
    nextPhase().
}

// ── CAPTURE ────────────────────────────────────────────────
LOCAL FUNCTION _phaseCapture {
    LOCAL target IS missionTargetBody().
    WAIT 2. // let KE update after warp/SOI transition
    mLog("Planning capture at " + target:NAME + ".").
    LOCAL success IS FALSE.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planCapture(target, CFG["RELAY_ALT"]).
        SET success TO executeManeuver().
        IF NOT success { mLog("Capture missed - replanning."). }
    }
    orbitSummary().
    nextPhase().
}

// ── CIRC ───────────────────────────────────────────────────
LOCAL FUNCTION _phaseCirc {
    IF _impactThreat() {
        mLog("Impact threat — raising Pe immediately.").
        LOCAL success IS FALSE.
        UNTIL success {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            planRaisePeNow(CFG["RELAY_ALT"]).
            SET success TO executeManeuver().
            IF NOT success { mLog("Raise Pe missed — replanning."). }
        }
    } ELSE IF SHIP:ORBIT:ECCENTRICITY < CFG["CIRC_ECC_TOL"] {
        mLog("Already circular (ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4) + ").").
    } ELSE {
        LOCAL success IS FALSE.
        UNTIL success {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            planCircularize().
            SET success TO executeManeuver().
            IF NOT success { mLog("Circ burn missed — replanning."). }
        }
    }
    orbitSummary().
    nextPhase().
}

LOCAL FUNCTION _impactThreat {
    LOCAL myBody IS SHIP:ORBIT:BODY.
    LOCAL pe   IS SHIP:PERIAPSIS.

    IF myBody:ATM:EXISTS {
        RETURN pe < myBody:ATM:HEIGHT + 1000.
    }

    RETURN pe < 5000.
}

// ── TARGETED_DEORBIT ───────────────────────────────────────────────
LOCAL FUNCTION _phaseTargetedDeorbit {
    // Check target is reachable from current inclination
    IF NOT targetReachable(CFG["PROBE_TARGET_LAT"]) {
        mLogWarn("Target lat=" + CFG["PROBE_TARGET_LAT"]
            + " not reachable from inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
            + "deg — proceeding with best effort.").
    }
    targetedDeorbit().
    nextPhase().
}

// ── RELEASE_PROBE ──────────────────────────────────────────
LOCAL FUNCTION _phaseReleaseProbe {
    LOCAL parts IS SHIP:PARTSTAGGED("probe_decoupler").
    IF parts:LENGTH = 0 {
        mLogError("No part tagged 'probe_decoupler' — cannot release probe.").
        HUDTEXT("ERROR: probe_decoupler missing!", 10, 2, 18, RED, FALSE).
        RETURN.  // stay here — operator must intervene
    }

    SET SAS TO TRUE.
    WAIT 1.

    // Arm parachutes on probe immediately after release
    LOCAL lChutes IS SHIP:PARTSTAGGED("probe_chute").
    IF lChutes:LENGTH > 0 {
        FOR c IN lChutes {
            IF c:HASMODULE("ModuleParachute") {
                LOCAL modu IS c:GETMODULE("ModuleParachute").
                IF modu:HASEVENT("Arm Parachute") {
                    modu:DOEVENT("Arm Parachute").
                    mLog("Probe chute armed.").
                } ELSE IF modu:HASEVENT("Deploy") {
                    modu:DOEVENT("Deploy").
                    mLog("Probe chute deployed/armed.").
                }
            }
        }
    } ELSE {
        // Fallback — try action group
        mLogWarn("No parts tagged 'probe_chute' — trying AG5.").
        AG5 ON.
    }

    WAIT 0.2.
    
    LOCAL dc IS parts[0].
    IF dc:HASMODULE("ModuleDecouple") {
        dc:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
        dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogError("probe_decoupler has no recognized decouple module.").
        RETURN.
    }
    WAIT 0.5.
    
    stateSet("probe_released_time", TIME:SECONDS).
    mLog("Probe released. Relay mass: " + ROUND(SHIP:MASS,2) + "t.").
    nextPhase().
}

// ── RECIRC ─────────────────────────────────────────────────
LOCAL FUNCTION _phaseRecirc {
    mLog("Re-circularizing relay at " + ROUND(CFG["RELAY_ALT"]/1000,0) + "km.").
    planRecircularize(CFG["RELAY_ALT"]).
    executeManeuver().
    orbitSummary().
    nextPhase().
}

// ── RELAY_OPS ──────────────────────────────────────────────
LOCAL FUNCTION _phaseRelayOps {
    UNLOCK STEERING.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    SET SAS TO TRUE.
    orbitSummary().
    mLog("Relay on station at " + MISSION["target"] + ".").
    HUDTEXT("Relay deployed: " + MISSION["target"], 8, 2, 18, GREEN, FALSE).
    LOCAL n IS 0.
    UNTIL n >= 5 { WAIT 60. orbitSummary(). SET n TO n + 1. }
    nextPhase().
}

// ── DEPLOY_SAT ─────────────────────────────────────────────
LOCAL FUNCTION _phaseDeploySat {
    mLog("DEPLOY_SAT: not yet implemented.").
    nextPhase().
}

// ── DONE ───────────────────────────────────────────────────
LOCAL FUNCTION _phaseDone {
    UNLOCK ALL.
    SET SAS TO TRUE.
    mLog("Mission complete: " + SHIP:NAME).
    HUDTEXT("Mission Complete: " + MISSION["target"], 10, 2, 20, GREEN, FALSE).
}

// ── Fairing helper ─────────────────────────────────────────
LOCAL FUNCTION _deployFairing {
    LOCAL parts IS SHIP:PARTSTAGGED("main_fairing").
    IF parts:LENGTH = 0 {
        mLogWarn("No part tagged 'main_fairing' — skipping fairing deploy.").
        RETURN.
    }
    LOCAL fairingPart IS parts[0].
    IF NOT fairingPart:HASMODULE("ModuleProceduralFairing") {
        mLogWarn("main_fairing has no ModuleProceduralFairing.").
        RETURN.
    }
    LOCAL myMod IS fairingPart:GETMODULE("ModuleProceduralFairing").
    IF myMod:HASEVENT("Deploy") {
        myMod:DOEVENT("Deploy").
        stateSet("fairing_deployed", "true").
        mLog("Fairing deployed at " + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
    } ELSE {
        mLogWarn("Fairing Deploy event not available.").
    }
}

LOCAL FUNCTION _phaseExtendAnts {
    IF SHIP:ALTITUDE < CFG["EXTEND_ALT"] {
        mLog("Waiting for deploy alt " + ROUND(CFG["EXTEND_ALT"]/1000,0) + "km...").
        WAIT UNTIL SHIP:ALTITUDE >= CFG["EXTEND_ALT"].
    }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL sm IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF sm:HASEVENT("Extend Solar Panel") { sm:DOEVENT("Extend Solar Panel"). }
        }
    }
    mLog("Solar panels deployed.").
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL am IS p:GETMODULE("ModuleDeployableAntenna").
            IF am:HASEVENT("Extend Antenna") { am:DOEVENT("Extend Antenna"). }
        }
    }
    mLog("Antennas deployed.").
    nextPhase().
}

LOCAL FUNCTION _phaseRaiseAlt {
    LOCAL targetAlt IS CFG["RELAY_ALT"].
    IF SHIP:APOAPSIS > targetAlt * 0.99 {
        mLog("Already at target altitude.").
        nextPhase().
        RETURN.
    }
    mLog("Raising to " + ROUND(targetAlt/1000,0) + "km.").
    LOCAL success IS FALSE.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        // Raise Ap to target altitude
        LOCAL mu    IS SHIP:ORBIT:BODY:MU.
        LOCAL rNow  IS SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS.
        LOCAL rTarget IS SHIP:ORBIT:BODY:RADIUS + targetAlt.
        LOCAL tSMA  IS (rNow + rTarget) / 2.
        LOCAL vNow  IS VELOCITYAT(SHIP, TIME:SECONDS + ETA:APOAPSIS):ORBIT:MAG.
        LOCAL vNew  IS SQRT(mu * (2/rNow - 1/tSMA)).
        LOCAL dv    IS vNew - vNow.
        LOCAL nd    IS NODE(TIME:SECONDS + ETA:APOAPSIS, 0, 0, dv).
        ADD nd.
        mLog("Raise Ap: dV=" + ROUND(dv,1) + " m/s").
        SET success TO executeManeuver().
        IF NOT success { mLog("Raise Ap missed — replanning."). }
    }
    // Now circularize at new Ap
    SET success TO FALSE.
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        planCircularize().
        SET success TO executeManeuver().
        IF NOT success { mLog("Circ at target alt missed — replanning."). }
    }
    orbitSummary().
    nextPhase().
}

LOCAL FUNCTION _phaseInclCorrect {
    LOCAL targetInc IS resolveTargetInclination().
    LOCAL currentInc IS SHIP:ORBIT:INCLINATION.

    // If in retrograde orbit (inc > 90) and target is prograde (< 90),
    // this is a massive plane change — warn and skip rather than burn
    // half the mission budget on a plane change
    IF currentInc > 90 AND targetInc < 90 {
        mLogWarn("Retrograde orbit detected (inc=" + ROUND(currentInc,1)
            + "deg) but target is prograde (" + ROUND(targetInc,1)
            + "deg) — plane change would cost ~600m/s. Skipping.").
        HUDTEXT("WARNING: Retrograde orbit — skipping incl correction", 
            8, 2, 15, YELLOW, FALSE).
        nextPhase().
        RETURN.
    }

    // If retrograde orbit and target is also retrograde family,
    // correct within retrograde — target should be 180-targetInc
    IF currentInc > 90 AND targetInc > 90 {
        // Normal correction within retrograde family
    }

    LOCAL deltaInc IS ABS(currentInc - targetInc).
    IF deltaInc <= CFG["INCL_TOLERANCE"] {
        mLog("Inclination within tolerance — skipping.").
        nextPhase().
        RETURN.
    }

    mLog("Correcting inclination: " + ROUND(currentInc,2)
        + "deg → " + ROUND(targetInc,2)
        + "deg  delta=" + ROUND(deltaInc,2) + "deg").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    planInclinationChange(targetInc).
    
    IF NEXTNODE:DELTAV:MAG > CFG["MAX_INCL_CHANGE_DV"] {
        mLogWarn("Inclination correction would cost " + ROUND(NEXTNODE:DELTAV:MAG,0)
            + "m/s — exceeds MAX_INCL_CHANGE_DV. Skipping.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        nextPhase().
        RETURN.
    }

    executeManeuver().
    orbitSummary().
    nextPhase().
}