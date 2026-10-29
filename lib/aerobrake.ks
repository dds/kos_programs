// ============================================================
// aerobrake.ks  —  Aerobrake entry phase  (0:/lib/aerobrake.ks)
//
// Two responsibilities:
//   1. Precision reentry targeting using Trajectories addon
//      (coordinate search over radial/normal to steer impact
//      point toward KSC)
//   2. Vessel prep for atmospheric entry (decouple transfer
//      stage, retract antennas after entry, orient retrograde,
//      arm chutes)
//
// Loaded as an implicit single-phase band (like MCC).
// Depends on: utils (geoDistance)
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL AEROBRAKE_DECOUPLE_TAG IS "".
GLOBAL AEROBRAKE_REENTRY_DIR IS "".
GLOBAL AEROBRAKE_ARM_CHUTES IS 0.
GLOBAL AEROBRAKE_TARGETING IS 1.
// Pe-trim is opt-in (off by default) so it can't fight a body that
// sets its own aerobrake periapsis elsewhere (e.g. Duna aerocapture /
// DUNA_ENTRY_LOWER_PE). When on, it deepens to AEROBRAKE_PE, or
// REENTRY_PE if AEROBRAKE_PE is unset.
GLOBAL AEROBRAKE_PE_TARGETING IS 0.
GLOBAL AEROBRAKE_PE IS -1.
// Optional bounds for impact-site corrections. A better KSC prediction
// must not trade away an explicitly requested shallow entry corridor.
GLOBAL AEROBRAKE_CORRECTION_PE_MIN IS -1.
GLOBAL AEROBRAKE_CORRECTION_PE_MAX IS -1.
// Multi-pass aerobrake: hold heat-shield-forward through each pass and
// stay in this phase until captured AND slowed below this airspeed (m/s)
// — i.e. through the fast/thick part — before handing to DESCENT. We never
// reboot into DESCENT at orbital speed where a brief loss of control on a
// not-yet-stable craft could tumble it.
GLOBAL AEROBRAKE_HANDOFF_SPEED IS 600.
// The capture braking burn stops once periapsis is this deep (m over
// surface); -1 => auto (0.4 * atmosphere height). Keeps it from driving
// Pe negative if it ever runs to fuel exhaustion.
GLOBAL AEROBRAKE_BRAKE_PE_FLOOR IS -1.
// Hold the solar attitude through the long coast and only wake to get
// ready for entry this many seconds before the atmosphere (default 15 min).
GLOBAL AEROBRAKE_ENTRY_LEAD IS 900.

LOCAL KSC_LAT IS -0.10.
LOCAL KSC_LNG IS -74.25.
LOCAL CORRECTION_TOLERANCE IS 50000.   // 50km default
LOCAL MAX_CORRECTION_DV IS 20.         // cap total correction burn
LOCAL PE_CORRECTION_TOLERANCE IS 1000. // 1km final reentry Pe cleanup
LOCAL MAX_PE_CORRECTION_FRACTION IS 0.05.
LOCAL MAX_TARGETING_SCANS IS 5.
LOCAL TARGETING_ATMO_SKIP_MULT IS 1.1.

// Atmosphere heights by body (meters). Stock + OPM.
LOCAL ATM_HEIGHTS IS LEXICON(
    "KERBIN", 70000,
    "DUNA",   50000,
    "EVE",    90000,
    "JOOL",   200000,
    "LAYTHE", 50000,
    "SARNUS", 580000,
    "URLUM",  325000,
    "NEIDON", 260000,
    "TEKTO",  95000
).

