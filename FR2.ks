// ============================================================
// FR2.ks  —  FR2 vehicle flight computer  (0:/FR2.ks)
//
// Handles any FR2 mission by reading MISSION lexicon from boot:
//   MISSION["target"]   — body name string e.g. "MUN"
//   MISSION["payloads"] — comma-joined type list e.g. "RELAY1,PROBE1"
//
// Payload types (case-insensitive, order defines execution):
//   RELAY1   — circularize, enter relay station keeping
//   PROBE1   — lower Pe, release probe, re-circularize relay
//   STKSAT1  — circularize, deploy satellite (future)
//
// Named parts required (tag in VAB):
//   probe_decoupler   — decoupler between relay and impactor
//   main_fairing      — procedural fairing jettisoned at FAIRING_ALT
//
// Phase sequence (all persisted in state.json):
//   PARKING → FAIRING → TMI → COAST → CAPTURE → CIRC
//   → [payload phases in order] → DONE
//
// Payload phases:
//   RELAY1:  RELAY_OPS
//   PROBE1:  LOWER_PE → RELEASE_PROBE → RECIRC
// ============================================================

// ============================================================
// CONFIG — adjust between launches
// ============================================================
GLOBAL CFG IS LEXICON(
    "PARKING_ALT",     90000,   // m — target Kerbin parking orbit
    "PARKING_TOL",      2000,   // m — Pe/Ap tolerance for "stable"
    "FAIRING_ALT",     68000,   // m — jettison main_fairing here
    "RELAY_ALT",      500000,   // m above target body — relay orbit
    "PROBE_IMPACT_PE",  5000,   // m — impact trajectory Pe
    "CIRC_ECC_TOL",     0.02,   // eccentricity threshold for "circular"
    "CAPTURE_PE",      50000    // m — aim for this Pe on arrival
                                //     (lower than RELAY_ALT, raise after)
).
// ============================================================

// ── Phase sequence builder ─────────────────────────────────
// Produces an ordered LIST of phase name strings from payload types.
// Phases before payload-specific work are always the same.
LOCAL FUNCTION buildPhaseSequence {
    LOCAL seq IS LIST(
        "PARKING",
        "FAIRING",
        "TMI",
        "COAST",
        "CAPTURE",
        "CIRC"
    ).

    // Append payload phases in the order types appear in ship name
    FOR ptype IN missionPayloads() {
        LOCAL t IS ptype:TOUPPER.
        IF      t = "PROBE1" {
            seq:ADD("LOWER_PE").
            seq:ADD("RELEASE_PROBE").
            seq:ADD("RECIRC").
        }
        ELSE IF t = "RELAY1"  { seq:ADD("RELAY_OPS").  }
        ELSE IF t = "STKSAT1" { seq:ADD("DEPLOY_SAT"). }
        ELSE {
            mLogWarn("Unknown payload type: " + t + " — skipped.").
        }
    }

    seq:ADD("DONE").
    RETURN seq.
}

// ── Advance to next phase ──────────────────────────────────
LOCAL FUNCTION nextPhase {
    LOCAL seq IS buildPhaseSequence().
    LOCAL current IS stateGet("phase", seq[0]).
    LOCAL i IS 0.
    UNTIL i >= seq:LENGTH {
        IF seq[i] = current {
            IF i + 1 < seq:LENGTH {
                LOCAL next IS seq[i + 1].
                stateSet("phase", next).
                mLog("Phase: " + current + " → " + next).
                RETURN next.
            } ELSE {
                stateSet("phase", "DONE").
                RETURN "DONE".
            }
        }
        SET i TO i + 1.
    }
    // Current phase not found in sequence — go to DONE
    mLogWarn("Phase " + current + " not in sequence. Advancing to DONE.").
    stateSet("phase", "DONE").
    RETURN "DONE".
}

// ── Main entry ─────────────────────────────────────────────
GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    mLogPhase("FR2 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Phase sequence: " + seq:JOIN(" → ")).

    // Set initial phase if not already in state
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    _runPhaseLoop().
}

LOCAL FUNCTION _runPhaseLoop {
    UNTIL FALSE {
        LOCAL phase IS stateGet("phase","DONE").
        mLogPhase(phase).

        IF      phase = "PARKING"      { _phaseParking().      }
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
            mLogError("Unknown phase: " + phase).
            stateSet("phase","DONE").
        }
    }
}

// ── Phases ─────────────────────────────────────────────────

