// landing_light_wait.ks - Live parking-orbit wait for a landing light window.
// Forecasts schedule a fresh search; they are never stored landing targets.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _landingLightWaitContext {
    LOCAL band IS landingSunBand().
    RETURN LEXICON("mission", stateGet("mission_id", ""),
        "launch", stateGetNum("launch_time", 0), "phase", stateGet("phase", ""),
        "body", SHIP:BODY:NAME, "mode", LANDING_LIGHT_MODE,
        "radio", LANDING_REQUIRE_KERBIN, "kerbinMin", LANDING_KERBIN_MIN_ELEV,
        "sunMin", band["MIN"], "sunMax", band["MAX"],
        "radius", landingPlanningRadius(), "margin", LANDING_LIGHT_TIME_MARGIN,
        "period", ROUND(SHIP:ORBIT:PERIOD, 0),
        "inc", ROUND(SHIP:ORBIT:INCLINATION, 1), "lan", ROUND(SHIP:ORBIT:LAN, 1)).
}

LOCAL FUNCTION _landingLightWaitBlockReason {
    IF ABORT { RETURN "abort-active". }
    IF HASNODE { RETURN "maneuver-node-present". }
    IF SHIP:STATUS <> "ORBITING" { RETURN "not-orbiting". }
    IF NOT (SHIP:PERIAPSIS > 0 AND SHIP:ORBIT:ECCENTRICITY < 1) { RETURN "invalid-bound-orbit". }
    IF NOT (SHIP:ORBIT:PERIOD > 0 AND SHIP:ORBIT:PERIOD < 1e30) { RETURN "invalid-orbit-period". }
    IF SHIP:ORBIT:HASNEXTPATCH { RETURN "future-orbit-patch". }
    IF SHIP:BODY:ATM:EXISTS { RETURN "atmospheric-body". }
    IF stateGet("deorbit_burn_started", "false") = "true" { RETURN "deorbit-already-started". }
    IF ADDONS:TR:AVAILABLE {
        IF ADDONS:TR:HASIMPACT { RETURN "predicted-impact". }
    }
    RETURN "".
}

LOCAL FUNCTION _landingLightWaitSafe {
    PARAMETER report IS 0.
    LOCAL reason IS _landingLightWaitBlockReason().
    IF reason <> "" {
        IF report <> 0 { SET report["REASON"] TO reason. }
        mLogWarn("STATS landing-light wait-rejected reason=" + reason
            + " abort=" + ABORT + " status=" + SHIP:STATUS
            + " PeKm=" + SHIP:PERIAPSIS/1000 + " ecc=" + SHIP:ORBIT:ECCENTRICITY
            + " period=" + SHIP:ORBIT:PERIOD + " hasNode=" + HASNODE
            + " nextPatch=" + SHIP:ORBIT:HASNEXTPATCH).
    }
    RETURN reason = "".
}

GLOBAL FUNCTION landingLightWaitClear {
    LOCAL saved IS stateGet("landing_light_wait", LEXICON()).
    IF saved:LENGTH > 0 {
        IF saved["alarm"] <> "" AND ADDONS:KAC:AVAILABLE { DELETEALARM(saved["alarm"]). }
    }
    stateRemove("landing_light_wait").
}

LOCAL FUNCTION _landingLightWaitMatches {
    PARAMETER saved.
    IF saved:LENGTH = 0 { RETURN FALSE. }
    LOCAL context IS _landingLightWaitContext().
    FOR key IN context:KEYS {
        IF saved["context"][key] <> context[key] { RETURN FALSE. }
    }
    RETURN saved["wakeUt"] > 0 AND saved["wakeUt"] < 1e30.
}