GLOBAL FUNCTION phaseAerobrake {
    IF NOT aerobrakeApRecover() { RETURN. }
    mLogPhase("AEROBRAKE").

    // If entered while still coasting through an AIRLESS SOI (a Mun
    // flyby's outbound leg hands off mid-escape), wait until we're at
    // the body we'll actually aerobrake. Otherwise the Pe-trim and
    // targeting run against the wrong orbit — flight-found: it tried to
    // deepen the *Mun* Pe (2146km) to 25km and capped out.
    IF NOT SHIP:BODY:ATM:EXISTS {
        mLog("Aerobrake: in airless " + SHIP:BODY:NAME
            + " SOI — coasting until at an atmosphere body...").
        WAIT UNTIL SHIP:BODY:ATM:EXISTS
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
        mLog("Aerobrake: now at " + SHIP:BODY:NAME + ".").
    }

    LOCAL atmHeight IS _aerobrakeAtmoHeight().
    // A reboot after a skipped pass may have lost the RAM-only inPass flag.
    // An outbound hyperbola still needs capture before any solar wait.
    IF SHIP:ALTITUDE > atmHeight AND SHIP:PERIAPSIS < atmHeight
            AND SHIP:ORBIT:ECCENTRICITY >= 1 AND SHIP:VERTICALSPEED > 0 {
        _aerobrakeBrakingBurn().
        IF phaseShouldYield { RETURN. }
    }

    // A skipped/failed return MCC is not an atmospheric approach.
    // Repair it while still far out, before alarms, coast, or stowing
    // hardware. This also recovers older saved returns already at AEROBRAKE.
    IF SHIP:BODY:NAME = "Kerbin" AND SHIP:PERIAPSIS >= atmHeight {
        SET WARP TO 0.
        IF xferSeq:CONTAINS("MCC") {
            mLogWarn("Aerobrake: no atmospheric approach; returning to MCC.").
            mLog("STATS aerobrake status=return-to-mcc PeKm="
                + ROUND(SHIP:PERIAPSIS / 1000, 3)).
            stateSet("phase", "MCC").
        } ELSE {
            mLogError("Aerobrake: no atmospheric approach and no MCC phase; holding.").
            yieldToPrompt().
        }
        RETURN.
    }

    LOCAL peFloor IS atmHeight*0.4.
    IF AEROBRAKE_BRAKE_PE_FLOOR >= 0 { SET peFloor TO AEROBRAKE_BRAKE_PE_FLOOR. }
    LOCAL assistPe IS REENTRY_PE.
    IF AEROBRAKE_PE > 0 { SET assistPe TO AEROBRAKE_PE. }
    LOCAL peLow IS MAX(peFloor,assistPe-1000).
    LOCAL peHigh IS MIN(atmHeight-100,assistPe+1000).
    IF AEROBRAKE_CORRECTION_PE_MIN >= 0 { SET peLow TO MAX(peLow,AEROBRAKE_CORRECTION_PE_MIN). }
    IF AEROBRAKE_CORRECTION_PE_MAX >= 0 { SET peHigh TO MIN(peHigh,AEROBRAKE_CORRECTION_PE_MAX). }

    // --- Long-term setup: alarm the atmosphere entry, then orient for
    // solar and hold (charging, panels still out) until 15 min before it. ---
    LOCAL entryUt IS _aerobrakeSetEntryAlarm().
    // Also handles a reboot on the outbound leg after a skipped pass.
    IF NOT _aerobrakeRestorePe(atmHeight,assistPe,peLow,peHigh) { RETURN. }
    SET entryUt TO _aerobrakeSetEntryAlarm().
    IF entryUt > 0 {
        _aerobrakeSolarWait(entryUt - AEROBRAKE_ENTRY_LEAD).
    }

    // --- Wake up and get ready (~15 min before entry) ---
    // Aim the periapsis at the aerobrake corridor (shallow enough that the
    // craft stays controllable at orbital speed).
    IF AEROBRAKE_PE_TARGETING > 0 {
        _aerobrakeTrimReentryPe().
    }
    // One opportunistic impact nudge if Trajectories already resolves one;
    // a missing impact is NOT a reason to bail to DESCENT — the multi-pass
    // loop below carries on regardless.
    IF AEROBRAKE_TARGETING <= 0 {
        mLog("Aerobrake impact-site targeting disabled by config.").
    } ELSE IF ADDONS:TR:AVAILABLE {
        _aerobrakeReentryTargeting().
    } ELSE {
        mLog("Trajectories not available — skipping impact-site targeting.").
    }
    _aerobrakeDecouple().
    // Deployable antennas/panels break in the airstream and open bays add
    // unwanted torque; stow everything now. (Fixed panels, e.g. FTSV1's,
    // ride through fine.) DESCENT re-extends them once it's slow enough.
    _aerobrakeRetractSolarPanels().
    _aerobrakeRetractAntennas().
    _aerobrakeCloseExtendBays().
    // Entry timing may have changed during Pe/site correction burns.
    SET entryUt TO _aerobrakeSetEntryAlarm().

    mLog("Aerobrake: multi-pass braking. Holding heat-shield-forward "
        + "through each pass; staying until captured and slowed below "
        + AEROBRAKE_HANDOFF_SPEED + " m/s before DESCENT.").

    // If we somehow begin already inside the atmosphere, get oriented now.
    IF SHIP:ALTITUDE < atmHeight { _aerobrakeOrient(). }

    // --- Multi-pass aerobrake loop ---
    LOCAL passNum IS 0.
    LOCAL inPass IS FALSE.
    mLog("STATS aerobrake-assist policy enabled=" + (AEROBRAKE_AP_BURN > 0)
        + " reserve=" + aerobrakeApReserveDv() + " planLead=" + AEROBRAKE_AP_PLAN_LEAD
        + " maxQAtm=" + AEROBRAKE_AP_MAX_Q + " targetPe=" + assistPe
        + " peLow=" + peLow + " peHigh=" + peHigh + " repair=" + AEROBRAKE_PE_TARGETING).
    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        IF _aerobrakeThroughThickPart(atmHeight) {
            mLog("Aerobrake: captured (Ap "
                + ROUND(SHIP:APOAPSIS / 1000, 1) + "km) and slowed to "
                + ROUND(SHIP:AIRSPEED, 0)
                + " m/s — through the thick part. Handing to DESCENT.").
            BREAK.
        }
        aerobrakeApObserve(atmHeight).
        IF SHIP:ALTITUDE > atmHeight {
            IF inPass {
                SET inPass TO FALSE.
                mLog("STATS aerobrake pass=" + passNum + " out"
                    + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
                    + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
                    + " vel=" + ROUND(SHIP:VELOCITY:ORBIT:MAG, 0)).
                // A pass that left us still hyperbolic would sail back out
                // and escape — spend fuel to secure capture (the braking
                // burn lives only in AEROBRAKE now). Stops as soon as the
                // orbit is bound; aerobraking finishes the rest.
                IF SHIP:ORBIT:ECCENTRICITY >= 1 {
                    mLog("Aerobrake: pass " + passNum + " left ecc "
                        + ROUND(SHIP:ORBIT:ECCENTRICITY, 3)
                        + " (hyperbolic) — braking burn to secure capture.").
                    _aerobrakeBrakingBurn().
                    IF phaseShouldYield { RETURN. }
                }
                // Drag (and any capture burn) changed the next orbit.
                // Refresh the owned alarm before beginning its solar coast.
                SET entryUt TO _aerobrakeSetEntryAlarm().
            }
            IF NOT _aerobrakeRestorePe(atmHeight,assistPe,peLow,peHigh) { RETURN. }
            SET entryUt TO _aerobrakeSetEntryAlarm().
            // Between passes: solar-hold + warp the high coast, then orient
            // heat-shield-forward ~15 min before the next pass.
            IF entryUt > 0 { _aerobrakeSolarWait(entryUt - AEROBRAKE_ENTRY_LEAD). }
            LOCAL entryStage IS STAGE:NUMBER.
            IF AEROBRAKE_AP_BURN > 0 {
                LOCAL approachEta IS aerobrakeApEntryEta(atmHeight).
                IF approachEta > AEROBRAKE_AP_PLAN_LEAD {
                    _aerobrakeSolarWait(TIME:SECONDS+approachEta-AEROBRAKE_AP_PLAN_LEAD).
                }
                // Solar wait has released warp. A depleted tagged upper
                // engine can now hand off before a fresh next-entry forecast.
                IF aerobrakeApStageCoast(atmHeight,peLow,peHigh) {
                    SET entryUt TO _aerobrakeSetEntryAlarm().
                }
                IF phaseShouldYield { RETURN. }
                SET entryStage TO STAGE:NUMBER.
                _aerobrakeOrient().
                LOCAL assistPlan IS aerobrakeApAssist(atmHeight,peLow,peHigh,assistPe).
                IF phaseShouldYield { RETURN. }
                IF assistPlan["OK"] AND assistPlan["ENTERED"] {
                    SET inPass TO TRUE.
                    SET passNum TO passNum+1.
                    mLog("STATS aerobrake pass=" + passNum + " in powered=true").
                } ELSE IF assistPlan["OK"] AND SHIP:ALTITUDE > atmHeight {
                    // A pre-entry finite burn can move the interface by
                    // minutes. Replace the pre-burn alarm on the new conic.
                    SET entryUt TO _aerobrakeSetEntryAlarm().
                }
                aerobrakeApObserve(atmHeight).
            }
            _aerobrakeOrient().
            // The engine/forecast may change while waiting, even after a
            // skipped assist. Re-enter planning on an operator separation;
            // do not clear the once-per-pass latch or burn inside atmosphere.
            IF _aerobrakeAwaitEntry(atmHeight,inPass,entryStage) {
                IF NOT thrustCutoffOk() { RETURN. }
                mLog("STATS aerobrake-assist status=stage-changed-replan oldStage="
                    + entryStage + " newStage=" + STAGE:NUMBER).
                SET entryUt TO _aerobrakeSetEntryAlarm().
            }
            IF ABORT OR phaseShouldYield {
                IF thrustCutoffOk() { yieldToPrompt(). }
                RETURN.
            }
        } ELSE {
            IF NOT inPass {
                SET inPass TO TRUE.
                SET passNum TO passNum + 1.
                mLog("STATS aerobrake pass=" + passNum + " in"
                    + " entryKm=" + ROUND(SHIP:ALTITUDE / 1000, 1)
                    + " vel=" + ROUND(SHIP:VELOCITY:ORBIT:MAG, 0)).
            }
            // In a pass: heat-shield-forward, let drag bleed the energy.
            UNTIL SHIP:ALTITUDE > atmHeight
                OR _aerobrakeThroughThickPart(atmHeight)
                OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
                _aerobrakeOrient().
                aerobrakeApObserve(atmHeight).
                WAIT 1.
            }
        }
    }

    mLog("STATS aerobrake status=complete passes=" + passNum
        + " body=" + SHIP:BODY:NAME).
    _aerobrakeAdvance().
}

