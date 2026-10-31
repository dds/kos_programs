// ============================================================
// science_entry.ks — continuous flyby/entry science (0:/lib/science_entry.ks)
// No capture or automatic staging. Optional chutes and terminal controller.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL SCIENCE_ENTRY_BANDS IS LEXICON().
GLOBAL SCIENCE_ENTRY_MOON IS "".
GLOBAL SCIENCE_ENTRY_MOON_MIN_PE IS 20000.
GLOBAL SCIENCE_ENTRY_PREPARE_LEAD IS 180.
GLOBAL SCIENCE_ENTRY_MAX_PASSES IS 3.
GLOBAL SCIENCE_ENTRY_MIN_EC IS 0.05.
GLOBAL SCIENCE_ENTRY_CHUTES IS 0.

LOCAL FUNCTION _scienceEntryChutes {
    PARAMETER primary.
    IF SCIENCE_ENTRY_CHUTES <= 0 OR ABORT OR WARP <> 0 { RETURN. }
    IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR SHIP:BODY <> primary { RETURN. }
    IF NOT primary:ATM:EXISTS OR NOT (SHIP:ALTITUDE < primary:ATM:HEIGHT
            AND SHIP:VERTICALSPEED < 0) { RETURN. }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN. }
    IF NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
            AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) { RETURN. }
    // Native ModuleParachute safety gate, revisited as speed/pressure change.
    // Never use CHUTESSAFE's getter as proof of deployment (empty is true).
    CHUTESSAFE ON.
}

GLOBAL FUNCTION scienceEntrySample {
    PARAMETER primary.
    // Optional flyby measurements share the assist-coast science flag.
    // Primary entry science and every encounter safety check remain active.
    IF SHIP:BODY <> primary AND MISSION_ASSIST_SCIENCE <= 0 { RETURN. }
    scienceFlightPulse(scienceEntryContext(),shipPowerFraction() >= SCIENCE_ENTRY_MIN_EC).
}

GLOBAL FUNCTION scienceEntryContext {
    LOCAL bands IS SCIENCE_ENTRY_BANDS[SHIP:BODY:NAME].
    LOCAL situation IS "SPACE_HIGH".
    IF SHIP:ALTITUDE < bands[0] { SET situation TO "SPACE_LOW". }
    IF SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT {
        SET situation TO "FLYING_HIGH".
        IF SHIP:ALTITUDE < bands[1] { SET situation TO "FLYING_LOW". }
    }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { SET situation TO SHIP:STATUS. }
    LOCAL biome IS "unknown".
    IF ADDONS:SCANSAT:AVAILABLE {
        SET biome TO ADDONS:SCANSAT:GETBIOME(SHIP:BODY,SHIP:GEOPOSITION).
    }
    RETURN stateGet("mission_id","")+":"+SHIP:BODY:NAME+":"+situation+":"+biome.
}

LOCAL FUNCTION _scienceEntryHold {
    PARAMETER reason.
    SET WARP TO 0.
    IF NOT thrustCutoffOk() { RETURN. }
    UNLOCK STEERING.
    mLogError("STATS science-entry result status=hold reason=" + reason
        + " body=" + SHIP:BODY:NAME + " altitude=" + SHIP:ALTITUDE
        + " Pe=" + SHIP:PERIAPSIS + " passes=" + stateGetNum("science_entry_passes",0)).
    PRINT "SCIENCE ENTRY HELD: " + reason + ". Review the live trajectory before resuming.".
    yieldToPrompt().
}

