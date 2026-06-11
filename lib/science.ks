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
    mLogWarn("STATS scansat status available=True body=" + lBody:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " note=coverage-api-unavailable").
    HUDTEXT("SCANsat active over " + lBody:NAME, 3, 2, 13, CYAN, FALSE).
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
// scansatPowerWatch — on-station power management loop. Pauses
// the scanners when charge drops below SCANSAT_POWER_LOW (15%),
// resumes above SCANSAT_POWER_RESUME (50%), and flashes the HUD
// red when critical — pointing at the AMP reserve bank when one
// is aboard (we can't transfer it ourselves; the operator can).
// Re-runs the solar attitude every 30 min. AG10 exits the watch
// and lets the sequence continue. Requires utils (orientForSolar,
// shipPowerFraction) — SCANSAT_OPS loads it via payload_ops.
// ============================================================
GLOBAL FUNCTION scansatPowerWatch {
    LOCAL lowFrac IS 0.15.
    LOCAL resumeFrac IS 0.5.
    IF CFG:HASKEY("SCANSAT_POWER_LOW") { SET lowFrac TO CFG["SCANSAT_POWER_LOW"]. }
    IF CFG:HASKEY("SCANSAT_POWER_RESUME") { SET resumeFrac TO CFG["SCANSAT_POWER_RESUME"]. }

    mLog("Power watch: scans pause below " + ROUND(lowFrac * 100, 0)
        + "%, resume above " + ROUND(resumeFrac * 100, 0)
        + "%. AG10 ends the watch.").
    LOCAL scansOn IS TRUE.
    LOCAL nextOrient IS TIME:SECONDS + 1800.
    LOCAL nextHud IS 0.
    LOCAL nextStats IS 0.
    UNTIL AG10 {
        LOCAL frac IS shipPowerFraction().

        IF scansOn AND frac < lowFrac {
            scienceStopScanners().
            SET scansOn TO FALSE.
            mLogWarn("STATS scansat power pause charge="
                + ROUND(frac * 100, 1) + "pct").
            HUDTEXT("Scans PAUSED — battery "
                + ROUND(frac * 100, 0) + "%", 10, 2, 18, YELLOW, FALSE).
        } ELSE IF NOT scansOn AND frac > resumeFrac {
            scienceStartScanners().
            SET scansOn TO TRUE.
            mLog("Power recovered (" + ROUND(frac * 100, 0)
                + "%) — scans resumed.").
        }

        IF frac < lowFrac * 0.67 AND TIME:SECONDS > nextHud {
            SET nextHud TO TIME:SECONDS + 20.
            HUDTEXT("POWER CRITICAL " + ROUND(frac * 100, 0) + "%"
                + (CHOOSE " — TRANSFER RESERVE POWER (AMP)"
                   IF shipReservePower() > 0
                   ELSE " — systems powering down"),
                15, 2, 20, RED, FALSE).
        }

        IF TIME:SECONDS > nextOrient {
            SET nextOrient TO TIME:SECONDS + 1800.
            orientForSolar().
        }
        IF TIME:SECONDS > nextStats {
            SET nextStats TO TIME:SECONDS + 600.
            mLogWarn("STATS scansat power charge="
                + ROUND(frac * 100, 1) + "pct flow="
                + ROUND(shipSolarFlow(), 2)
                + " scans=" + scansOn
                + " reserve=" + ROUND(shipReservePower(), 0)).
        }
        WAIT 5.
    }
    mLog("Power watch ended (AG10) — continuing the sequence.").
}