// Resident wait, responsive to manual separation before atmospheric entry.
// Stage changes during an actual pass remain under the powered cutoff and
// heat-shield guidance; only a fresh outside-atmosphere plan can use them.
LOCAL FUNCTION _aerobrakeAwaitEntry {
    PARAMETER atmHeight.
    PARAMETER inPass.
    PARAMETER entryStage.
    UNTIL SHIP:ALTITUDE < atmHeight OR inPass OR ABORT OR phaseShouldYield
            OR STAGE:NUMBER <> entryStage
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        WAIT 0.5.
    }
    RETURN NOT ABORT AND NOT phaseShouldYield AND NOT inPass
        AND SHIP:ALTITUDE > atmHeight AND STAGE:NUMBER <> entryStage
        AND SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "SPLASHED".
}

// Through the dangerous fast/thick regime: captured into a sub-atmosphere
// orbit (won't climb back out) AND slowed below the safe handoff speed.
// A negative/huge apoapsis (still hyperbolic, or a high ellipse needing
// more passes) reads as NOT yet captured.
LOCAL FUNCTION _aerobrakeThroughThickPart {
    PARAMETER atmHeight.
    IF SHIP:ALTITUDE > atmHeight { RETURN FALSE. }
    LOCAL ap IS SHIP:ORBIT:APOAPSIS.
    LOCAL captured IS ap > 0 AND ap < atmHeight.
    RETURN captured AND SHIP:AIRSPEED < AEROBRAKE_HANDOFF_SPEED.
}

// Retract deployable antennas before the airstream snaps them off.
LOCAL FUNCTION _aerobrakeRetractAntennas {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL m IS p:GETMODULE("ModuleDeployableAntenna").
            IF m:HASEVENT("retract antenna") {
                m:DOEVENT("retract antenna").
                SET retracted TO retracted + 1.
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " antenna(s) before aerobraking.").
        WAIT 3.
    }
}

// Retract deployable solar panels before the airstream snaps them off.
LOCAL FUNCTION _aerobrakeRetractSolarPanels {
    LOCAL retracted IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL m IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF m:HASEVENT("Retract Solar Panel") {
                m:DOEVENT("Retract Solar Panel").
                SET retracted TO retracted + 1.
            }
        }
    }
    IF retracted > 0 {
        mLog("Retracted " + retracted + " solar panel(s) before aerobraking.").
        WAIT 3.
    }
}

// Close tagged ('extend_bay') service bays before entry.
LOCAL FUNCTION _aerobrakeCloseExtendBays {
    LOCAL closed IS 0.
    FOR p IN SHIP:PARTSTAGGED("extend_bay") {
        IF p:HASMODULE("ModuleAnimateGeneric") {
            LOCAL bm IS p:GETMODULE("ModuleAnimateGeneric").
            IF bm:HASEVENT("Close") { bm:DOEVENT("Close"). SET closed TO closed + 1. }
            ELSE IF bm:HASEVENT("Close Doors") { bm:DOEVENT("Close Doors"). SET closed TO closed + 1. }
            ELSE IF bm:HASEVENT("Retract") { bm:DOEVENT("Retract"). SET closed TO closed + 1. }
        }
    }
    IF closed > 0 {
        mLog("Closed " + closed + " extend bay(s) before aerobraking.").
        WAIT 1.
    }
}

// Capture braking burn (AEROBRAKE-only): burn retrograde just long enough
// to drop from a hyperbolic pass into a bound orbit, then let aerobraking
// finish. Stops on capture (ecc<1), fuel exhaustion, the Pe floor, or
// landing — so it can't run away and drive Pe negative.
LOCAL FUNCTION _aerobrakeCaptureStop {
    PARAMETER control.
    LOCAL reason IS aerobrakeBurnFrameReason(control).
    IF reason <> "" { RETURN reason. }
    IF NOT (STAGE:LIQUIDFUEL+STAGE:OXIDIZER > 0.1) { RETURN "fuel-exhausted". }
    IF SHIP:ORBIT:ECCENTRICITY < 1 { RETURN "captured". }
    IF NOT (SHIP:ORBIT:ECCENTRICITY >= 1 AND SHIP:ORBIT:ECCENTRICITY < 1e30) { RETURN "invalid-orbit". }
    IF NOT (SHIP:PERIAPSIS >= control["FLOOR"]) { RETURN "pe-below-reentry-floor". }
    IF NOT (SHIP:ALTITUDE > control["ATMO"]) { RETURN "returned-to-atmosphere". }
    RETURN "".
}

LOCAL FUNCTION _aerobrakeCaptureThrottle {
    PARAMETER command.
    PARAMETER control.
    IF control["REASON"] <> "" { RETURN 0. }
    SET control["REASON"] TO _aerobrakeCaptureStop(control).
    IF NOT (ABS(command) < 1e30) { SET control["REASON"] TO "invalid-command". }
    IF control["REASON"] <> "" { RETURN 0. }
    IF NOT aerobrakeBurnAligned(control)
            OR NOT (VANG(control["DIR"],-SHIP:VELOCITY:ORBIT) <= 5) {
        SET control["REASON"] TO "alignment-or-energy". RETURN 0.
    }
    RETURN MAX(0,MIN(1,command)).
}