LOCAL FUNCTION _scienceEntryMoonCheck {
    PARAMETER primary.
    IF SCIENCE_ENTRY_MOON = "" { RETURN TRUE. }
    LOCAL patch IS SHIP:ORBIT.
    LOCAL steps IS 0.
    LOCAL moonSeen IS FALSE.
    LOCAL safeMoon IS TRUE.
    LOCAL entryAfterMoon IS FALSE.
    LOCAL startEta IS 0.
    UNTIL steps >= 12 {
        IF patch:BODY:NAME = SCIENCE_ENTRY_MOON {
            SET moonSeen TO TRUE.
            SET entryAfterMoon TO FALSE.
            SET safeMoon TO safeMoon AND patch:PERIAPSIS >= SCIENCE_ENTRY_MOON_MIN_PE
                AND ABS(patch:PERIAPSIS) < 1e30.
        }
        IF moonSeen AND patch:BODY = primary {
            // Pe must actually occur on this patch, not on an extrapolated
            // conic truncated by another encounter. ETAs are relative to now.
            LOCAL peEta IS patch:ETA:PERIAPSIS.
            SET entryAfterMoon TO patch:PERIAPSIS > 0
                AND patch:PERIAPSIS < primary:ATM:HEIGHT
                AND peEta > startEta AND peEta < 1e30.
            IF patch:HASNEXTPATCH {
                SET entryAfterMoon TO entryAfterMoon AND peEta < patch:NEXTPATCHETA.
            }
        }
        IF NOT patch:HASNEXTPATCH { BREAK. }
        SET startEta TO patch:NEXTPATCHETA.
        SET patch TO patch:NEXTPATCH.
        SET steps TO steps+1.
    }
    mLog("STATS science-entry moon nativeEncounter=" + moonSeen
        + " safeMoon=" + safeMoon + " subsequentEntry=" + entryAfterMoon
        + " detourDv=0 activeDetour=False").
    // An incidental moon pass is free, but must retain the primary entry.
    // Do not buy capture/a moon transfer or authorize an unsafe native pass.
    RETURN NOT moonSeen OR (safeMoon AND entryAfterMoon AND steps < 12).
}

LOCAL FUNCTION _scienceEntryWakeUt {
    LOCAL wakeUt IS TIME:SECONDS+900.
    LOCAL bands IS SCIENCE_ENTRY_BANDS[SHIP:BODY:NAME].
    LOCAL boundaryEta IS aerobrakeApEntryEta(bands[0]).
    IF boundaryEta > 0 { SET wakeUt TO MIN(wakeUt,TIME:SECONDS+boundaryEta). }
    IF SHIP:BODY:ATM:EXISTS {
        LOCAL entryEta IS aerobrakeApEntryEta(SHIP:BODY:ATM:HEIGHT).
        IF entryEta >= 0 {
            SET wakeUt TO MIN(wakeUt,TIME:SECONDS+MAX(0,entryEta-SCIENCE_ENTRY_PREPARE_LEAD)).
        }
    }
    IF SHIP:ORBIT:HASNEXTPATCH {
        SET wakeUt TO MIN(wakeUt,TIME:SECONDS+MAX(0,SHIP:ORBIT:NEXTPATCHETA-30)).
    }
    RETURN wakeUt.
}

