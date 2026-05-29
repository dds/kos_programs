// ============================================================
// science.ks  —  Science collection library  (0:/lib/science.ks)
//
// Three layers:
//   1. Experiment runner — finds, checks, runs, stores/transmits
//   2. Situation monitor — WHEN trigger for biome/situation changes
//   3. SCANsat integration — scanner management and coverage reporting
//
// Usage:
//   RUNPATH("1:/lib/science.ks").
//   scienceInit().              -- call once, arms situation monitor
//   scienceRunAll().            -- run all available experiments now
//   scienceStatus().            -- log what's available/collected
//   scienceStartScanners().     -- enable all SCANsat scanners
//   scienceScanStatus().        -- log SCANsat coverage %
// ============================================================

// ── Config ─────────────────────────────────────────────────
GLOBAL SCI_CFG IS LEXICON(
    "AUTO_COLLECT",       TRUE,   // auto-run experiments on situation change
    "AUTO_TRANSMIT",      FALSE,  // transmit immediately vs store for recovery
    "ALERT_ON_CHANGE",    TRUE,   // HUDTEXT alert on biome/situation change
    "TRANSMIT_THRESHOLD", 0,      // only transmit if science value > this
    "SCANSAT_AUTO",       TRUE,   // auto-enable scanners on orbital insertion
    "LOG_INTERVAL",       60      // seconds between periodic science checks
).

// ── State ──────────────────────────────────────────────────
GLOBAL scienceActive    IS FALSE.
GLOBAL sciLastBiome     IS "".
GLOBAL sciLastSituation IS "".

// ── Init + situation monitor ───────────────────────────────

GLOBAL FUNCTION scienceInit {
    SET scienceActive    TO TRUE.
    SET sciLastBiome     TO SHIP:BIOME.
    SET sciLastSituation TO SHIP:SITUATION.

    mLog("Science monitor active. Biome=" + sciLastBiome
        + "  Situation=" + sciLastSituation).

    // SCANsat auto-start if configured and available
    IF SCI_CFG["SCANSAT_AUTO"] AND ADDONS:SCANSAT:AVAILABLE {
        scienceStartScanners().
    }

    // ── Situation/biome change trigger ─────────────────────
    WHEN scienceActive AND
            (SHIP:BIOME <> sciLastBiome OR SHIP:SITUATION <> sciLastSituation) THEN {

        LOCAL newBiome IS SHIP:BIOME.
        LOCAL newSit   IS SHIP:SITUATION.

        mLog("Science: situation change"
            + "  biome: " + sciLastBiome + " → " + newBiome
            + "  situation: " + sciLastSituation + " → " + newSit).

        IF SCI_CFG["ALERT_ON_CHANGE"] {
            HUDTEXT("New science: " + newBiome + " / " + newSit,
                4, 2, 14, CYAN, FALSE).
        }

        SET sciLastBiome     TO newBiome.
        SET sciLastSituation TO newSit.

        IF SCI_CFG["AUTO_COLLECT"] {
            scienceRunAll().
        }

        PRESERVE.  // re-arm trigger
    }
}

GLOBAL FUNCTION scienceShutdown {
    SET scienceActive TO FALSE.
    mLog("Science monitor deactivated.").
}

// ── Experiment runner ──────────────────────────────────────

GLOBAL FUNCTION scienceRunAll {
    // Run all available experiments on the vessel.
    LOCAL ran     IS 0.
    LOCAL skipped IS 0.

    FOR p IN SHIP:PARTS {
        // Stock science experiments
        IF p:HASMODULE("ModuleScienceExperiment") {
            LOCAL result IS _runExperiment(p, "ModuleScienceExperiment").
            IF result { SET ran TO ran + 1. }
            ELSE      { SET skipped TO skipped + 1. }
        }
        // DMagic and other modded experiments
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
    // Transmit all stored science data.
    LOCAL transmitted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleScienceContainer") {
            LOCAL myMod IS p:GETMODULE("ModuleScienceContainer").
            IF myMod:HASEVENT("Transmit Data") {
                myMod:DOEVENT("Transmit Data").
                SET transmitted TO transmitted + 1.
                mLog("Transmitting science from " + p:NAME).
            }
        }
        IF p:HASMODULE("ModuleDataTransmitter") {
            LOCAL myMod IS p:GETMODULE("ModuleDataTransmitter").
            IF myMod:HASEVENT("Transmit Data") {
                myMod:DOEVENT("Transmit Data").
                SET transmitted TO transmitted + 1.
            }
        }
    }
    mLog("Science transmission: " + transmitted + " parts transmitting.").
    RETURN transmitted.
}