LOCAL FUNCTION _aerobrakeBrakingBurn {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF NOT thrustCutoffOk(FALSE) { RETURN FALSE. }
    IF SHIP:ORBIT:ECCENTRICITY < 1 { RETURN TRUE. }
    LOCAL atmHeight IS _aerobrakeAtmoHeight().
    LOCAL peFloor IS atmHeight * 0.4.
    IF AEROBRAKE_BRAKE_PE_FLOOR >= 0 { SET peFloor TO AEROBRAKE_BRAKE_PE_FLOOR. }
    LOCAL engine IS aerobrakeBurnEngine().
    IF NOT (atmHeight > 0 AND engine["VE"] > 0 AND engine["VE"] < 1e30
            AND engine["THRUST"] > 0 AND engine["THRUST"] < 1e30) {
        mLogError("Emergency capture: unavailable atmosphere/controllable engine; no burn.").
        yieldToPrompt(). RETURN FALSE.
    }
    LOCAL priorDeferral IS LOG_ARCHIVE_DEFERRED.
    SET LOG_ARCHIVE_DEFERRED TO 1.
    aerobrakeBurnCpuBegin().
    stateSet("aerobrake_capture_active",TRUE).
    LOCAL started IS TIME:SECONDS.
    LOCAL control IS LEXICON("BODY",SHIP:BODY:NAME,"STAGE",STAGE:NUMBER,
        "UPDATED",started,"DEADLINE",started+60,"REASON","","PEAK_FACING_ERR",0,
        "DIR",-SHIP:VELOCITY:ORBIT,"FLOOR",peFloor,"ATMO",atmHeight).
    SAS OFF.
    // Re-read orbital velocity in the steering lock, rather than storing
    // a Direction snapshot that becomes wrong as the velocity turns.
    LOCK STEERING TO -SHIP:VELOCITY:ORBIT.
    mLog("STATS aerobrake-capture align status=begin Pe=" + SHIP:PERIAPSIS
        + " peFloor=" + peFloor + " stage=" + control["STAGE"]).
    UNTIL control["REASON"] <> "" OR aerobrakeBurnAligned(control) {
        SET control["DIR"] TO -SHIP:VELOCITY:ORBIT.
        SET control["UPDATED"] TO TIME:SECONDS.
        SET control["REASON"] TO _aerobrakeCaptureStop(control).
        IF control["REASON"] = "" { WAIT 0.05. }
    }
    // At full throttle, burning the entire wet mass would take m/flow.
    // This deliberately generous physical upper bound avoids an arbitrary
    // duration cap on a weak engine. Real fuel exhaustion stops sooner.
    SET control["DEADLINE"] TO TIME:SECONDS+engine["VE"]*SHIP:MASS/engine["THRUST"]+5.
    SET control["UPDATED"] TO TIME:SECONDS.
    LOCAL command IS 1.
    LOCK THROTTLE TO _aerobrakeCaptureThrottle(command,control).
    UNTIL control["REASON"] <> "" {
        // Check the old publication time before refreshing it. Both this
        // check and the throttle lock latch a stale publisher at zero.
        IF TIME:SECONDS-control["UPDATED"] > 0.5 { SET control["REASON"] TO "stale-control". }
        SET control["DIR"] TO -SHIP:VELOCITY:ORBIT.
        SET control["UPDATED"] TO TIME:SECONDS.
        LOCAL checked IS _aerobrakeCaptureThrottle(command,control).
        IF control["REASON"] = "" { WAIT 0.05. }
    }
    SET command TO 0.
    IF NOT thrustCutoffOk() { RETURN FALSE. }
    aerobrakeBurnCpuEnd().
    stateSet("aerobrake_capture_active",FALSE).
    LOCK STEERING TO SHIP:SRFRETROGRADE.
    SET LOG_ARCHIVE_DEFERRED TO priorDeferral.
    mLog("STATS aerobrake-capture result reason=" + control["REASON"]
        + " elapsed=" + (TIME:SECONDS-started) + " peakFacingErr=" + control["PEAK_FACING_ERR"]
        + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY,3)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)).
    IF control["REASON"] <> "captured" {
        mLogError("Emergency capture incomplete; review trajectory, attitude and fuel before resuming.").
        yieldToPrompt(). RETURN FALSE.
    }
    RETURN TRUE.
}

// Alarm the next inbound atmosphere crossing from the live conic and return
// its UT. Returns -1 for an airless body or no future crossing. No POSITIONAT
// frame prediction and no fixed time offset from periapsis.
LOCAL FUNCTION _aerobrakeSetEntryAlarm {
    LOCAL atmAlt IS _aerobrakeAtmoHeight().
    IF atmAlt <= 0 { RETURN -1. }
    // Share the actual next inbound conic crossing with assist planning,
    // including an outbound ellipse after a skip. No fixed Pe-minus120s.
    LOCAL entryEta IS aerobrakeApEntryEta(atmAlt).
    IF NOT (entryEta > 0 AND entryEta < 1e30) {
        mLog("STATS aerobrake entry-alarm status=no-future-crossing body=" + SHIP:BODY:NAME).
        RETURN -1.
    }
    LOCAL entryUt IS TIME:SECONDS + entryEta.

    IF ADDONS:KAC:AVAILABLE {
        LOCAL alarmId IS kacEnsureAlarm("Atmo entry: " + SHIP:BODY:NAME,
            entryUt,
            "Atmosphere at " + ROUND(atmAlt/1000, 0) + "km").
        IF alarmId <> "" {
            mLog("KAC alarm set for atmosphere entry in "
                + ROUND(entryUt - TIME:SECONDS, 0) + "s"
                + " (" + SHIP:BODY:NAME + " atmo=" + ROUND(atmAlt/1000, 0) + "km).").
        }
    }
    mLog("STATS aerobrake entry-alarm entryUt=" + entryUt + " eta=" + entryEta
        + " prepareUt=" + (entryUt-AEROBRAKE_ENTRY_LEAD)
        + " body=" + SHIP:BODY:NAME + " kac=" + ADDONS:KAC:AVAILABLE).
    RETURN entryUt.
}

