// ============================================================
// science.ks  —  Science collection library  (0:/lib/science.ks)
// ============================================================

GLOBAL SCI_CFG IS LEXICON(
    "AUTO_COLLECT",       TRUE,
    "AUTO_TRANSMIT",      FALSE,
    "ALERT_ON_CHANGE",    TRUE,
    "TRANSMIT_THRESHOLD", 0,
    "SCANSAT_AUTO",       TRUE,
    "LOG_INTERVAL",       60
).

GLOBAL scienceActive    IS FALSE.
GLOBAL sciLastBiome     IS "".
GLOBAL sciLastSituation IS "".


GLOBAL FUNCTION scienceInit {
    SET scienceActive TO TRUE.

    IF ADDONS:SCANSAT:AVAILABLE {
        SET sciLastBiome TO ADDONS:SCANSAT:GETBIOME(SHIP:BODY, SHIP:GEOPOSITION).
    } ELSE {
        SET sciLastBiome TO "unknown".
    }
    SET sciLastSituation TO SHIP:STATUS.

    mLog("Science monitor active. Starting Biome=" + sciLastBiome).

    // Set up a pacing clock
    LOCAL checkInterval IS 5. // Check every 5 seconds
    LOCAL nextCheck IS TIME:SECONDS + checkInterval.

    // This trigger now sleeps for 250 frames at a time!
    WHEN scienceActive AND TIME:SECONDS > nextCheck THEN {
        SET nextCheck TO TIME:SECONDS + checkInterval. // Reset clock

        LOCAL currentBiome IS "unknown".
        IF ADDONS:SCANSAT:AVAILABLE {
            SET currentBiome TO ADDONS:SCANSAT:GETBIOME(SHIP:BODY, SHIP:GEOPOSITION).
        }
        LOCAL currentSit IS SHIP:STATUS.

        IF (currentBiome <> sciLastBiome OR currentSit <> sciLastSituation) {
            // ... (keep all your existing science collection/logging logic here) ...
        }

        IF scienceActive {
            PRESERVE.
        }
    }
}

GLOBAL FUNCTION scienceShutdown {
    SET scienceActive TO FALSE.
    mLog("Science monitor deactivated.").
}

GLOBAL FUNCTION scienceRunAll {
    LOCAL ran     IS 0.
    LOCAL skipped IS 0.

    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleScienceExperiment") {
            LOCAL result IS _runExperiment(p, "ModuleScienceExperiment").
            IF result { SET ran TO ran + 1. }
            ELSE      { SET skipped TO skipped + 1. }
        }
        IF p:HASMODULE("DMModuleScienceAnimate") {
            LOCAL result IS _runExperiment(p, "DMModuleScienceAnimate").
            IF result { SET ran TO ran + 1. }
            ELSE      { SET skipped TO skipped + 1. }
        }
        IF p:HASMODULE("DMBasicScienceModule") {
            LOCAL result IS _runExperiment(p, "DMBasicScienceModule").
            IF result { SET ran TO ran + 1. }
            ELSE      { SET skipped TO skipped + 1. }
        }
    }

    mLog("Science run complete: " + ran + " ran, " + skipped + " skipped/unavailable.").
    HUDTEXT("Science: " + ran + " experiments run", 3, 2, 13, GREEN, FALSE).
    RETURN ran.
}

GLOBAL FUNCTION scienceTransmitAll {
    LOCAL transmitted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleScienceContainer") {
            LOCAL modu IS p:GETMODULE("ModuleScienceContainer").
            IF modu:HASEVENT("Transmit Data") {
                modu:DOEVENT("Transmit Data").
                SET transmitted TO transmitted + 1.
                mLog("Transmitting science from " + p:NAME).
            }
        }
        IF p:HASMODULE("ModuleDataTransmitter") {
            LOCAL modu IS p:GETMODULE("ModuleDataTransmitter").
            IF modu:HASEVENT("Transmit Data") {
                modu:DOEVENT("Transmit Data").
                SET transmitted TO transmitted + 1.
            }
        }
    }
    mLog("Science transmission: " + transmitted + " parts transmitting.").
    RETURN transmitted.
}