GLOBAL FUNCTION scienceStatus {
    // Log current science situation and available experiments.
    mLog("Science status:"
        + "  body="      + SHIP:ORBIT:BODY:NAME
        + "  biome="     + SHIP:BIOME
        + "  situation=" + SHIP:SITUATION).

    LOCAL available IS 0.
    LOCAL deployed  IS 0.
    LOCAL inoperable IS 0.

    FOR p IN SHIP:PARTS {
        FOR modName IN LIST("ModuleScienceExperiment",
                            "DMModuleScienceAnimate",
                            "DMBasicScienceModule") {
            IF p:HASMODULE(modName) {
                LOCAL mod IS p:GETMODULE(modName).
                IF mod:HASFIELD("Deployed") AND mod:GETFIELD("Deployed") = "True" {
                    SET deployed TO deployed + 1.
                } ELSE IF mod:HASFIELD("Inoperable") AND mod:GETFIELD("Inoperable") = "True" {
                    SET inoperable TO inoperable + 1.
                } ELSE IF _experimentAvailable(mod) {
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
    // Collect/reset all deployed experiments into science container.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleScienceExperiment") {
            LOCAL mod IS p:GETMODULE("ModuleScienceExperiment").
            IF mod:HASEVENT("Collect Data") { mod:DOEVENT("Collect Data"). }
            IF mod:HASEVENT("Reset Experiment") { mod:DOEVENT("Reset Experiment"). }
        }
    }
    mLog("All experiments collected/reset.").
}

// ── SCANsat integration ────────────────────────────────────

GLOBAL FUNCTION scienceStartScanners {
    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("SCANsat not available.").
        RETURN.
    }
    LOCAL started IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("SCANsat") {
            LOCAL mod IS p:GETMODULE("SCANsat").
            IF mod:HASEVENT("Start RADAR Scan")    { mod:DOEVENT("Start RADAR Scan").    SET started TO started + 1. }
            IF mod:HASEVENT("Start SAR Scan")      { mod:DOEVENT("Start SAR Scan").      SET started TO started + 1. }
            IF mod:HASEVENT("Start Altimetry Scan"){ mod:DOEVENT("Start Altimetry Scan").SET started TO started + 1. }
            IF mod:HASEVENT("Start Biome Scan")    { mod:DOEVENT("Start Biome Scan").    SET started TO started + 1. }
            IF mod:HASEVENT("Start Anomaly Scan")  { mod:DOEVENT("Start Anomaly Scan").  SET started TO started + 1. }
        }
        // Generic fallback
        IF p:HASMODULE("SCANsat") {
            LOCAL mod IS p:GETMODULE("SCANsat").
            IF mod:HASEVENT("Start Scan") { mod:DOEVENT("Start Scan"). SET started TO started + 1. }
        }
    }
    mLog("SCANsat: " + started + " scanners started.").
    HUDTEXT("SCANsat scanning started", 3, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION scienceStopScanners {
    IF NOT ADDONS:SCANSAT:AVAILABLE { RETURN. }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("SCANsat") {
            LOCAL mod IS p:GETMODULE("SCANsat").
            IF mod:HASEVENT("Stop Scan") { mod:DOEVENT("Stop Scan"). }
        }
    }
    mLog("SCANsat: all scanners stopped.").
}

GLOBAL FUNCTION scienceScanStatus {
    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("SCANsat not available.").
        RETURN.
    }
    LOCAL body IS SHIP:ORBIT:BODY.
    // ADDONS:SCANSAT coverage functions
    LOCAL altCoverage  IS 0.
    LOCAL biomCoverage IS 0.
    // Try to get coverage percentages — these are the kOS SCANsat addon functions
    // Requires SCANsat kOS addon installed in GameData
    IF ADDONS:SCANSAT:AVAILABLE {
        SET altCoverage  TO ADDONS:SCANSAT:COVERAGE(body, "Altimetry").
        SET biomCoverage TO ADDONS:SCANSAT:COVERAGE(body, "Biome").
    }
    mLog("SCANsat coverage " + body:NAME + ":"
        + "  altimetry="  + ROUND(altCoverage,1)  + "%"
        + "  biome="      + ROUND(biomCoverage,1) + "%").
    HUDTEXT("Scan: alt=" + ROUND(altCoverage,0) + "% bio=" + ROUND(biomCoverage,0) + "%",
        3, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION scienceScanLoop {
    // Periodic scan status loop — call in coast/relay ops phase.
    // Logs coverage every LOG_INTERVAL seconds until scienceActive = FALSE.
    UNTIL NOT scienceActive {
        scienceScanStatus().
        WAIT SCI_CFG["LOG_INTERVAL"].
    }
}

// ── Private helpers ────────────────────────────────────────

LOCAL FUNCTION _runExperiment {
    PARAMETER part.
    PARAMETER modName.

    LOCAL mod IS part:GETMODULE(modName).

    IF NOT _experimentAvailable(mod) { RETURN FALSE. }

    // Try known run event names in order
    LOCAL runEvents IS LIST(
        "Deploy Experiment",
        "Run Experiment",
        "Collect Data",
        "Observe",
        "Log Data",
        "Take Data"
    ).

    FOR evt IN runEvents {
        IF mod:HASEVENT(evt) {
            mod:DOEVENT(evt).
            mLog("Science: ran '" + evt + "' on " + part:NAME
                + "  biome=" + SHIP:BIOME
                + "  situation=" + SHIP:SITUATION).

            IF SCI_CFG["AUTO_TRANSMIT"] {
                WAIT 1.  // give experiment time to complete
                IF mod:HASEVENT("Transmit Data") { mod:DOEVENT("Transmit Data"). }
            }
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _experimentAvailable {
    PARAMETER mod.
    // Check known unavailability flags
    IF mod:HASFIELD("Inoperable") AND mod:GETFIELD("Inoperable") = "True" { RETURN FALSE. }
    IF mod:HASFIELD("Deployed")   AND mod:GETFIELD("Deployed")   = "True" { RETURN FALSE. }
    // Check if any run event exists at all
    LOCAL runEvents IS LIST(
        "Deploy Experiment", "Run Experiment",
        "Collect Data", "Observe", "Log Data", "Take Data"
    ).
    FOR evt IN runEvents {
        IF mod:HASEVENT(evt) { RETURN TRUE. }
    }
    RETURN FALSE.
}
