// ============================================================
// FR2.ks  —  Mission: Mun Relay + Impactor  (0:/FR2.ks)
//
// Phases (persisted in state.json):
//   PARKING       — wait for stable Kerbin parking orbit
//   FAIRING       — deploy main fairing at altitude threshold
//   TMI           — plan + execute trans-Munar injection
//   MUN_COAST     — coast to Mun SOI
//   MUN_CAPTURE   — capture burn at Mun periapsis
//   CIRC_MUN      — circularize at target altitude
//   LOWER_PE      — retrograde at Ap to put probe on impact traj
//   RELEASE_PROBE — decouple probe
//   RECIRC        — relay prograde burn to re-circularize
//   RELAY_OPS     — relay station keeping, telemetry loop
//   PROBE_COAST   — probe telemetry until impact / signal loss
//   DONE          — mission complete
// ============================================================

// ============================================================
// CONFIG — edit between test launches
// ============================================================
LOCAL CFG IS LEXICON(
    "PARKING_ALT",       90000,   // m — target parking orbit altitude
    "PARKING_TOL",        2000,   // m — acceptable Pe/Ap deviation
    "FAIRING_ALT",       68000,   // m — deploy main_fairing at this altitude
    "MUN_RELAY_ALT",    500000,   // m above Mun surface — relay target orbit
    "PROBE_IMPACT_PE",    5000,   // m — lower Pe to this for impact trajectory
    "CIRC_ECC_TOL",       0.02,   // eccentricity threshold for "circular enough"
    "MANEUVER_LEAD",        10    // s — HUD warning before burn
).
// ============================================================

GLOBAL FUNCTION main {
    mLogPhase("MAIN ENTRY").
    mLog("Config: " + CFG:KEYS:JOIN(", ")).

    // Resume from persisted phase if present
    LOCAL phase IS stateGet("phase", "PARKING").
    mLog("Resuming from phase: " + phase).

    IF phase = "PARKING"      { _phaseParking().      }
    ELSE IF phase = "FAIRING"      { _phaseFairing().      }
    ELSE IF phase = "TMI"          { _phaseTMI().          }
    ELSE IF phase = "MUN_COAST"    { _phaseMunCoast().     }
    ELSE IF phase = "MUN_CAPTURE"  { _phaseMunCapture().   }
    ELSE IF phase = "CIRC_MUN"     { _phaseCircMun().      }
    ELSE IF phase = "LOWER_PE"     { _phaseLowerPe().      }
    ELSE IF phase = "RELEASE_PROBE"{ _phaseReleaseProbe(). }
    ELSE IF phase = "RECIRC"       { _phaseRecirc().       }
    ELSE IF phase = "RELAY_OPS"    { _phaseRelayOps().     }
    ELSE IF phase = "PROBE_COAST"  { _phaseProbeCoast().   }
    ELSE IF phase = "DONE"         { _phaseDone().         }
    ELSE {
        mLogError("Unknown phase: " + phase + " — defaulting to PARKING.").
        stateSet("phase", "PARKING").
        _phaseParking().
    }
}

// ── Phase: wait for stable parking orbit ──────────────────
LOCAL FUNCTION _phaseParking {
    mLogPhase("PARKING").
    stateSet("phase", "PARKING").

    // MechJeb is running ascent — we just wait for a stable orbit
    UNTIL isOrbitStable(CFG["PARKING_ALT"] - CFG["PARKING_TOL"]) {
        WAIT 5.
    }

    orbitSummary().
    mLog("Stable parking orbit confirmed.").
    // Transition — check if fairing still needs deploying
    // (If we're already past fairing alt this is a no-op resume path)
    stateSet("phase", "FAIRING").
    _phaseFairing().
}

