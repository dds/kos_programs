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
//   main_fairing      — procedural fairing
//
// Phase sequence:
//   LAUNCH → PARKING → FAIRING → TMI → COAST → CAPTURE → CIRC
//   → [payload phases derived from ship name tokens] → DONE
// ============================================================

// ============================================================
// CONFIG — adjust per launch, sane FR2 defaults here
// ============================================================
GLOBAL CFG IS LEXICON(
    // Ascent
    "PARKING_ALT",          90000,  // m — MJ target orbit altitude
    "LAUNCH_INCLINATION",       0,  // deg — 0 = equatorial
    "LAUNCH_AZIMUTH",          90,  // deg — 90 = due east from KSC
    "LAUNCH_STAGE_LIMIT",       2,  // MJ AutoStageLimit
    "FAIRING_ALT",          68000,  // m — jettison main_fairing

    // Transfer + capture
    "RELAY_ALT",           500000,  // m above target body
    "CAPTURE_PE",           50000,  // m — arrival Pe aim point
    "CIRC_ECC_TOL",           0.02, // eccentricity threshold

    // Probe impact
    "PROBE_IMPACT_PE",        5000  // m — impact trajectory Pe
).
// ============================================================

// ── Phase sequence builder ─────────────────────────────────
LOCAL FUNCTION buildPhaseSequence {
    LOCAL seq IS LIST(
        "LAUNCH",
        "PARKING",
        "FAIRING",
        "TMI",
        "COAST",
        "CAPTURE",
        "CIRC"
    ).
    FOR ptype IN missionPayloads() {
        LOCAL t IS ptype:TOUPPER.
        IF t = "CRASHPROBE1" OR t = "PROBE1" {
            seq:ADD("LOWER_PE").
            seq:ADD("RELEASE_PROBE").
            seq:ADD("RECIRC").
        } ELSE IF t = "RELAY1" {
            seq:ADD("RELAY_OPS").
        } ELSE IF t = "STKSAT1" {
            seq:ADD("DEPLOY_SAT").
        } ELSE {
            mLogWarn("Unknown payload type: " + t + " — skipped.").
        }
    }
    seq:ADD("DONE").
    RETURN seq.
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
        ELSE IF phase = "TMI"          { _phaseTMI().          }
        ELSE IF phase = "COAST"        { _phaseCoast().        }
        ELSE IF phase = "CAPTURE"      { _phaseCapture().      }
        ELSE IF phase = "CIRC"         { _phaseCirc().         }
        ELSE IF phase = "LOWER_PE"     { _phaseLowerPe().      }
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
    SET asc:AUTODEPLOYANTENNAS    TO TRUE.
    SET asc:AUTODEPLOYSOLARPANELS TO TRUE.
    SET asc:AUTOWARP              TO FALSE.
    SET asc:SKIPCIRCULARIZATION   TO FALSE.

    mLog("MechJeb ascent armed. Alt=" + ROUND(CFG["PARKING_ALT"]/1000,0)
        + "km  inc=" + CFG["LAUNCH_INCLINATION"]
        + "°  az=" + CFG["LAUNCH_AZIMUTH"] + "°").

    // Ignition
    mLog("Press ABORT within 5s to hold launch.").
    HUDTEXT("T-5: press ABORT to hold", 5, 2, 16, YELLOW, FALSE).
    LOCAL aborted IS FALSE.
    LOCAL tEnd IS TIME:SECONDS + 5.
    WAIT UNTIL TIME:SECONDS >= tEnd OR ABORT {
        IF ABORT { SET aborted TO TRUE. }
    }
    IF aborted {
        mLog("Launch hold — operator abort.").
        SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
        RETURN.  // stays in LAUNCH phase — reboot or manual resumeMission() to retry
    }
    countdown(3).
    
    STAGE.
    mLog("Launch — STAGE fired.").
    HUDTEXT("Launch!", 3, 2, 18, YELLOW, FALSE).

    nextPhase().
}