LOCAL FUNCTION _phaseParking {
    // MechJeb owns ascent — we wait for a stable parking orbit.
    WAIT UNTIL isOrbitStable(CFG["PARKING_ALT"] - CFG["PARKING_TOL"]).
    orbitSummary().
    mLog("Stable parking orbit confirmed.").
    nextPhase().
}

LOCAL FUNCTION _phaseFairing {
    IF stateGet("fairing_deployed","false") = "true" {
        mLog("Fairing already deployed.").
        nextPhase().
        RETURN.
    }
    IF SHIP:ALTITUDE < CFG["FAIRING_ALT"] {
        mLog("Waiting for fairing alt: " + ROUND(CFG["FAIRING_ALT"]/1000,0) + "km").
        WAIT UNTIL SHIP:ALTITUDE >= CFG["FAIRING_ALT"].
    }
    _deployFairing().
    nextPhase().
}

LOCAL FUNCTION _phaseTMI {
    LOCAL target IS missionTargetBody().
    orbitSummary().
    mLog("Planning transfer to " + target:NAME).
    planTransfer(target).
    executeManeuver().
    nextPhase().
}

LOCAL FUNCTION _phaseCoast {
    LOCAL target IS missionTargetBody().
    SET SAS TO TRUE.
    UNLOCK STEERING.
    mLog("Coasting to " + target:NAME + " SOI.").
    waitForSOI(target).
    orbitSummary().
    nextPhase().
}

LOCAL FUNCTION _phaseCapture {
    LOCAL target IS missionTargetBody().
    mLog("Capture burn at " + target:NAME + " Pe.").
    planCapture(target, CFG["RELAY_ALT"]).
    executeManeuver().
    orbitSummary().
    nextPhase().
}

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

LOCAL FUNCTION _phaseLowerPe {
    mLog("Lowering Pe to " + ROUND(CFG["PROBE_IMPACT_PE"]/1000,1) + "km.").
    planLowerPe(CFG["PROBE_IMPACT_PE"]).
    executeManeuver().
    orbitSummary().
    nextPhase().
}

LOCAL FUNCTION _phaseReleaseProbe {
    LOCAL parts IS SHIP:PARTSTAGGED("probe_decoupler").
    IF parts:LENGTH = 0 {
        mLogError("No part tagged 'probe_decoupler'!").
        HUDTEXT("ERROR: probe_decoupler missing!", 10, 2, 18, RED, FALSE).
        RETURN.  // stay in this phase — operator must intervene
    }

    SET SAS TO TRUE.
    WAIT 1.

    LOCAL dc IS parts[0].
    IF dc:HASMODULE("ModuleDecouple") {
        dc:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
        dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogError("probe_decoupler has no decouple module.").
        RETURN.
    }

    WAIT 0.5.
    stateSet("probe_released_time", TIME:SECONDS).
    mLog("Probe released. Relay mass: " + ROUND(SHIP:MASS,2) + "t").
    nextPhase().
}

LOCAL FUNCTION _phaseRecirc {
    mLog("Re-circularizing relay at " + ROUND(CFG["RELAY_ALT"]/1000,0) + "km.").
    planRecircularize(CFG["RELAY_ALT"]).
    executeManeuver().
    orbitSummary().
    nextPhase().
}

LOCAL FUNCTION _phaseRelayOps {
    UNLOCK STEERING.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    SET SAS TO TRUE.
    orbitSummary().
    mLog("Relay on station. Mission payloads complete.").
    HUDTEXT("Relay deployed: " + MISSION["target"], 8, 2, 18, GREEN, FALSE).
    // Log orbit every 60s for 5 min then advance
    LOCAL n IS 0.
    UNTIL n >= 5 { WAIT 60. orbitSummary(). SET n TO n + 1. }
    nextPhase().
}

LOCAL FUNCTION _phaseDeploySat {
    // Placeholder for future STKSAT1 payload type
    mLog("DEPLOY_SAT: not yet implemented.").
    nextPhase().
}

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
        mLogWarn("No part tagged 'main_fairing' — skipping.").
        RETURN.
    }
    LOCAL mod IS parts[0]:GETMODULE("ModuleProceduralFairing").
    IF mod:HASEVENT("Deploy") {
        mod:DOEVENT("Deploy").
        stateSet("fairing_deployed", "true").
        mLog("Fairing deployed at " + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
    } ELSE {
        mLogWarn("Fairing Deploy event not found.").
    }
}