GLOBAL FUNCTION scienceStatus {
    // FIXED: Swapped out SHIP:BIOME and SHIP:SITUATION to prevent crashes
    mLog("Science status:"
        + "  body="      + SHIP:ORBIT:BODY:NAME
        + "  biome="     + sciLastBiome
        + "  situation=" + SHIP:STATUS).

    LOCAL available IS 0.
    LOCAL deployed  IS 0.
    LOCAL inoperable IS 0.

    FOR p IN SHIP:PARTS {
        FOR modName IN LIST("ModuleScienceExperiment",
                            "DMModuleScienceAnimate",
                            "DMBasicScienceModule") {
            IF p:HASMODULE(modName) {
                LOCAL modu IS p:GETMODULE(modName).
                // FIXED: Changed 'mod' references to 'modu'
                IF modu:HASFIELD("Deployed") AND modu:GETFIELD("Deployed") = "True" {
                    SET deployed TO deployed + 1.
                } ELSE IF modu:HASFIELD("Inoperable") AND modu:GETFIELD("Inoperable") = "True" {
                    SET inoperable TO inoperable + 1.
                } ELSE IF _experimentAvailable(modu) {
                    SET available TO available + 1.
                }
            }
        }
    }

    mLog("  Experiments: " + available + " available  "
        + deployed + " deployed  "
        + inoperable + " inoperable").

    IF ADDONS:SCANSAT:AVAILABLE {
        scienceScanStatus().
    }
}

GLOBAL FUNCTION scienceCollectAll {
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleScienceExperiment") {
            LOCAL modu IS p:GETMODULE("ModuleScienceExperiment").
            IF modu:HASEVENT("Collect Data") { modu:DOEVENT("Collect Data"). }
            IF modu:HASEVENT("Reset Experiment") { modu:DOEVENT("Reset Experiment"). }
        }
    }
    mLog("All experiments collected/reset.").
}

GLOBAL FUNCTION scienceStartScanners {
    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("SCANsat not available.").
        RETURN.
    }
    // Event names drift across SCANsat versions — match any event
    // containing start+scan instead of guessing exact strings
    // (flight-found: the hardcoded list fired nothing on modules
    // that were demonstrably off). When a module matches nothing,
    // its real event names are dumped to the log.
    LOCAL started IS 0.
    LOCAL found IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("SCANsat") {
            SET found TO found + 1.
            LOCAL modu IS p:GETMODULE("SCANsat").
            LOCAL fired IS FALSE.
            FOR evName IN modu:ALLEVENTNAMES {
                LOCAL evLower IS evName:TOLOWER.
                IF evLower:CONTAINS("start") AND evLower:CONTAINS("scan") {
                    modu:DOEVENT(evName).
                    SET started TO started + 1.
                    SET fired TO TRUE.
                }
            }
            IF NOT fired {
                mLog("SCANsat module on " + p:TITLE + " events: "
                    + modu:ALLEVENTNAMES:JOIN(" | ")).
            }
        }
    }
    mLog("SCANsat: " + found + " module(s), " + started
        + " start event(s) fired.").
    IF found = 0 {
        mLogWarn("No SCANsat modules on this vessel — is the CPU on"
            + " the carrier instead of the mapper?").
    }
    HUDTEXT("SCANsat scanning started", 3, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION scienceStopScanners {
    IF NOT ADDONS:SCANSAT:AVAILABLE { RETURN. }
    LOCAL stopped IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("SCANsat") {
            LOCAL modu IS p:GETMODULE("SCANsat").
            FOR evName IN modu:ALLEVENTNAMES {
                LOCAL evLower IS evName:TOLOWER.
                IF evLower:CONTAINS("stop") AND evLower:CONTAINS("scan") {
                    modu:DOEVENT(evName).
                    SET stopped TO stopped + 1.
                }
            }
        }
    }
    mLog("SCANsat: " + stopped + " stop event(s) fired.").
}