GLOBAL FUNCTION landingAwaitLitGroundTrack {
    mLog("STATS landing-light selector revision=2 abort=" + ABORT
        + " status=" + SHIP:STATUS + " PeKm=" + SHIP:PERIAPSIS/1000).
    LOCAL site IS LEXICON("FOUND", FALSE, "REASON", "aborted").
    UNTIL ABORT {
        LOCAL saved IS stateGet("landing_light_wait", LEXICON()).
        IF saved:LENGTH > 0 {
            IF NOT _landingLightWaitSafe(site) {
                landingLightWaitClear().
                RETURN site.
            }
            IF NOT _landingLightWaitMatches(saved) {
                landingLightWaitClear().
            } ELSE {
                IF NOT thrustCutoffOk() { RETURN site. }
                LOCAL wakeUt IS saved["wakeUt"].
                LOCAL waitBody IS SHIP:BODY.
                IF wakeUt > TIME:SECONDS {
                    // Install the timer BEFORE potentially slow solar setup.
                    SET saved TO saved:COPY.
                    SET saved["alarm"] TO kacEnsureAlarm("Landing light retry: " + SHIP:BODY:NAME,
                        wakeUt, "Estimated light/radio window; fresh site search required at wake.").
                    stateSet("landing_light_wait", saved).
                    mLog("STATS landing-light wait wakeUt=" + wakeUt
                        + " eta=" + (wakeUt-TIME:SECONDS) + " estimateUt=" + saved["estimateUt"]
                        + " forecastFound=" + saved["forecastFound"] + " alarm=" + saved["alarm"]
                        + " automaticResume=True").
                    PRINT "LANDING WINDOW WAIT: solar hold; retry in "
                        + ROUND(wakeUt-TIME:SECONDS,0) + "s (UT " + ROUND(wakeUt,1) + ").".
                    LOCAL solarRef IS enterSolarCoast("Landing light retry", TRUE, TRUE, wakeUt).
                    waitUntilOrSOI(waitBody, wakeUt, 10, saved["alarm"], solarRef, TRUE, TRUE).
                }
                IF WARP > 0 {
                    SET WARP TO 0.
                    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
                }
                landingLightWaitClear().
                IF NOT _landingLightWaitSafe(site) OR SHIP:BODY <> waitBody
                        OR NOT _landingLightWaitMatches(saved) {
                    mLogWarn("Landing light wait interrupted; recheck orbit/node before deorbit.").
                    RETURN site.
                }
            }
        }
        SET site TO landingLitGroundTrack().
        IF site["FOUND"] OR ABORT { RETURN site. }
        // Only an unmet light/radio window is an automatic retry. Preserve
        // manual handling of invalid configuration or frame disagreements.
        IF NOT _landingLightWaitSafe(site) OR NOT landingLightActive()
                OR site["REASON"] = "invalid-light-config"
                OR site["REASON"] = "kerbin-frame-mismatch" { RETURN site. }
        LOCAL estimate IS landingLitGroundTrack(TRUE).
        IF ABORT { RETURN site. }
        LOCAL period IS SHIP:ORBIT:PERIOD.
        LOCAL wakeUt IS TIME:SECONDS + MAX(period, (estimate["SCAN_END"]-TIME:SECONDS)/16).
        IF estimate["FOUND"] {
            // Wake while the estimate is inside the normal search horizon,
            // leaving two vessel orbits to find and plan a reachable site.
            SET wakeUt TO MAX(TIME:SECONDS+60,
                estimate["UT"]-MAX(600,period*0.35)-2*period).
        }
        stateSet("landing_light_wait", LEXICON("context", _landingLightWaitContext(),
            "wakeUt", wakeUt, "estimateUt", estimate["UT"],
            "forecastFound", estimate["FOUND"], "alarm", "")).
        mLog("STATS landing-light retry-scheduled reason=" + site["REASON"]
            + " wakeUt=" + wakeUt + " eta=" + (wakeUt-TIME:SECONDS)
            + " estimateUt=" + estimate["UT"] + " forecastFound=" + estimate["FOUND"]
            + " estimateStep=" + estimate["STEP"]).
    }
    RETURN site.
}
