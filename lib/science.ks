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
    SET scienceActive    TO TRUE.
    SET sciLastBiome     TO SHIP:BODY:BIOMEOF(SHIP:GEOPOSITION).
    SET sciLastSituation TO SHIP:SITUATION.

    mLog("Science monitor active. Biome=" + sciLastBiome
        + "  Situation=" + sciLastSituation).

    IF SCI_CFG["SCANSAT_AUTO"] AND ADDONS:SCANSAT:AVAILABLE {
        scienceStartScanners().
    }

    // Optimized trigger condition
    WHEN scienceActive THEN {
        // Fetch current states once per trigger check to avoid multi-query lag
        LOCAL currentBiome IS SHIP:GEOPOSITION:BIOME.
        LOCAL currentSit   IS SHIP:SITUATION.

        IF (currentBiome <> sciLastBiome OR currentSit <> sciLastSituation) {

            mLog("Science: situation change"
                + "  biome: " + sciLastBiome + " -> " + currentBiome
                + "  situation: " + sciLastSituation + " -> " + currentSit).

            IF SCI_CFG["ALERT_ON_CHANGE"] {
                HUDTEXT("New science: " + currentBiome + " / " + currentSit,
                    4, 2, 14, CYAN, FALSE).
            }

            SET sciLastBiome     TO currentBiome.
            SET sciLastSituation TO currentSit.

            IF SCI_CFG["AUTO_COLLECT"] {
                scienceRunAll().
            }
        }

        // Only preserve the trigger if we actually want the monitor to stay alive
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
                LOCAL modu IS p:GETMODULE(modName).
                IF modu:HASFIELD("Deployed") AND mod:GETFIELD("Deployed") = "True" {
                    SET deployed TO deployed + 1.
                } ELSE IF modu:HASFIELD("Inoperable") AND mod:GETFIELD("Inoperable") = "True" {
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
    LOCAL started IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("SCANsat") {
            LOCAL modu IS p:GETMODULE("SCANsat").
            IF modu:HASEVENT("Start RADAR Scan")    { modu:DOEVENT("Start RADAR Scan").    SET started TO started + 1. }
            IF modu:HASEVENT("Start SAR Scan")      { modu:DOEVENT("Start SAR Scan").      SET started TO started + 1. }
            IF modu:HASEVENT("Start Altimetry Scan"){ modu:DOEVENT("Start Altimetry Scan").SET started TO started + 1. }
            IF modu:HASEVENT("Start Biome Scan")    { modu:DOEVENT("Start Biome Scan").    SET started TO started + 1. }
            IF modu:HASEVENT("Start Anomaly Scan")  { modu:DOEVENT("Start Anomaly Scan").  SET started TO started + 1. }
        }
        IF p:HASMODULE("SCANsat") {
            LOCAL modu IS p:GETMODULE("SCANsat").
            IF modu:HASEVENT("Start Scan") { modu:DOEVENT("Start Scan"). SET started TO started + 1. }
        }
    }
    mLog("SCANsat: " + started + " scanners started.").
    HUDTEXT("SCANsat scanning started", 3, 2, 13, CYAN, FALSE).
}

GLOBAL FUNCTION scienceStopScanners {
    IF NOT ADDONS:SCANSAT:AVAILABLE { RETURN. }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("SCANsat") {
            LOCAL modu IS p:GETMODULE("SCANsat").
            IF modu:HASEVENT("Stop Scan") { modu:DOEVENT("Stop Scan"). }
        }
    }
    mLog("SCANsat: all scanners stopped.").
}

GLOBAL FUNCTION scienceScanStatus {
    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("SCANsat not available.").
        RETURN.
    }
    LOCAL lBody IS SHIP:ORBIT:BODY.
    LOCAL altCoverage  IS 0.
    LOCAL biomCoverage IS 0.
    IF ADDONS:SCANSAT:AVAILABLE {
        SET altCoverage  TO ADDONS:SCANSAT:COVERAGE(lBody, "Altimetry").
        SET biomCoverage TO ADDONS:SCANSAT:COVERAGE(lBody, "Biome").
    }
    mLog("SCANsat coverage " + lBody:NAME + ":"
        + "  altimetry="  + ROUND(altCoverage,1)  + "%"
        + "  biome="      + ROUND(biomCoverage,1) + "%").
    HUDTEXT("Scan: alt=" + ROUND(altCoverage,0) + "% bio=" + ROUND(biomCoverage,0) + "%",
        3, 2, 13, CYAN, FALSE).
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
        IF mod:HASEVENT(evt) {
            mod:DOEVENT(evt).
            mLog("Science: ran '" + evt + "' on " + part:NAME
                + "  biome=" + SHIP:BIOME
                + "  situation=" + SHIP:SITUATION).

            IF SCI_CFG["AUTO_TRANSMIT"] {
                WAIT 1.
                IF mod:HASEVENT("Transmit Data") { mod:DOEVENT("Transmit Data"). }
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
        IF mod:HASEVENT(evt) { RETURN TRUE. }
    }
    RETURN FALSE.
}