// Coverage per scan type from the Kos-Scansat addon:
// GETCOVERAGE(body, type) returns 0-100. -1 list = unavailable.
GLOBAL FUNCTION scienceScanCoverage {
    LOCAL cov IS LEXICON().
    IF NOT ADDONS:SCANSAT:AVAILABLE { RETURN cov. }
    LOCAL typesRaw IS ADDONS:SCANSAT:ALLSCANTYPES.
    IF typesRaw:ISTYPE("List") {
        FOR t IN typesRaw {
            cov:ADD(t, ADDONS:SCANSAT:GETCOVERAGE(SHIP:BODY, t)).
        }
    }
    RETURN cov.
}

GLOBAL FUNCTION scienceScanStatus {
    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("SCANsat not available.").
        RETURN.
    }
    LOCAL line IS "".
    LOCAL cov IS scienceScanCoverage().
    FOR t IN cov:KEYS {
        IF cov[t] > 0 { SET line TO line + t + "=" + ROUND(cov[t], 1) + "% ". }
    }
    IF line = "" { SET line TO "none yet". }
    mLog("Scan coverage @ " + SHIP:BODY:NAME + ": " + line:TRIM).
    mLogWarn("STATS scansat coverage body=" + SHIP:BODY:NAME
        + " " + line:TRIM).
}

GLOBAL FUNCTION scienceScanLoop {
    UNTIL NOT scienceActive {
        scienceScanStatus().
        WAIT SCI_CFG["LOG_INTERVAL"].
    }
}

