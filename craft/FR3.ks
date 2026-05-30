// ============================================================
// FR3.ks  —  FR3 vehicle flight computer  (0:/craft/FR3.ks)
//
// Next-gen rocket. Leaner than FR2 — no probe/molniya phases.
// Ship name:  FR3-TARGET-TYPE1-TYPE2-...-NN
// Payload tokens: RELAY, SCANSAT, SCISAT, LANDER
// ============================================================

GLOBAL CFG IS LEXICON(
    "PARKING_ALT",         120000,
    "LAUNCH_INCLINATION",       90,
    "LAUNCH_AZIMUTH",           0,
    "LAUNCH_STAGE_LIMIT",       0,
    "FAIRING_ALT",          68000,
    "EXTEND_ALT",           72000,
    "RELAY_ALT",           1000000,
    "CAPTURE_PE",            20000,
    "CIRC_ECC_TOL",          0.005,
    "TARGET_INCLINATION",      90,
    "INCL_MATCH_TARGET",       "",
    "INCL_TOLERANCE",         0.01,
    "MAX_INCL_CHANGE_DV",     200
).

GLOBAL LIBS IS LIST(
    "phases", "launch", "xfer",
    "countdown", "maneuver", "inclination",
    "orbit"
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
    seq:ADD("CIRC").
    seq:ADD("RAISE_ALT").
    seq:ADD("INCL_CORRECT").

    FOR ptype IN missionPayloads() {
        LOCAL t IS _normalizePayloadType(ptype).
        IF t = "RELAY" OR t = "SCANSAT" OR t = "SCISAT" {
            seq:ADD("OPS").
        }
        IF t = "LANDER" {
            seq:ADD("LAND_DEORBIT").
            seq:ADD("LAND").
        }
    }
    seq:ADD("DONE").
    RETURN seq.
}

LOCAL FUNCTION _printConfig {
    LOCAL seq IS buildPhaseSequence().
    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "    FR3 FLIGHT PLAN    " + SHIP:NAME.
    PRINT "  ========================================".
    PRINT " ".
    PRINT "  TARGET ..... " + MISSION["target"].
    PRINT "  PAYLOADS ... " + MISSION["payloads"].
    PRINT " ".
    PRINT "  -- ASCENT --".
    PRINT "  PARK ALT ... " + ROUND(CFG["PARKING_ALT"]/1000,0) + " km".
    LOCAL incStr IS CFG["LAUNCH_INCLINATION"] + " deg".
    IF CFG["LAUNCH_INCLINATION"] = 0 { SET incStr TO "0 deg  (equatorial)". }
    PRINT "  INCL ...... " + incStr.
    PRINT "  FAIRING ... " + ROUND(CFG["FAIRING_ALT"]/1000,0) + " km".
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        PRINT " ".
        PRINT "  -- TRANSFER --".
        PRINT "  CAPTURE PE . " + ROUND(CFG["CAPTURE_PE"]/1000,0) + " km".
    }
    PRINT " ".
    PRINT "  -- ORBIT --".
    PRINT "  FINAL ALT .. " + ROUND(CFG["RELAY_ALT"]/1000,0) + " km".
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    PRINT "  FINAL INCL . " + tincStr.
    PRINT "  CIRC TOL ... ecc < " + CFG["CIRC_ECC_TOL"].
    PRINT " ".
    PRINT "  -- SEQUENCE --".
    LOCAL i IS 0.
    UNTIL i >= seq:LENGTH {
        LOCAL line IS "  ".
        LOCAL j IS i.
        UNTIL j >= seq:LENGTH OR line:LENGTH > 42 {
            IF j > i { SET line TO line + " > ". }
            SET line TO line + seq[j].
            SET j TO j + 1.
        }
        PRINT line.
        SET i TO j.
    }
    PRINT " ".
    PRINT "  ========================================".
}

LOCAL FUNCTION _confirmConfig {
    LOCAL phase IS stateGet("phase", "").
    IF phase <> "" AND phase <> "LAUNCH" {
        RETURN.
    }

    _printConfig().
    PRINT "  >> ENTER to launch / 30s auto-launch".
    PRINT "  >> Edit CFG in terminal to override".
    PRINT " ".
    LOCAL deadline IS TIME:SECONDS + 30.
    LOCAL confirmed IS FALSE.
    UNTIL TIME:SECONDS >= deadline OR confirmed {
        LOCAL remaining IS ROUND(deadline - TIME:SECONDS, 0).
        LOCAL bar IS "".
        LOCAL filled IS ROUND(30 - remaining, 0).
        LOCAL j IS 0.
        UNTIL j >= 30 {
            IF j < filled { SET bar TO bar + "=". }
            ELSE { SET bar TO bar + ".". }
            SET j TO j + 1.
        }
        PRINT "  [" + bar + "] T-" + ("" + remaining):PADLEFT(2) + "s   " AT (0, TERMINAL:HEIGHT - 1).
        IF TERMINAL:INPUT:HASCHAR {
            LOCAL ch IS TERMINAL:INPUT:GETCHAR().
            IF UNCHAR(ch) = 13 OR UNCHAR(ch) = 10 {
                SET confirmed TO TRUE.
            }
        }
        WAIT 0.2.
    }
    PRINT "  [==============================] GO       " AT (0, TERMINAL:HEIGHT - 1).
}

GLOBAL FUNCTION main {
    LOCAL seq IS buildPhaseSequence().
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FR3 MAIN").
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
        "OPS",              _phaseOps@,
        "LAND_DEORBIT",     _phaseLandDeorbit@,
        "LAND",             _phaseLand@
    ).

    runPhases(phaseMap).
}

LOCAL FUNCTION _phaseOps {
    UNLOCK STEERING.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    SET SAS TO TRUE.
    orbitSummary().
    mLog("On station at " + MISSION["target"] + ".").
    HUDTEXT("Deployed: " + MISSION["target"], 8, 2, 18, GREEN, FALSE).
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseLandDeorbit {
    mLog("LAND_DEORBIT: not yet implemented.").
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseLand {
    mLog("LAND: not yet implemented.").
    nextPhase(launchSeq).
}