// ── PARKING ────────────────────────────────────────────────
LOCAL FUNCTION _phaseParking {
    mLog("Ascent monitoring — kOS owns staging, MJ owns steering/throttle.").

    UNTIL isOrbitStable(CFG["PARKING_ALT"] - 2000) {

        // Fairing deploy check
        IF stateGet("fairing_deployed","false") = "false"
                AND SHIP:ALTITUDE >= CFG["FAIRING_ALT"] {
            _deployFairing().
        }

        // Staging monitor
        LOCAL needsStage IS FALSE.
        IF SHIP:MAXTHRUST = 0 { SET needsStage TO TRUE. }
        IF NOT needsStage {
            LOCAL engs IS LIST().
            LIST ENGINES IN engs.
            FOR eng IN engs {
                IF eng:FLAMEOUT { SET needsStage TO TRUE. }
            }
        }

        IF needsStage {
            // Don't stage if the next stage only contains the fairing
            // and we haven't hit fairing alt yet — let _deployFairing handle it
            LOCAL safeToStage IS TRUE.
            IF stateGet("fairing_deployed","false") = "false"
                    AND SHIP:ALTITUDE < CFG["FAIRING_ALT"] {
                // Check if next stage contains only the tagged fairing
                LOCAL fairingParts IS SHIP:PARTSTAGGED("main_fairing").
                IF fairingParts:LENGTH > 0 {
                    LOCAL nextStageParts IS SHIP:PARTSINDECOUPLESTAGE(STAGE:NUMBER - 1).
                    LOCAL allFairing IS TRUE.
                    FOR p IN nextStageParts {
                        IF p:TAG <> "main_fairing" { SET allFairing TO FALSE. }
                    }
                    IF allFairing { SET safeToStage TO FALSE. }
                }
            }

            IF safeToStage {
                mLog("Ascent auto-stage at alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
                HUDTEXT("Staging!", 2, 2, 14, YELLOW, FALSE).
                STAGE.
                WAIT 0.5.
            }
        }

        WAIT 0.1.
    }

    // Disable MJ ascent now that we're on station
    IF ADDONS:MJ:AVAILABLE {
        SET ADDONS:MJ:ASCENT:ENABLED TO FALSE.
        mLog("MechJeb ascent disabled.").
    }

    orbitSummary().
    mLog("Stable parking orbit confirmed.").
    nextPhase().
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

// ── TMI ────────────────────────────────────────────────────
LOCAL FUNCTION _phaseTMI {
    LOCAL target IS missionTargetBody().
    orbitSummary().
    mLog("Planning transfer to " + target:NAME + ".").
    planTransfer(target).
    executeManeuver().
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
    mLog("Planning capture at " + target:NAME + ".").
    planCapture(target, CFG["RELAY_ALT"]).
    executeManeuver().
    orbitSummary().
    nextPhase().
}

// ── CIRC ───────────────────────────────────────────────────
LOCAL FUNCTION _phaseCirc {
    IF SHIP:ORBIT:ECCENTRICITY < CFG["CIRC_ECC_TOL"] {
        mLog("Already circular (ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4) + ").").
    } ELSE {
        planCircularize().
        executeManeuver().
    }
    orbitSummary().
    nextPhase().
}

// ── LOWER_PE ───────────────────────────────────────────────
LOCAL FUNCTION _phaseLowerPe {
    mLog("Lowering Pe to " + ROUND(CFG["PROBE_IMPACT_PE"]/1000,1) + "km.").
    planLowerPe(CFG["PROBE_IMPACT_PE"]).
    executeManeuver().
    orbitSummary().
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
    LOCAL mod IS fairingPart:GETMODULE("ModuleProceduralFairing").
    IF mod:HASEVENT("Deploy") {
        mod:DOEVENT("Deploy").
        stateSet("fairing_deployed", "true").
        mLog("Fairing deployed at " + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
    } ELSE {
        mLogWarn("Fairing Deploy event not available.").
    }
}