// ── Phase: fairing deployment ──────────────────────────────
LOCAL FUNCTION _phaseFairing {
    mLogPhase("FAIRING").
    stateSet("phase", "FAIRING").

    LOCAL fairingDeployed IS stateGet("fairing_deployed", "false").
    IF fairingDeployed = "true" {
        mLog("Fairing already deployed — skipping.").
        stateSet("phase", "TMI").
        _phaseTMI().
        RETURN.
    }

    // If we're already above the fairing alt (e.g. resumed mid-ascent), deploy now
    IF SHIP:ALTITUDE >= CFG["FAIRING_ALT"] {
        _deployFairing().
        stateSet("phase", "TMI").
        _phaseTMI().
        RETURN.
    }

    // Otherwise wait for the altitude threshold
    mLog("Waiting for fairing alt: " + ROUND(CFG["FAIRING_ALT"]/1000,0) + "km").
    WAIT UNTIL SHIP:ALTITUDE >= CFG["FAIRING_ALT"].
    _deployFairing().

    stateSet("phase", "TMI").
    _phaseTMI().
}

LOCAL FUNCTION _deployFairing {
    LOCAL parts IS SHIP:PARTSTAGGED("main_fairing").
    IF parts:LENGTH = 0 {
        mLogWarn("No part tagged 'main_fairing' found — skipping fairing deploy.").
        RETURN.
    }
    LOCAL fairing IS parts[0].
    // kOS ModuleFairing event
    IF fairing:HASMODULE("ModuleProceduralFairing") {
        LOCAL mod IS fairing:GETMODULE("ModuleProceduralFairing").
        IF mod:HASEVENT("Deploy") {
            mod:DOEVENT("Deploy").
            stateSet("fairing_deployed", "true").
            mLog("Main fairing deployed at " + ROUND(SHIP:ALTITUDE/1000,1) + "km.").
        } ELSE {
            mLogWarn("Fairing module has no Deploy event.").
        }
    } ELSE {
        mLogWarn("main_fairing part has no ModuleProceduralFairing.").
    }
}

// ── Phase: Trans-Munar Injection ───────────────────────────
LOCAL FUNCTION _phaseTMI {
    mLogPhase("TMI").
    stateSet("phase", "TMI").

    orbitSummary().
    mLog("Planning TMI burn...").
    planTransferToMun().   // from maneuver.ks — adds node
    executeManeuver().

    stateSet("phase", "MUN_COAST").
    _phaseMunCoast().
}

// ── Phase: Coast to Mun SOI ────────────────────────────────
LOCAL FUNCTION _phaseMunCoast {
    mLogPhase("MUN_COAST").
    stateSet("phase", "MUN_COAST").

    mLog("Coasting to Mun SOI. Current body: " + SHIP:ORBIT:BODY:NAME).
    SET SAS TO TRUE.
    UNLOCK STEERING.

    waitForSOI(MUN).  // from orbit.ks — blocks until SOI entry
    orbitSummary().

    stateSet("phase", "MUN_CAPTURE").
    _phaseMunCapture().
}

// ── Phase: Mun capture burn ────────────────────────────────
LOCAL FUNCTION _phaseMunCapture {
    mLogPhase("MUN_CAPTURE").
    stateSet("phase", "MUN_CAPTURE").

    mLog("Planning Mun capture at Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km").
    planMunCapture(CFG["MUN_RELAY_ALT"]).
    executeManeuver().
    orbitSummary().

    stateSet("phase", "CIRC_MUN").
    _phaseCircMun().
}

// ── Phase: Circularize at relay altitude ───────────────────
LOCAL FUNCTION _phaseCircMun {
    mLogPhase("CIRC_MUN").
    stateSet("phase", "CIRC_MUN").

    IF SHIP:ORBIT:ECCENTRICITY < CFG["CIRC_ECC_TOL"] {
        mLog("Orbit already circular enough (ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,4) + ").").
    } ELSE {
        planCircularize().
        executeManeuver().
    }
    orbitSummary().

    stateSet("phase", "LOWER_PE").
    _phaseLowerPe().
}

// ── Phase: Lower Pe for probe impact trajectory ────────────
LOCAL FUNCTION _phaseLowerPe {
    mLogPhase("LOWER_PE").
    stateSet("phase", "LOWER_PE").

    mLog("Lowering Pe to " + ROUND(CFG["PROBE_IMPACT_PE"]/1000,1) + "km for probe impact.").
    planMunPeriapsisLower(CFG["PROBE_IMPACT_PE"]).
    executeManeuver().
    orbitSummary().

    stateSet("phase", "RELEASE_PROBE").
    _phaseReleaseProbe().
}