LOCAL FUNCTION _runExperiment {
    PARAMETER part.
    PARAMETER modName.

    LOCAL modu IS part:GETMODULE(modName).

    IF NOT _experimentAvailable(modu) { RETURN FALSE. }

    LOCAL runEvents IS LIST(
        "Deploy Experiment",
        "Run Experiment",
        "Collect Data",
        "Observe",
        "Log Data",
        "Take Data"
    ).

    FOR evt IN runEvents {
        // FIXED: Changed 'mod' to 'modu' to match the declared local variable
        IF modu:HASEVENT(evt) {
            modu:DOEVENT(evt).
            
            // FIXED: Swapped out broken suffixes for global tracked variables
            mLog("Science: ran '" + evt + "' on " + part:NAME
                + "  biome=" + sciLastBiome
                + "  situation=" + SHIP:STATUS).

            IF SCI_CFG["AUTO_TRANSMIT"] {
                WAIT 1.
                IF modu:HASEVENT("Transmit Data") { modu:DOEVENT("Transmit Data"). }
            }
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _experimentAvailable {
    PARAMETER modu.
    IF modu:HASFIELD("Inoperable") AND modu:GETFIELD("Inoperable") = "True" { RETURN FALSE. }
    IF modu:HASFIELD("Deployed")   AND modu:GETFIELD("Deployed")   = "True" { RETURN FALSE. }
    LOCAL runEvents IS LIST(
        "Deploy Experiment", "Run Experiment",
        "Collect Data", "Observe", "Log Data", "Take Data"
    ).
    FOR evt IN runEvents {
        IF modu:HASEVENT(evt) { RETURN TRUE. }
    }
    RETURN FALSE.
}

// ============================================================
// phaseEvaScience — placeholder handler. The EVA science mission
// flow isn't built yet (kOS there is expected to do little more
// than boot and log); this exists so the phase binds instead of
// crashing the binder wherever science+orbit happen to be loaded
// (flight-found via the scansat band). Logs and yields to the
// operator; advance manually with setphase when done.
// ============================================================
GLOBAL FUNCTION phaseEvaScience {
    mLog("EVA_SCIENCE: no automated flow yet — manual ops.").
    mLog("Advance with: RUNPATH('1:/cmd/setphase', '<next>').").
    yieldToPrompt().
}

// ============================================================
// scansatDutyCycle — duty-cycle the scanners on battery state:
// OFF below SCANSAT_POWER_LOW (30%), ON above
// SCANSAT_POWER_RESUME (60%). Charge on the held solar attitude,
// scan in bursts, repeat until the map is done. Survives time
// warp (game-time waits, no warp-killing alarms) so 5-10x grinds
// out full coverage. AG10 ends the cycle and continues the
// sequence with the scanners left ON.
// ============================================================
GLOBAL FUNCTION scansatDutyCycle {
    LOCAL lowFrac IS 0.30.
    LOCAL resumeFrac IS 0.60.
    IF CFG:HASKEY("SCANSAT_POWER_LOW") { SET lowFrac TO CFG["SCANSAT_POWER_LOW"]. }
    IF CFG:HASKEY("SCANSAT_POWER_RESUME") { SET resumeFrac TO CFG["SCANSAT_POWER_RESUME"]. }
    mLog("Scan duty cycle: OFF below " + ROUND(lowFrac * 100, 0)
        + "%, ON above " + ROUND(resumeFrac * 100, 0)
        + "%. AG10 ends the cycle. Warp away.").

    // Active scan types are detected empirically: whichever
    // types' coverage RISES after the cycle starts is what our
    // scanners collect. When every active type reaches
    // SCANSAT_TARGET_COVERAGE (95%), the map is done — scanners
    // off, cycle ends itself.
    LOCAL targetCov IS 95.
    IF CFG:HASKEY("SCANSAT_TARGET_COVERAGE") {
        SET targetCov TO CFG["SCANSAT_TARGET_COVERAGE"].
    }
    LOCAL baseline IS scienceScanCoverage().
    LOCAL active IS LIST().
    LOCAL mapDone IS FALSE.

    // Deterministic start: the scanners may be on OR off when the
    // phase begins — force them OFF so the bookkeeping matches
    // reality, then the loop brings them up the moment the charge
    // is above the resume threshold (immediately, when entering
    // with a healthy battery).
    scienceStopScanners().
    LOCAL scansOn IS FALSE.
    LOCAL nextStatus IS TIME:SECONDS + 600.
    UNTIL AG10 OR mapDone {
        LOCAL frac IS shipPowerFraction().
        IF scansOn AND frac < lowFrac {
            scienceStopScanners().
            SET scansOn TO FALSE.
            mLog("Scans OFF at " + ROUND(frac * 100, 0) + "% — charging.").
            HUDTEXT("Scans off — charging ("
                + ROUND(frac * 100, 0) + "%)", 8, 2, 15, YELLOW, FALSE).
        } ELSE IF NOT scansOn AND frac > resumeFrac {
            scienceStartScanners().
            SET scansOn TO TRUE.
            mLog("Scans ON at " + ROUND(frac * 100, 0) + "%.").
            HUDTEXT("Scans on ("
                + ROUND(frac * 100, 0) + "%)", 8, 2, 15, GREEN, FALSE).
        }
        IF TIME:SECONDS > nextStatus {
            SET nextStatus TO TIME:SECONDS + 600.
            mLogWarn("STATS scansat duty charge=" + ROUND(frac * 100, 1)
                + "pct scans=" + scansOn
                + " flow=" + ROUND(shipSolarFlow(), 2)).
            scienceScanStatus().

            LOCAL cov IS scienceScanCoverage().
            FOR t IN cov:KEYS {
                IF baseline:HASKEY(t) AND cov[t] > baseline[t] + 0.05
                        AND NOT active:CONTAINS(t) {
                    active:ADD(t).
                    mLog("Active scan type detected: " + t + ".").
                }
            }
            IF active:LENGTH > 0 {
                SET mapDone TO TRUE.
                FOR t IN active {
                    IF cov[t] < targetCov { SET mapDone TO FALSE. }
                }
            }
        }
        WAIT 2.
    }
    IF mapDone {
        scienceStopScanners().
        mLog("Mapping COMPLETE: all active scan types >= "
            + ROUND(targetCov, 0) + "% — scanners off, continuing.").
        mLogWarn("STATS scansat duty result=complete types="
            + active:JOIN(",")).
        HUDTEXT("Mapping complete", 10, 2, 18, GREEN, FALSE).
    } ELSE {
        scienceStartScanners().
        mLog("Duty cycle ended (AG10) — scanners left ON, continuing.").
    }
}
