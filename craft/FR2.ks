// ============================================================
// FR2.ks  —  FR2 vehicle flight computer  (0:/craft/FR2.ks)
//
// Ship name:  FR2-TARGET-TYPE1-TYPE2-...-NN
// e.g.  FR2-MUN-CRASHPROBE1-RELAY1
//       FR2-KERBIN-PROBE-RELAY-POLAR-02
//
// Recognized payload tokens: PROBE, CRASHPROBE, RELAY, SCANSAT, SCISAT, LANDER
// Anything else (POLAR, 02, etc.) is ignored.
// ============================================================

GLOBAL CFG IS LEXICON(
    "PARKING_ALT",         140000,
    "LAUNCH_INCLINATION",     270,
    "LAUNCH_AZIMUTH",           0,
    "LAUNCH_STAGE_LIMIT",       0,
    "FAIRING_ALT",          68000,
    "EXTEND_ALT",           72000,
    "RELAY_ALT",          1000000,
    "CAPTURE_PE",            20000,
    "CIRC_ECC_TOL",          0.005,
    "TARGET_INCLINATION",     63.4,
    "INCL_MATCH_TARGET",       "",
    "INCL_TOLERANCE",         0.01,
    "MAX_INCL_CHANGE_DV",     200,
    "PROBE_TARGET_LAT",       -90.0,
    "PROBE_TARGET_LNG",         0.0,
    "PROBE_ENTRY_PE",         30000,
    "PROBE_TARGET_TOL",        5000,
    "MOLNIYA_PERIOD",         10775,
    "MOLNIYA_AOP",              80,
    "MOLNIYA_ECC",               0.7
).

