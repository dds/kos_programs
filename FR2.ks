// ============================================================
// FR2.ks  —  FR2 vehicle flight computer  (0:/FR2.ks)
//
// Ship name:  FR2-TARGET-TYPE1-TYPE2-...-NN
// e.g.  FR2-MUN-CRASHPROBE1-RELAY1
//       FR2-KERBIN-PROBE-RELAY-POLAR-02
//
// Recognized payload tokens: PROBE, CRASHPROBE, RELAY, SCANSAT, SCISAT
// Anything else (POLAR, 02, etc.) is ignored.
// ============================================================

GLOBAL CFG IS LEXICON(
    "PARKING_ALT",         100000,
    "LAUNCH_INCLINATION",      0,
    "LAUNCH_AZIMUTH",           0,
    "LAUNCH_STAGE_LIMIT",       0,
    "FAIRING_ALT",          68000,
    "EXTEND_ALT",           72000,
    "RELAY_ALT",           1000000,
    "CAPTURE_PE",            20000,
    "CIRC_ECC_TOL",          0.005,
    "TARGET_INCLINATION",    0,
    "INCL_MATCH_TARGET",     "",
    "INCL_TOLERANCE",        0.01,
    "MAX_INCL_CHANGE_DV",    200,
    "PROBE_TARGET_LAT",        80.0,
    "PROBE_TARGET_LNG",         0.0,
    "PROBE_ENTRY_PE",         30000,
    "PROBE_TARGET_TOL",        5000
).

GLOBAL LIBS IS LIST(
    "phases", "launch", "xfer",
    "countdown", "maneuver", "inclination",
    "orbit", "targeting"
).

LOCAL FUNCTION _normalizePayloadType {
    PARAMETER raw.
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

LOCAL FUNCTION buildPhaseSequence {
    LOCAL seq IS LIST(
        "LAUNCH",
        "FAIRING",
        "EXTEND_ANTS",
        "PARKING"
    ).
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        seq:ADD("TRANSFER").
        seq:ADD("COAST").
        seq:ADD("CAPTURE").
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

LOCAL FUNCTION _printConfig {
    LOCAL seq IS buildPhaseSequence().
    CLEARSCREEN.
    PRINT "=== FR2 MISSION CONFIG ===".
    PRINT " ".
    PRINT "Ship:      " + SHIP:NAME.
    PRINT "Target:    " + MISSION["target"].
    PRINT "Payloads:  " + MISSION["payloads"].
    PRINT " ".
    PRINT "Parking:   " + ROUND(CFG["PARKING_ALT"]/1000,0) + "km".
    PRINT "Relay alt: " + ROUND(CFG["RELAY_ALT"]/1000,0) + "km".
    PRINT "Launch inc:" + CFG["LAUNCH_INCLINATION"] + "deg".
    PRINT "Target inc:" + CFG["TARGET_INCLINATION"] + "deg".
    PRINT "Capture Pe:" + ROUND(CFG["CAPTURE_PE"]/1000,0) + "km".
    PRINT " ".
    PRINT "Sequence:".
    PRINT "  " + seq:JOIN(" -> ").
    PRINT " ".
}

LOCAL FUNCTION _confirmConfig {
    LOCAL phase IS stateGet("phase", "").
    IF phase <> "" AND phase <> "LAUNCH" {
        RETURN.
    }

    _printConfig().
    PRINT "Launching in 30s. Press ENTER to launch now.".
    PRINT "Edit CFG in terminal to change values.".
    LOCAL deadline IS TIME:SECONDS + 30.
    LOCAL confirmed IS FALSE.
    UNTIL TIME:SECONDS >= deadline OR confirmed {
        LOCAL remaining IS ROUND(deadline - TIME:SECONDS, 0).
        PRINT "  T-" + remaining + "s  " AT (0, 17).
        IF TERMINAL:INPUT:HASCHAR {
            LOCAL ch IS TERMINAL:INPUT:GETCHAR().
            IF UNCHAR(ch) = 13 OR UNCHAR(ch) = 10 {
                SET confirmed TO TRUE.
            }
        }
        WAIT 0.2.
    }
    PRINT " ".
    PRINT "Proceeding with launch.".
}

GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR2 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    mLog("Sequence: " + seq:JOIN(" -> ")).
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    _confirmConfig().

    LOCAL phaseMap IS LEXICON(
        "LAUNCH",           phaseLaunch@,
        "FAIRING",          phaseFairing@,
        "EXTEND_ANTS",      phaseExtendAnts@,
        "PARKING",          phaseParking@,
        "TRANSFER",         phaseTransfer@,
        "COAST",            phaseCoast@,
        "CAPTURE",          phaseCapture@,
        "CIRC",             phaseCirc@,
        "RAISE_ALT",        phaseRaiseAlt@,
        "INCL_CORRECT",     phaseInclCorrect@,
        "TARGETED_DEORBIT", _phaseTargetedDeorbit@,
        "RELEASE_PROBE",    _phaseReleaseProbe@,
        "RECIRC",           _phaseRecirc@,
        "RELAY_OPS",        _phaseRelayOps@,
        "DEPLOY_SAT",       _phaseDeploySat@
    ).

    runPhases(phaseMap).
}

// ── FR2-specific phases ──────────────────────────────────────

LOCAL FUNCTION _phaseTargetedDeorbit {
    IF NOT targetReachable(CFG["PROBE_TARGET_LAT"]) {
        mLogWarn("Target lat=" + CFG["PROBE_TARGET_LAT"]
            + " not reachable from inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
            + "deg — proceeding with best effort.").
    }
    targetedDeorbit().
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseReleaseProbe {
    LOCAL parts IS SHIP:PARTSTAGGED("probe_decoupler").
    IF parts:LENGTH = 0 {
        mLogError("No part tagged 'probe_decoupler' — cannot release probe.").
        HUDTEXT("ERROR: probe_decoupler missing!", 10, 2, 18, RED, FALSE).
        RETURN.
    }

    SET SAS TO TRUE.
    WAIT 1.

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
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseRecirc {
    mLog("Re-circularizing relay at " + ROUND(CFG["RELAY_ALT"]/1000,0) + "km.").
    planRecircularize(CFG["RELAY_ALT"]).
    executeManeuver().
    orbitSummary().
    nextPhase(launchSeq).
}

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
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseDeploySat {
    mLog("DEPLOY_SAT: not yet implemented.").
    nextPhase(launchSeq).
}