// Orient for solar and hold (auto-warping) until `wakeUt`, then return so
// the caller can get ready for entry. No-op if already in the atmosphere
// or wakeUt is already here.
LOCAL FUNCTION _aerobrakeSolarWait {
    PARAMETER wakeUt.
    PARAMETER wakeAlarm IS "".
    LOCAL atmHeight IS _aerobrakeAtmoHeight().
    IF atmHeight > 0 AND SHIP:ALTITUDE < atmHeight { RETURN. }
    IF wakeUt <= TIME:SECONDS + 30 { RETURN. }

    LOCAL coastBody IS SHIP:BODY.
    LOCAL ownsAlarm IS wakeAlarm = "".
    IF ownsAlarm {
        SET wakeAlarm TO kacEnsureAlarm("Aerobrake coast wake",wakeUt,
            "Running aerobrake wakes for entry preparation.",1).
    }
    LOCAL solarRef IS -1.
    LOCAL canWarp IS TRUE.
    LOCAL hasPanels IS FALSE.
    IF PHASES_HAS_SOLAR { SET hasPanels TO shipHasSolarPanels(). }
    IF PHASES_HAS_SOLAR AND hasPanels {
        // A health tick may simply accept nonzero flow without steering.
        // Initialize the hold explicitly, off rails, before considering warp.
        SET WARP TO 0.
        WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
        UNLOCK STEERING.
        mLog("Aerobrake: aiming for solar; wake in T+" + ROUND(wakeUt-TIME:SECONDS,0) + "s.").
        LOCAL aimed IS orientForSolar(FALSE,TRUE,TRUE,wakeUt).
        SET solarRef TO shipSolarFlow().
        SET canWarp TO aimed AND (solarRef > 0 OR shipPowerFraction() >= SOLAR_HOLD_EC).
        mLog("STATS aerobrake solar aimed=" + aimed + " flow=" + solarRef
            + " canWarp=" + canWarp + " wakeUt=" + wakeUt).
    } ELSE {
        LOCAL reason IS "solar-library-not-loaded".
        IF PHASES_HAS_SOLAR { SET reason TO "no-supported-solar-panels". }
        mLogWarn("STATS aerobrake solar status=unavailable coasting-without-solar-aim"
            + " reason=" + reason + " helperLoaded=" + PHASES_HAS_SOLAR + " panels=" + hasPanels).
    }
    IF canWarp AND wakeAlarm <> "" AND NOT ABORT AND NOT phaseShouldYield {
        coastAutoWarp(wakeUt, "Aerobrake coast", wakeAlarm).
    }
    UNTIL TIME:SECONDS >= wakeUt
            OR ABORT OR phaseShouldYield
            OR SHIP:BODY <> coastBody
            OR (atmHeight > 0 AND SHIP:ALTITUDE < atmHeight)
            OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        SET solarRef TO trySolarHoldTick(solarRef,wakeUt).
        IF TIME:SECONDS >= wakeUt { BREAK. }
        WAIT MIN(10, MAX(1, wakeUt - TIME:SECONDS)).
    }
    IF WARP > 0 {
        SET WARP TO 0.
        WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
        WAIT 1.
    }
    IF ownsAlarm AND wakeAlarm <> "" { DELETEALARM(wakeAlarm). }
    mLog("Aerobrake: waking up to get ready for entry.").
}