// ── Phase: Release probe ───────────────────────────────────
LOCAL FUNCTION _phaseReleaseProbe {
    mLogPhase("RELEASE_PROBE").
    stateSet("phase", "RELEASE_PROBE").

    LOCAL parts IS SHIP:PARTSTAGGED("probe_decoupler").
    IF parts:LENGTH = 0 {
        mLogError("No part tagged 'probe_decoupler' — cannot release probe!").
        HUDTEXT("ERROR: probe_decoupler tag missing!", 10, 2, 18, RED, FALSE).
        RETURN.
    }

    LOCAL decoupler IS parts[0].
    mLog("Releasing probe. Current Ap=" + ROUND(SHIP:APOAPSIS/1000,1)
        + "km Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km").

    // Brief SAS hold before decoupling so we don't impart spin
    SET SAS TO TRUE.
    WAIT 1.

    IF decoupler:HASMODULE("ModuleDecouple") {
        decoupler:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF decoupler:HASMODULE("ModuleAnchoredDecoupler") {
        decoupler:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogError("probe_decoupler has no known decouple module.").
        RETURN.
    }

    WAIT 0.5.
    mLog("Probe released. Relay mass now: " + ROUND(SHIP:MASS,2) + "t").
    stateSet("probe_released_time", TIME:SECONDS).

    stateSet("phase", "RECIRC").
    _phaseRecirc().
}

// ── Phase: Re-circularize relay ────────────────────────────
LOCAL FUNCTION _phaseRecirc {
    mLogPhase("RECIRC").
    stateSet("phase", "RECIRC").

    mLog("Re-raising Pe to " + ROUND(CFG["MUN_RELAY_ALT"]/1000,0) + "km.").
    planMunRecircularize(CFG["MUN_RELAY_ALT"]).
    executeManeuver().
    orbitSummary().

    stateSet("phase", "RELAY_OPS").
    _phaseRelayOps().
}

// ── Phase: Relay station keeping ──────────────────────────
LOCAL FUNCTION _phaseRelayOps {
    mLogPhase("RELAY_OPS").
    stateSet("phase", "RELAY_OPS").

    UNLOCK STEERING.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    SET SAS TO TRUE.

    orbitSummary().
    mLog("Relay in final orbit. SAS holding. Mission handoff to probe.").
    HUDTEXT("Relay deployed!", 8, 2, 18, GREEN, FALSE).

    // Log orbit summary every 60s for a few minutes, then hand off
    LOCAL checks IS 0.
    UNTIL checks >= 5 {
        WAIT 60.
        orbitSummary().
        SET checks TO checks + 1.
    }

    stateSet("phase", "DONE").
    _phaseDone().
}

// ── Phase: Probe coast (ballistic — telemetry only) ────────
LOCAL FUNCTION _phaseProbeCoast {
    // This phase runs on the PROBE vessel after separation.
    // Since we don't switch vessels in kOS automatically, this
    // is available for manual invocation from the probe's own
    // kOS if you've uploaded FR2.ks to the probe core.
    mLogPhase("PROBE_COAST").
    stateSet("phase", "PROBE_COAST").

    SET SAS TO TRUE.
    mLog("Probe ballistic. Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + "km  ETA=" + ROUND(ETA:PERIAPSIS,0) + "s").

    UNTIL NOT ADDONS:RT:HASKSCCONNECTION(SHIP) OR SHIP:ALTITUDE < 1000 {
        mLog("Alt=" + ROUND(SHIP:ALTITUDE/1000,1) + "km  Pe=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + "km  ETA=" + ROUND(ETA:PERIAPSIS,0) + "s").
        WAIT 10.
    }

    mLog("Signal lost or impact imminent. Telemetry end.").
    stateSet("phase", "DONE").
}

// ── Phase: Done ────────────────────────────────────────────
LOCAL FUNCTION _phaseDone {
    mLogPhase("DONE").
    stateSet("phase", "DONE").
    UNLOCK ALL.
    SET SAS TO TRUE.
    mLog("Mission FR2 complete.").
    HUDTEXT("FR2 Mission Complete", 10, 2, 20, GREEN, FALSE).
}