GLOBAL LIBS IS LIST(
    "phases", "launch", "xfer",
    "countdown", "maneuver", "inclination",
    "orbit", "targeting", "landing",
    "molniya"
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

    LOCAL hasMolniya IS FALSE.
    FOR ptype IN missionPayloads() {
        IF _normalizePayloadType(ptype) = "MOLNIYA" { SET hasMolniya TO TRUE. }
    }

    seq:ADD("CIRC").
    IF hasMolniya {
        seq:ADD("INCL_CORRECT").
        seq:ADD("MOLNIYA_INSERT").
    } ELSE {
        seq:ADD("RAISE_ALT").
        seq:ADD("INCL_CORRECT").
    }

    FOR ptype IN missionPayloads() {
        LOCAL t IS _normalizePayloadType(ptype).
        IF t = "RELAY" OR t = "SCANSAT" OR t = "SCISAT" {
            seq:ADD("RELAY_OPS").
        }
    }

    FOR ptype IN missionPayloads() {
        LOCAL t IS _normalizePayloadType(ptype).
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
    LOCAL hasProbe IS FALSE.
    LOCAL hasLander IS FALSE.
    LOCAL hasMolniya IS FALSE.
    FOR ptype IN missionPayloads() {
        LOCAL t IS _normalizePayloadType(ptype).
        IF t = "CRASHPROBE" OR t = "PROBE" { SET hasProbe TO TRUE. }
        IF t = "LANDER" { SET hasLander TO TRUE. }
        IF t = "MOLNIYA" { SET hasMolniya TO TRUE. }
    }

    CLEARSCREEN.
    PRINT "  ========================================".
    PRINT "    FR2 FLIGHT PLAN    " + SHIP:NAME.
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
    IF CFG["LAUNCH_STAGE_LIMIT"] > 0 {
        PRINT "  MJ LIMIT .. stage " + CFG["LAUNCH_STAGE_LIMIT"].
    }
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
    IF hasMolniya {
        LOCAL mu IS SHIP:ORBIT:BODY:MU.
        LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
        LOCAL mPeAlt IS SHIP:PERIAPSIS.
        IF mPeAlt < 0 { SET mPeAlt TO CFG["PARKING_ALT"]. }
        LOCAL mPeR IS bodyR + mPeAlt.
        LOCAL mSMA IS 0.
        LOCAL mp IS CFG["MOLNIYA_PERIOD"].
        LOCAL mEcc IS 0.
        LOCAL modeStr IS "period".
        IF CFG:HASKEY("MOLNIYA_ECC") AND CFG["MOLNIYA_ECC"] > 0 {
            SET mEcc TO CFG["MOLNIYA_ECC"].
            SET mSMA TO mPeR / (1 - mEcc).
            SET mp TO 2 * CONSTANT:PI * SQRT(mSMA^3 / mu).
            SET modeStr TO "ecc".
        } ELSE {
            SET mSMA TO (mu * (mp / (2 * CONSTANT:PI))^2)^(1/3).
            SET mEcc TO 1 - mPeR / mSMA.
        }
        LOCAL mh IS FLOOR(mp / 3600).
        LOCAL mm IS FLOOR(MOD(mp, 3600) / 60).
        LOCAL ms IS ROUND(MOD(mp, 60), 0).
        LOCAL mAp IS 2 * mSMA - mPeR - bodyR.
        LOCAL dwell IS "North".
        IF CFG["MOLNIYA_AOP"] <= 180 { SET dwell TO "South". }
        PRINT " ".
        PRINT "  -- MOLNIYA (" + modeStr + ") --".
        PRINT "  PERIOD .... " + mh + "h" + ("" + mm):PADLEFT(2) + "m" + ("" + ms):PADLEFT(2) + "s".
        PRINT "  AoP ....... " + CFG["MOLNIYA_AOP"] + " deg  (" + dwell + " dwell)".
        PRINT "  TARGET Ap . " + ROUND(mAp/1000,0) + " km".
        PRINT "  TARGET ecc  " + ROUND(mEcc,4).
    }
    IF hasProbe {
        PRINT " ".
        PRINT "  -- PROBE --".
        PRINT "  IMPACT ..... " + ROUND(CFG["PROBE_TARGET_LAT"],1) + " lat  " + ROUND(CFG["PROBE_TARGET_LNG"],1) + " lng".
        PRINT "  ENTRY PE ... " + ROUND(CFG["PROBE_ENTRY_PE"]/1000,0) + " km".
        PRINT "  TOLERANCE .. " + ROUND(CFG["PROBE_TARGET_TOL"]/1000,0) + " km".
    }
    IF hasLander {
        PRINT " ".
        PRINT "  -- LANDING --".
        PRINT "  TARGET ..... " + ROUND(LANDING_CFG["TARGET_LAT"],4) + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng".
        PRINT "  DEORBIT PE . " + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + " km".
    }
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
        "MOLNIYA_INSERT",   phaseMolniyaInsert@,
        "TARGETED_DEORBIT", _phaseTargetedDeorbit@,
        "RELEASE_PROBE",    _phaseReleaseProbe@,
        "RECIRC",           _phaseRecirc@,
        "RELAY_OPS",        _phaseRelayOps@,
        "DEPLOY_SAT",       _phaseDeploySat@,
        "LAND_DEORBIT",     _phaseLandDeorbit@,
        "LAND",             _phaseLand@
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

LOCAL FUNCTION _hasFixedPanels {
    PARAMETER dc.
    LOCAL probeChildren IS dc:CHILDREN.
    LOCAL bfsQ IS LIST().
    FOR ch IN probeChildren { bfsQ:ADD(ch). }
    UNTIL bfsQ:LENGTH = 0 {
        LOCAL p IS bfsQ[0].
        bfsQ:REMOVE(0).
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL m IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF NOT m:HASEVENT("Extend Solar Panel")
                AND NOT m:HASEVENT("Retract Solar Panel")
                AND NOT m:HASEVENT("Toggle Solar Panel") {
                RETURN TRUE.
            }
        }
        FOR ch IN p:CHILDREN { bfsQ:ADD(ch). }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _phaseReleaseProbe {
    LOCAL parts IS SHIP:PARTSTAGGED("probe_decoupler").
    IF parts:LENGTH = 0 {
        mLogError("No part tagged 'probe_decoupler' — cannot release probe.").
        HUDTEXT("ERROR: probe_decoupler missing!", 10, 2, 18, RED, FALSE).
        RETURN.
    }

    IF _hasFixedPanels(parts[0]) {
        mLog("Fixed solar panels detected — orienting sunward.").
        HUDTEXT("Orienting for solar panels...", 3, 2, 13, CYAN, FALSE).
        LOCK sunDir TO (SUN:POSITION - SHIP:POSITION):NORMALIZED.
        LOCK STEERING TO sunDir.
        LOCAL alignDeadline IS TIME:SECONDS + 60.
        WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, sunDir) < 5
            OR TIME:SECONDS > alignDeadline.
        mLog("Sun angle: " + ROUND(VANG(SHIP:FACING:FOREVECTOR, sunDir), 1) + "deg.").
        UNLOCK STEERING.
        UNLOCK sunDir.
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

LOCAL FUNCTION _phaseLandDeorbit {
    landingTargetedDeorbit().
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseLand {
    landingExecute().
    nextPhase(launchSeq).
}