// The same periapsis target governs powered energy reduction and the
// between-pass repair. Spend the protected repair allowance at apoapsis,
// not by chasing the osculating Pe while drag is acting in atmosphere.
LOCAL FUNCTION _aerobrakeRestorePe {
    PARAMETER atmHeight, targetPe, peLow, peHigh.
    IF AEROBRAKE_PE_TARGETING <= 0 OR ABORT OR phaseShouldYield { RETURN NOT ABORT AND NOT phaseShouldYield. }
    // A reboot can interrupt goal verification after an otherwise good Pe
    // repair. Only its recorded intent permits automatic reconciliation.
    IF maneuverBurnInterrupted() { reentryPeRecover(targetPe,peLow,peHigh). }
    IF HASNODE OR maneuverBurnInterrupted() {
        mLogError("Aerobrake Pe repair blocked by an existing/interrupted maneuver.").
        PRINT "If this was a completed Pe repair with a tiny residual, run cmd/reentryresume.ks to verify the current orbit.".
        yieldToPrompt(). RETURN FALSE.
    }
    IF SHIP:ALTITUDE <= atmHeight OR SHIP:APOAPSIS <= atmHeight
            OR NOT (SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1)
            OR ABS(SHIP:PERIAPSIS-targetPe) <= 250
            OR VDOT(SHIP:POSITION-SHIP:BODY:POSITION,SHIP:VELOCITY:ORBIT) <= 0 { RETURN TRUE. }
    IF SHIP:DELTAV:VACUUM <= 0.5 {
        mLogWarn("STATS aerobrake pe-repair status=passive reason=insufficient-fuel Pe=" + SHIP:PERIAPSIS).
        RETURN TRUE.
    }
    LOCAL repairBody IS SHIP:BODY.
    LOCAL wakeUt IS TIME:SECONDS+ETA:APOAPSIS-180.
    IF NOT (ETA:APOAPSIS > 30 AND ETA:APOAPSIS < 1e30)
            OR SHIP:ORBIT:HASNEXTPATCH { RETURN TRUE. }
    IF wakeUt > TIME:SECONDS+30 {
        LOCAL alarm IS kacEnsureAlarm("Aerobrake Pe repair",wakeUt,
            "Wake before apoapsis to restore the configured entry periapsis.",1).
        mLog("STATS aerobrake pe-repair status=waiting targetPe=" + targetPe
            + " Pe=" + SHIP:PERIAPSIS + " wakeUt=" + wakeUt + " alarm=" + alarm).
        _aerobrakeSolarWait(wakeUt,alarm).
        IF alarm <> "" { DELETEALARM(alarm). }
    }
    IF ABORT OR phaseShouldYield OR SHIP:BODY <> repairBody
            OR SHIP:ALTITUDE <= atmHeight OR HASNODE
            OR SHIP:ORBIT:HASNEXTPATCH {
        mLogError("Aerobrake Pe repair coast interrupted; no repair burn.").
        yieldToPrompt(). RETURN FALSE.
    }
    IF MIN(SHIP:DELTAV:VACUUM,STAGE:DELTAV:VACUUM) <= 1 {
        // Repair is a vacuum job before apoapsis, not authorization to
        // enter on this Pe. Allow measured drift in this COAST check;
        // hardware/depletion/CPU/chute guards and the subsequent repair
        // node's strict requested corridor remain mandatory.
        aerobrakeApStageCoast(atmHeight,MIN(peLow,SHIP:PERIAPSIS-1000),MAX(peHigh,SHIP:PERIAPSIS+1000)).
        IF phaseShouldYield { RETURN FALSE. }
    }
    LOCAL repair IS restoreEntryPe(targetPe,peLow,peHigh).
    IF NOT repair["OK"] {
        IF repair["REASON"] = "insufficient-fuel" {
            mLogWarn("STATS aerobrake pe-repair status=passive reason=insufficient-fuel Pe=" + SHIP:PERIAPSIS).
            RETURN TRUE.
        }
        mLogError("STATS aerobrake pe-repair status=hold reason=" + repair["REASON"]).
        yieldToPrompt(). RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _aerobrakeAtmoHeight {
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN -1. }

    LOCAL atmAlt IS SHIP:BODY:ATM:HEIGHT.
    IF ATM_HEIGHTS:HASKEY(SHIP:BODY:NAME) {
        SET atmAlt TO ATM_HEIGHTS[SHIP:BODY:NAME].
    }
    RETURN atmAlt.
}

LOCAL FUNCTION _aerobrakeTargetingWindowOk {
    PARAMETER label.

    LOCAL atmAlt IS _aerobrakeAtmoHeight().
    IF atmAlt < 0 { RETURN TRUE. }

    LOCAL skipAlt IS atmAlt * TARGETING_ATMO_SKIP_MULT.
    IF SHIP:ALTITUDE <= skipAlt {
        mLog(label + " skipped: already within 10% of atmosphere altitude "
            + "(alt=" + ROUND(SHIP:ALTITUDE/1000, 1)
            + "km atmo=" + ROUND(atmAlt/1000, 1) + "km).").
        RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _aerobrakeAdvance {
    LOCAL current IS stateGet("phase", "AEROBRAKE").
    IF xferSeq:CONTAINS(current) {
        RETURN nextPhase(xferSeq).
    }

    LOCAL fallback IS "DESCENT".
    LOCAL requiredBand IS bootLibBandForPhase(fallback, fallback).
    mLogWarn("AEROBRAKE phase is not in the active sequence; "
        + "falling through to " + fallback + ".").
    archivePhaseLog().
    stateSet("phase", fallback).
    stateSaveReloadState("AEROBRAKE_FALLBACK", fallback, requiredBand).
    mLogWarn("Aerobrake complete; rebooting into band " + requiredBand + ".").
    WAIT 2.
    REBOOT.
    RETURN fallback.
}

// ============================================================
// Reentry targeting — small Pe cleanup plus Trajectories impact burn
//
// Pe cleanup uses a tiny prograde-only node. Impact-site targeting
// creates a small correction node and uses coordinate search over
// TIME, RADIAL, NORMAL to minimize distance to KSC.
// ============================================================
LOCAL FUNCTION _aerobrakeTrimReentryPe {
    IF NOT _aerobrakeTargetingWindowOk("Aerobrake Pe trim") { RETURN. }

    LOCAL targetPe IS REENTRY_PE.
    IF AEROBRAKE_PE >= 0 { SET targetPe TO AEROBRAKE_PE. }
    IF targetPe < 0 {
        mLog("Aerobrake Pe trim disabled: target Pe < 0.").
        RETURN.
    }

    LOCAL currentPe IS SHIP:PERIAPSIS.
    LOCAL peErr IS currentPe - targetPe.
    IF ABS(peErr) <= PE_CORRECTION_TOLERANCE {
        mLog("Reentry Pe already within tolerance: Pe="
            + ROUND(currentPe/1000, 1) + "km target="
            + ROUND(targetPe/1000, 1) + "km.").
        RETURN.
    }

    LOCAL maxPeChange IS SHIP:BODY:RADIUS * MAX_PE_CORRECTION_FRACTION.
    IF ABS(peErr) > maxPeChange {
        mLogWarn("Aerobrake Pe trim skipped: requested Pe change "
            + ROUND(ABS(peErr)/1000, 1) + "km exceeds "
            + ROUND(maxPeChange/1000, 1) + "km cap ("
            + ROUND(MAX_PE_CORRECTION_FRACTION * 100, 1)
            + "% body radius).").
        mLog("STATS aerobrake pe-trim status=skipped reason=pe-change-cap"
            + " startPeKm=" + ROUND(currentPe/1000, 1)
            + " targetPeKm=" + ROUND(targetPe/1000, 1)
            + " maxChangeKm=" + ROUND(maxPeChange/1000, 1)).
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + 60, 0, 0, 0).
    ADD nd.
    WAIT 0.2.

    LOCAL bestPro IS 0.
    LOCAL bestPe IS nd:ORBIT:PERIAPSIS.
    LOCAL bestErr IS ABS(bestPe - targetPe).
    LOCAL startPe IS bestPe.
    LOCAL startErr IS bestErr.
    LOCAL proStep IS 2.
    LOCAL signs IS LIST(1, -1).

    mLog("Reentry Pe trim: current=" + ROUND(currentPe/1000, 1)
        + "km target=" + ROUND(targetPe/1000, 1)
        + "km.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= MAX_TARGETING_SCANS STEP { SET iter TO iter + 1. } DO {
        LOCAL improved IS FALSE.
        LOCAL trialBestPro IS bestPro.
        LOCAL trialBestPe IS bestPe.
        LOCAL trialBestErr IS bestErr.

        FOR sign IN signs {
            LOCAL tryPro IS bestPro + sign * proStep.
            IF ABS(tryPro) <= MAX_CORRECTION_DV {
                SET nd:PROGRADE TO tryPro.
                WAIT 0.1.
                LOCAL tryPe IS nd:ORBIT:PERIAPSIS.
                LOCAL tryErr IS ABS(tryPe - targetPe).
                IF tryErr < trialBestErr {
                    SET trialBestPro TO tryPro.
                    SET trialBestPe TO tryPe.
                    SET trialBestErr TO tryErr.
                }
            }
        }

        IF trialBestErr < bestErr {
            SET bestPro TO trialBestPro.
            SET bestPe TO trialBestPe.
            SET bestErr TO trialBestErr.
            SET improved TO TRUE.
            mLog("  pe-trim[" + iter + "] Pe=" + ROUND(bestPe/1000, 2)
                + "km err=" + ROUND(bestErr/1000, 2)
                + "km P=" + ROUND(bestPro, 2)).
        }

        IF bestErr <= PE_CORRECTION_TOLERANCE { BREAK. }

        IF NOT improved {
            SET proStep TO proStep / 2.
            IF proStep < 0.02 { BREAK. }
        }
    }

    SET nd:PROGRADE TO bestPro.
    WAIT 0.2.

    LOCAL totalDv IS nd:DELTAV:MAG.
    IF bestErr >= startErr OR totalDv < 0.2 {
        mLog("Reentry Pe trim not useful — skipping burn.").
        mLog("STATS aerobrake pe-trim status=skipped reason=no-useful-node"
            + " startPeKm=" + ROUND(startPe/1000, 1)
            + " targetPeKm=" + ROUND(targetPe/1000, 1)
            + " predictPeKm=" + ROUND(bestPe/1000, 1)
            + " dv=" + ROUND(totalDv, 2)).
        REMOVE nd.
        RETURN.
    }

    mLog("Reentry Pe trim: predicted Pe=" + ROUND(bestPe/1000, 1)
        + "km dV=" + ROUND(totalDv, 2) + " m/s.").
    mLog("STATS aerobrake pe-trim status=planned"
        + " startPeKm=" + ROUND(currentPe/1000, 1)
        + " targetPeKm=" + ROUND(targetPe/1000, 1)
        + " predictPeKm=" + ROUND(bestPe/1000, 1)
        + " errKm=" + ROUND(bestErr/1000, 2)
        + " dv=" + ROUND(totalDv, 2)
        + " prograde=" + ROUND(bestPro, 2)).

    LOCAL success IS executeManeuver().
    IF NOT success {
        mLogWarn("Reentry Pe trim burn failed.").
        IF HASNODE { REMOVE NEXTNODE. }
        RETURN.
    }

    WAIT 1.
    mLog("Post-trim Pe=" + ROUND(SHIP:PERIAPSIS/1000, 1)
        + "km target=" + ROUND(targetPe/1000, 1) + "km.").
    mLog("STATS aerobrake pe-trim status=complete"
        + " finalPeKm=" + ROUND(SHIP:PERIAPSIS/1000, 1)
        + " targetPeKm=" + ROUND(targetPe/1000, 1)
        + " dv=" + ROUND(totalDv, 2)).
}

LOCAL FUNCTION _aerobrakeCorrectionPeOk {
    PARAMETER pe.
    RETURN (AEROBRAKE_CORRECTION_PE_MIN < 0 OR pe >= AEROBRAKE_CORRECTION_PE_MIN)
        AND (AEROBRAKE_CORRECTION_PE_MAX < 0 OR pe <= AEROBRAKE_CORRECTION_PE_MAX).
}

LOCAL FUNCTION _aerobrakeReentryTargeting {
    IF NOT _aerobrakeTargetingWindowOk("Aerobrake reentry targeting") { RETURN. }

    // Resolve the landing target (waypoint / locked / config). On
    // Kerbin with nothing set, default to KSC (preserves return-to-
    // Kerbin behavior); on any other body refuse to target without an
    // explicit site rather than blindly aiming at KSC's coordinates
    // on, e.g., Duna.
    LOCAL tgt IS landingResolveTarget().
    LOCAL tgtLat IS KSC_LAT.
    LOCAL tgtLng IS KSC_LNG.
    IF tgt["FOUND"] {
        SET tgtLat TO tgt["LAT"].
        SET tgtLng TO tgt["LNG"].
        mLog("Aerobrake target: " + tgt["SOURCE"] + " "
            + ROUND(tgtLat, 3) + "," + ROUND(tgtLng, 3) + ".").
    } ELSE IF SHIP:BODY:NAME = "Kerbin" {
        mLog("Aerobrake target: KSC default.").
    } ELSE {
        mLogWarn("Aerobrake: no landing target on " + SHIP:BODY:NAME
            + " — skipping reentry targeting (untargeted entry).").
        RETURN.
    }
    LOCAL targetGeo IS LATLNG(tgtLat, tgtLng).
    ADDONS:TR:SETTARGET(targetGeo).
    WAIT 0.5.

    IF NOT ADDONS:TR:HASIMPACT {
        // Don't warp/wait for a TR impact. Far out on a fast return TR
        // can't resolve one, and we're committed to entering the
        // atmosphere regardless — sitting here warping the approach down
        // just delays orienting for reentry. Skip the KSC impact-site
        // correction; the phase orients and hands off to DESCENT. The
        // correction only runs when TR already has an impact in hand.
        mLogWarn("Aerobrake: Trajectories has no impact prediction — "
            + "skipping KSC impact-site correction (committed to entry).").
        RETURN.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS geoDistance(impactPos:LAT, impactPos:LNG, tgtLat, tgtLng).
    mLog("Reentry: current impact " + ROUND(impactPos:LAT, 2) + "," + ROUND(impactPos:LNG, 2)
        + "  dist=" + ROUND(dist/1000, 1) + "km from target.").
    mLog("STATS aerobrake pre-correction distKm=" + ROUND(dist/1000, 1)
        + " impact=" + ROUND(impactPos:LAT, 4) + "," + ROUND(impactPos:LNG, 4)).

    IF dist < CORRECTION_TOLERANCE {
        mLog("Impact already within tolerance — no correction needed.").
        RETURN.
    }

    // Correction node well ahead of now: the coordinate search below
    // takes ~70s, and a 60s node had its window pass before executing
    // (flight-found "burn window already passed by 15s").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + 240, 0, 0, 0).
    ADD nd.
    WAIT 0.3.

    // Coordinate search over TIME, RADIAL, NORMAL
    LOCAL bestDist IS dist.
    LOCAL bestTime IS nd:TIME.
    LOCAL bestRad IS 0.
    LOCAL bestNor IS 0.
    LOCAL bestPro IS 0.

    LOCAL timeStep IS 30.
    LOCAL radialStep IS 2.
    LOCAL normalStep IS 2.
    LOCAL progradeStep IS 1.

    LOCAL axes IS LIST("TIME", "RADIAL", "NORMAL", "PROGRADE").
    LOCAL signs IS LIST(1, -1).

    mLog("Reentry correction: coordinate search from dist=" + ROUND(bestDist/1000, 1) + "km.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= MAX_TARGETING_SCANS STEP { SET iter TO iter + 1. } DO {
        LOCAL improved IS FALSE.
        LOCAL trialBestDist IS bestDist.
        LOCAL trialBestTime IS bestTime.
        LOCAL trialBestRad IS bestRad.
        LOCAL trialBestNor IS bestNor.
        LOCAL trialBestPro IS bestPro.

        FOR axis IN axes {
            FOR sign IN signs {
                LOCAL tryTime IS bestTime.
                LOCAL tryRad IS bestRad.
                LOCAL tryNor IS bestNor.
                LOCAL tryPro IS bestPro.

                IF axis = "TIME" { SET tryTime TO tryTime + sign * timeStep. }
                IF axis = "RADIAL" { SET tryRad TO tryRad + sign * radialStep. }
                IF axis = "NORMAL" { SET tryNor TO tryNor + sign * normalStep. }
                IF axis = "PROGRADE" { SET tryPro TO tryPro + sign * progradeStep. }

                // dV cap check
                IF SQRT(tryRad^2 + tryNor^2 + tryPro^2) > MAX_CORRECTION_DV {
                    // skip — would exceed correction budget
                } ELSE IF tryTime <= TIME:SECONDS + 30 {
                    // skip — too soon
                } ELSE {
                    SET nd:TIME TO tryTime.
                    SET nd:RADIALOUT TO tryRad.
                    SET nd:NORMAL TO tryNor.
                    SET nd:PROGRADE TO tryPro.
                    WAIT 0.2.

                    IF _aerobrakeCorrectionPeOk(nd:ORBIT:PERIAPSIS)
                            AND ADDONS:TR:HASIMPACT {
                        LOCAL tryImpact IS ADDONS:TR:IMPACTPOS.
                        LOCAL tryDist IS geoDistance(tryImpact:LAT, tryImpact:LNG, tgtLat, tgtLng).
                        IF tryDist < trialBestDist {
                            SET trialBestDist TO tryDist.
                            SET trialBestTime TO tryTime.
                            SET trialBestRad TO tryRad.
                            SET trialBestNor TO tryNor.
                            SET trialBestPro TO tryPro.
                        }
                    }
                }
            }
        }

        IF trialBestDist < bestDist {
            SET bestDist TO trialBestDist.
            SET bestTime TO trialBestTime.
            SET bestRad TO trialBestRad.
            SET bestNor TO trialBestNor.
            SET bestPro TO trialBestPro.
            SET improved TO TRUE.
            mLog("  reentry[" + iter + "] dist=" + ROUND(bestDist/1000, 1) + "km"
                + " R=" + ROUND(bestRad, 2) + " N=" + ROUND(bestNor, 2)
                + " P=" + ROUND(bestPro, 2)).
        }

        IF bestDist < CORRECTION_TOLERANCE { BREAK. }

        IF NOT improved {
            SET timeStep TO timeStep / 2.
            SET radialStep TO radialStep / 2.
            SET normalStep TO normalStep / 2.
            SET progradeStep TO progradeStep / 2.
            IF timeStep < 0.5 AND radialStep < 0.05
                    AND normalStep < 0.05 AND progradeStep < 0.02 { BREAK. }
        }
    }

    // Apply best solution
    SET nd:TIME TO bestTime.
    SET nd:RADIALOUT TO bestRad.
    SET nd:NORMAL TO bestNor.
    SET nd:PROGRADE TO bestPro.
    WAIT 0.2.

    LOCAL totalDv IS nd:DELTAV:MAG.
    mLog("Reentry correction: dist=" + ROUND(bestDist/1000, 1) + "km"
        + "  dV=" + ROUND(totalDv, 1) + " m/s").
    mLog("STATS aerobrake correction distKm=" + ROUND(bestDist/1000, 1)
        + " dv=" + ROUND(totalDv, 1)
        + " radial=" + ROUND(bestRad, 2)
        + " normal=" + ROUND(bestNor, 2)
        + " prograde=" + ROUND(bestPro, 2)).

    IF NOT _aerobrakeCorrectionPeOk(nd:ORBIT:PERIAPSIS) {
        mLogWarn("Impact correction outside entry Pe corridor — skipping burn.").
        REMOVE nd.
        RETURN.
    }
    IF totalDv < 0.5 {
        mLog("Correction too small — skipping burn.").
        REMOVE nd.
        RETURN.
    }

    // Execute the correction burn
    LOCAL success IS executeManeuver().
    IF NOT success {
        mLogWarn("Reentry correction burn failed.").
        IF HASNODE { REMOVE NEXTNODE. }
    }

    // Post-burn verification
    WAIT 1.
    IF ADDONS:TR:HASIMPACT {
        LOCAL finalImpact IS ADDONS:TR:IMPACTPOS.
        LOCAL finalDist IS geoDistance(finalImpact:LAT, finalImpact:LNG, tgtLat, tgtLng).
        mLog("Post-correction impact: " + ROUND(finalImpact:LAT, 2) + "," + ROUND(finalImpact:LNG, 2)
            + "  dist=" + ROUND(finalDist/1000, 1) + "km from target.").
        mLog("STATS aerobrake postburn distKm=" + ROUND(finalDist/1000, 1)
            + " impact=" + ROUND(finalImpact:LAT, 4) + "," + ROUND(finalImpact:LNG, 4)).
    }
}

// ============================================================
// Vessel prep helpers
// ============================================================

LOCAL FUNCTION _aerobrakeDecouple {
    IF AEROBRAKE_DECOUPLE_TAG = "" { RETURN. }
    LOCAL tag IS AEROBRAKE_DECOUPLE_TAG.
    LOCAL decouplers IS SHIP:PARTSTAGGED(tag).
    IF decouplers:LENGTH = 0 {
        mLogWarn("Decouple tag '" + tag + "' not found — skipping decouple.").
        RETURN.
    }
    FOR dc IN decouplers {
        IF dc:HASMODULE("ModuleDecouple") {
            dc:GETMODULE("ModuleDecouple"):DOEVENT("decouple").
            mLog("Decoupled: " + dc:TITLE + " (tag=" + tag + ")").
        } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
            dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("decouple").
            mLog("Decoupled: " + dc:TITLE + " (tag=" + tag + ")").
        }
    }
    WAIT 2.
}

LOCAL FUNCTION _aerobrakeEntryDirection {
    IF AEROBRAKE_REENTRY_DIR = "PROGRADE" { RETURN SHIP:SRFPROGRADE. }
    RETURN SHIP:SRFRETROGRADE.
}

LOCAL FUNCTION _aerobrakeOrient {
    SAS OFF.
    // A stored Direction is a snapshot. Keep both the steering lock and
    // alignment check live, including after this helper returns to coast.
    LOCK STEERING TO _aerobrakeEntryDirection().
    IF VANG(SHIP:FACING:FOREVECTOR,_aerobrakeEntryDirection():FOREVECTOR) < 2 { RETURN. }
    LOCAL mode IS "RETROGRADE".
    IF AEROBRAKE_REENTRY_DIR = "PROGRADE" { SET mode TO "PROGRADE". }
    mLog("Orienting " + mode + " for entry.").
    LOCAL startTime IS TIME:SECONDS.
    LOCAL timeout IS 60.
    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR,_aerobrakeEntryDirection():FOREVECTOR) < 2
        OR TIME:SECONDS > startTime + timeout.
    IF VANG(SHIP:FACING:FOREVECTOR,_aerobrakeEntryDirection():FOREVECTOR) < 2 {
        mLog("Oriented " + mode + " (error < 2°).").
    } ELSE {
        mLogWarn(mode + " alignment timed out.").
    }

    // LOCK STEERING stays active — phaseAerobrake will wait for
    // atmosphere entry and hand off to SAS before advancing.
    mLog(mode + " steering lock active.").
}

LOCAL FUNCTION _aerobrakeArmChutes {
    IF AEROBRAKE_ARM_CHUTES <= 0 { RETURN. }

    LOCAL armed IS 0.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleParachute") {
            LOCAL m IS p:GETMODULE("ModuleParachute").
            IF m:HASEVENT("arm parachute") {
                m:DOEVENT("arm parachute").
                SET armed TO armed + 1.
            }
        }
    }
    IF armed > 0 {
        mLog("Armed " + armed + " parachute(s).").
    }
}