GLOBAL FUNCTION scienceEntryWait {
    PARAMETER wakeUt.
    LOCAL coastBody IS SHIP:BODY.
    LOCAL alarm IS kacEnsureAlarm("Science entry wake",wakeUt,
        "Science/entry checkpoint; the running phase resumes automatically.",1).
    mLog("STATS science-entry wait wakeUt=" + wakeUt + " alarm=" + alarm + " resident=True").
    // Alarm first, then bounded solar work. The loop is also the no-KAC
    // fallback; without our own live alarm coastAutoWarp declines warp.
    LOCAL solarRef IS enterSolarCoast("Science entry coast",TRUE,TRUE,wakeUt).
    IF NOT ABORT AND TIME:SECONDS < wakeUt AND alarm <> ""
            AND solarCoastCanWarp(solarRef,"Science entry coast") {
        coastAutoWarp(wakeUt,"Science entry coast",alarm).
    }
    UNTIL ABORT OR TIME:SECONDS >= wakeUt OR SHIP:BODY <> coastBody {
        SET solarRef TO trySolarHoldTick(solarRef,wakeUt).
        IF TIME:SECONDS >= wakeUt { BREAK. }
        WAIT MIN(5,MAX(0.1,wakeUt-TIME:SECONDS)).
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF alarm <> "" { DELETEALARM(alarm). }
}

GLOBAL FUNCTION phaseScienceEntry {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF ABORT OR NOT thrustCutoffOk() { RETURN. }
    LOCAL primary IS missionTargetBody().
    IF NOT primary:ATM:EXISTS OR NOT SCIENCE_ENTRY_BANDS:HASKEY(primary:NAME)
            OR NOT (SCIENCE_ENTRY_PREPARE_LEAD >= 30 AND SCIENCE_ENTRY_PREPARE_LEAD <= 900)
            OR NOT (SCIENCE_ENTRY_MAX_PASSES >= 1 AND SCIENCE_ENTRY_MAX_PASSES <= 10)
            OR NOT (SCIENCE_ENTRY_MIN_EC >= 0 AND SCIENCE_ENTRY_MIN_EC < 1)
            OR NOT (SCIENCE_ENTRY_MOON_MIN_PE >= 0 AND SCIENCE_ENTRY_MOON_MIN_PE < 1e30) {
        _scienceEntryHold("invalid-entry-configuration"). RETURN.
    }
    FOR bands IN SCIENCE_ENTRY_BANDS:VALUES {
        IF bands:LENGTH <> 2 {
            _scienceEntryHold("invalid-sampling-bands"). RETURN.
        }
        IF NOT (bands[0] > bands[1] AND bands[1] >= 0 AND bands[0] < 1e30) {
            _scienceEntryHold("invalid-sampling-bands"). RETURN.
        }
    }
    IF HASNODE { _scienceEntryHold("unexpected-maneuver-node"). RETURN. }
    IF NOT _scienceEntryMoonCheck(primary) {
        _scienceEntryHold("moon-pass-does-not-retain-safe-primary-entry"). RETURN.
    }
    mLog("STATS science-entry setup primary=" + primary:NAME
        + " moon=" + SCIENCE_ENTRY_MOON + " minEc=" + SCIENCE_ENTRY_MIN_EC
        + " safeChutes=" + (SCIENCE_ENTRY_CHUTES > 0)
        + " poweredTerminal=" + (ENTRY_POWERED_LANDING > 0) + " deliveryConfirmationAvailable=False").
    LOCAL flightId IS stateGet("mission_id","")+":"+stateGetNum("launch_time",0)+":"+primary:NAME.
    IF stateGet("science_entry_id","") <> flightId {
        stateSet("science_entry_passes",0).
        stateSet("science_entry_in_atmo",FALSE).
        stateSet("science_entry_id",flightId).
    }
    LOCAL entrySteering IS FALSE.
    LOCAL terminal IS LEXICON().
    IF ENTRY_POWERED_LANDING > 0 { SET terminal TO entryLandingCreate(). }
    LOCAL nextScience IS 0.
    LOCAL nextReport IS 0.
    LOCAL lastBody IS SHIP:BODY.
    UNTIL ABORT {
        IF NOT SCIENCE_ENTRY_BANDS:HASKEY(SHIP:BODY:NAME) {
            _scienceEntryHold("left-science-system-without-touchdown"). RETURN.
        }
        IF SHIP:BODY <> lastBody {
            SET lastBody TO SHIP:BODY.
            IF NOT _scienceEntryMoonCheck(primary) {
                _scienceEntryHold("moon-pass-does-not-retain-safe-primary-entry"). RETURN.
            }
        }
        LOCAL inAtmo IS SHIP:BODY:ATM:EXISTS AND SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT.
        IF inAtmo AND NOT stateGet("science_entry_in_atmo",FALSE) {
            stateSet("science_entry_passes",stateGetNum("science_entry_passes",0)+1).
        }
        IF inAtmo <> stateGet("science_entry_in_atmo",FALSE) {
            stateSet("science_entry_in_atmo",inAtmo).
        }
        IF TIME:SECONDS >= nextScience {
            scienceEntrySample(primary).
            SET nextScience TO TIME:SECONDS+0.5.
        }
        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            IF terminal:LENGTH > 0 { IF NOT entryLandingStop(terminal) { RETURN. } }
            SET WARP TO 0.
            UNLOCK STEERING.
            BRAKES ON.
            // Give pending surface data a bounded chance to arrive and queue.
            LOCAL deadline IS TIME:SECONDS+60.
            UNTIL ABORT OR TIME:SECONDS >= deadline {
                scienceEntrySample(primary).
                WAIT 1.
            }
            IF ABORT { RETURN. }
            mLog("STATS science-entry result status=surface deliveryConfirmed=False").
            nextPhase(xferSeq). RETURN.
        }
        IF NOT inAtmo AND SHIP:BODY = primary
                AND stateGetNum("science_entry_passes",0) >= SCIENCE_ENTRY_MAX_PASSES {
            _scienceEntryHold("entry-pass-limit-without-touchdown"). RETURN.
        }
        IF NOT inAtmo AND SHIP:BODY = primary
                AND aerobrakeApEntryEta(primary:ATM:HEIGHT) < 0 {
            LOCAL moonNext IS FALSE.
            IF SCIENCE_ENTRY_MOON <> "" AND SHIP:ORBIT:HASNEXTPATCH {
                SET moonNext TO SHIP:ORBIT:NEXTPATCH:BODY:NAME = SCIENCE_ENTRY_MOON.
            }
            IF NOT moonNext { _scienceEntryHold("no-future-atmospheric-crossing"). RETURN. }
        }
        LOCAL wakeUt IS _scienceEntryWakeUt().
        IF NOT inAtmo AND wakeUt > TIME:SECONDS+30 {
            IF terminal:LENGTH > 0 {
                IF terminal["ACTIVE"] { IF NOT entryLandingStop(terminal) { RETURN. } }
            }
            SET entrySteering TO FALSE.
            scienceEntryWait(wakeUt).
        } ELSE {
            SET WARP TO 0.
            _scienceEntryChutes(primary).
            LOCAL controlled IS FALSE.
            IF terminal:LENGTH > 0 {
                SET controlled TO entryLandingTick(terminal).
                IF ABORT { BREAK. }
                IF NOT controlled AND terminal["ACTIVE"] {
                    _scienceEntryHold("terminal-control-context-changed"). RETURN.
                }
                IF controlled { SET entrySteering TO FALSE. }
            }
            IF NOT controlled AND NOT entrySteering {
                SET SAS TO FALSE.
                // Live surface retrograde follows the atmosphere-relative
                // velocity; never freeze a direction at a future periapsis.
                LOCK STEERING TO SHIP:SRFRETROGRADE.
                SET entrySteering TO TRUE.
            }
            IF TIME:SECONDS >= nextReport {
                mLog("STATS science-entry live body=" + SHIP:BODY:NAME
                    + " altitude=" + ROUND(SHIP:ALTITUDE,1) + " vs=" + ROUND(SHIP:VERTICALSPEED,1)
                    + " speed=" + ROUND(SHIP:AIRSPEED,1) + " ec=" + ROUND(shipPowerFraction(),3)
                    + " homeLink=" + HOMECONNECTION:ISCONNECTED + " inAtmo=" + inAtmo).
                SET nextReport TO TIME:SECONDS+10.
            }
            IF controlled { WAIT 0.05. } ELSE { WAIT 0.5. }
        }
    }
    SET WARP TO 0.
    IF terminal:LENGTH > 0 { entryLandingStop(terminal). }
    UNLOCK STEERING.
}
