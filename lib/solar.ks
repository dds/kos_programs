// ============================================================
// solar.ks  —  Solar attitude + power readouts  (0:/lib/solar.ks)
//
// Small and standalone on purpose: anything that spends time in
// space can load it. orientForSolar finds the attitude that
// maximizes MEASURED panel energy flow (no assumption about the
// panel layout) and can keep steering locked. Power readers included
// for telemetry; electrical management itself belongs to AmpYear.
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL SOLAR_HOLD_RATIO IS 0.92.
GLOBAL SOLAR_REUSE_RATIO IS 0.90.
GLOBAL SOLAR_HOLD_EC IS 0.75.
GLOBAL SOLAR_AIM_TIMEOUT IS 90.
GLOBAL SOLAR_SEARCH_TIMEOUT IS 300.
GLOBAL SOLAR_AIM_TOLERANCE IS 5.
GLOBAL SOLAR_HOLD_TOLERANCE IS 10.
GLOBAL SOLAR_MIN_IPU IS 2000.
GLOBAL SOLAR_SEARCH_SKIP_FIRST_BOOT IS 1.
GLOBAL SOLAR_SEARCH_LAUNCH_GUARD IS 300.
GLOBAL SOLAR_SEARCH_KSC_RADIUS IS 10000.
GLOBAL SOLAR_CHARGE_CHECK_DT IS 5.
GLOBAL SOLAR_CHARGE_CHECK_MIN_DELTA IS 0.01.
GLOBAL SOLAR_CHARGE_FULL_EC IS 0.995.

IF DEFINED PHASES_HAS_SOLAR { SET PHASES_HAS_SOLAR TO TRUE. }

// Command-core hibernation is handled by the stock "Hibernate in
// Warp" part toggle (set in the VAB), so this lib no longer pokes it.

// Sum of "energy flow" over all solar panels (falls back to
// "sun exposure"); -1 when no readable panel fields exist.
GLOBAL FUNCTION shipSolarFlow {
    LOCAL total IS -1.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL m IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF m:HASFIELD("energy flow") {
                SET total TO MAX(total, 0) + m:GETFIELD("energy flow").
            } ELSE IF m:HASFIELD("sun exposure") {
                SET total TO MAX(total, 0) + m:GETFIELD("sun exposure").
            }
        }
    }
    RETURN total.
}

GLOBAL FUNCTION shipHasSolarPanels {
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") { RETURN TRUE. }
    }
    RETURN FALSE.
}

LOCAL FUNCTION _shipElectricChargeAmount {
    LOCAL stored IS 0.
    FOR res IN SHIP:RESOURCES {
        IF res:NAME = "ElectricCharge" {
            SET stored TO stored + res:AMOUNT.
        }
    }
    RETURN stored.
}

LOCAL FUNCTION _shipElectricChargeCapacity {
    LOCAL cap IS 0.
    FOR res IN SHIP:RESOURCES {
        IF res:NAME = "ElectricCharge" {
            SET cap TO cap + res:CAPACITY.
        }
    }
    RETURN cap.
}

GLOBAL FUNCTION shipPowerFraction {
    LOCAL cap IS _shipElectricChargeCapacity().
    IF cap > 0 { RETURN _shipElectricChargeAmount() / cap. }
    RETURN 1.
}

// True when the ship's net ElectricCharge rises over dT seconds.
// minDelta is in EC units and filters tiny readout jitter.
GLOBAL FUNCTION shipBatteriesCharging {
    PARAMETER dT IS 5.
    PARAMETER minDelta IS 0.01.

    IF _shipElectricChargeCapacity() <= 0 { RETURN FALSE. }
    LOCAL startEc IS _shipElectricChargeAmount().
    IF dT > 0 { WAIT dT. }
    RETURN _shipElectricChargeAmount() > startEc + minDelta.
}

// Fix the full attitude for this turn, then follow only the Sun's motion.
// Reading SHIP:FACING inside the lock moves the goal as the craft turns.
LOCAL FUNCTION _solarAim {
    PARAMETER aShip.
    LOCAL facing IS SHIP:FACING.
    LOCAL toSun IS SUN:POSITION.
    LOCAL aim IS LEXICON("SUN", toSun,
        "FACING", ROTATEFROMTO(facing * aShip, toSun) * facing).
    LOCK STEERING TO _solarAimDirection(aim).
    RETURN aim.
}

LOCAL FUNCTION _solarAimDirection {
    PARAMETER aim.
    RETURN ROTATEFROMTO(aim["SUN"], SUN:POSITION) * aim["FACING"].
}

// Aim the axis at the Sun and wait until the ship is BOTH pointed and
// has stopped rotating before returning — measuring flow mid-slew is
// what made the coarse search bleed one axis's reading into the next.
LOCAL FUNCTION _solarAimSettle {
    PARAMETER aShip.
    PARAMETER deadlineUt IS 0.
    PARAMETER keepOnFailure IS TRUE.
    PARAMETER label IS "axis".
    PARAMETER tolerance IS SOLAR_AIM_TOLERANCE.
    LOCAL began IS TIME:SECONDS.
    LOCAL deadline IS began + SOLAR_AIM_TIMEOUT.
    LOCAL timeoutReason IS "alignment-timeout".
    IF deadlineUt > 0 AND deadlineUt-1.5 <= deadline {
        SET deadline TO deadlineUt-1.5.
        SET timeoutReason TO "search-deadline".
    }
    IF TIME:SECONDS >= deadline {
        mLogWarn("STATS solar aim label=" + label + " status=deadline-before-aim").
        IF NOT keepOnFailure { UNLOCK STEERING. }
        RETURN FALSE.
    }
    LOCAL startError IS VANG(SHIP:FACING * aShip,SUN:POSITION).
    mLog("STATS solar aim label=" + label + " status=begin err=" + ROUND(startError,2)
        + " tolerance=" + tolerance + " budget=" + ROUND(deadline-began,2) + " warp=" + WARP).
    LOCAL aim IS _solarAim(aShip).
    LOCAL nextSample IS TIME:SECONDS.
    UNTIL TIME:SECONDS >= deadline OR ABORT {
        IF TIME:SECONDS >= nextSample {
            solarDiagnosticSample(label,"turning",aShip,_solarAimDirection(aim)).
            SET nextSample TO TIME:SECONDS + 5.
        }
        IF VANG(SHIP:FACING * aShip, SUN:POSITION) <= tolerance
                AND SHIP:ANGULARVEL:MAG < 0.03 {
            BREAK.
        }
        WAIT MIN(0.2,MAX(0,deadline-TIME:SECONDS)).
    }
    IF ABORT { SET timeoutReason TO "operator-abort". }
    IF ABORT OR NOT (VANG(SHIP:FACING * aShip,SUN:POSITION) <= tolerance AND SHIP:ANGULARVEL:MAG < 0.03) {
        solarDiagnosticSample(label,timeoutReason,aShip,_solarAimDirection(aim)).
        mLogWarn("STATS solar aim label=" + label + " status=" + timeoutReason
            + " elapsed=" + ROUND(TIME:SECONDS-began,2)
            + " err=" + ROUND(VANG(SHIP:FACING * aShip,SUN:POSITION),2)
            + " tolerance=" + tolerance + " rate=" + ROUND(SHIP:ANGULARVEL:MAG,4)).
        IF NOT keepOnFailure { UNLOCK STEERING. }
        RETURN FALSE.
    }
    WAIT 1.5.   // let panel sun-tracking and the flow readout catch up
    LOCAL success IS NOT ABORT AND (deadlineUt <= 0 OR TIME:SECONDS <= deadlineUt)
        AND VANG(SHIP:FACING * aShip,SUN:POSITION) <= tolerance AND SHIP:ANGULARVEL:MAG < 0.03.
    LOCAL resultStatus IS "settled".
    IF NOT success { SET resultStatus TO "readout-drift-or-deadline". }
    IF ABORT { SET resultStatus TO "operator-abort". }
    solarDiagnosticSample(label,resultStatus,aShip,_solarAimDirection(aim)).
    mLog("STATS solar aim label=" + label + " status=" + resultStatus + " success=" + success
        + " elapsed=" + ROUND(TIME:SECONDS-began,2) + " startErr=" + ROUND(startError,2)
        + " err=" + ROUND(VANG(SHIP:FACING * aShip,SUN:POSITION),2)
        + " tolerance=" + tolerance + " rate=" + ROUND(SHIP:ANGULARVEL:MAG,4)).
    IF NOT success AND NOT keepOnFailure { UNLOCK STEERING. }
    RETURN success.
}

// Cache the winning axis, release/keep steering per the caller, and log.
LOCAL FUNCTION _solarFinish {
    PARAMETER aShip.
    PARAMETER lockSteering.
    PARAMETER note.
    PARAMETER referenceFlow IS -1.
    LOCAL flow IS shipSolarFlow().
    stateSet("solar_axis", LIST(
        ROUND(aShip:X, 4), ROUND(aShip:Y, 4), ROUND(aShip:Z, 4))).
    IF flow > 0 {
        LOCAL info IS _solarPanelInfo().
        stateSet("solar_axis_peak", MAX(flow, referenceFlow)).
        stateSet("solar_axis_distance", SUN:POSITION:MAG).
        stateSet("solar_axis_panels", info["COUNT"]).
        stateSet("solar_axis_scaled", info["SCALED"]).
    }
    IF NOT lockSteering { UNLOCK STEERING. }
    mLog("Solar attitude set (" + note + "): flow="
        + ROUND(shipSolarFlow(), 2) + ".").
    mLog("STATS solar orient flow=" + ROUND(shipSolarFlow(), 2)
        + " charge=" + ROUND(shipPowerFraction() * 100, 1) + "pct").
}

LOCAL FUNCTION _solarPanelInfo {
    LOCAL count_ IS 0.
    LOCAL scaled IS 1.
    FOR part IN SHIP:PARTS {
        IF part:HASMODULE("ModuleDeployableSolarPanel") {
            SET count_ TO count_ + 1.
            IF NOT part:GETMODULE("ModuleDeployableSolarPanel"):HASFIELD("energy flow") {
                SET scaled TO 0.
            }
        }
    }
    RETURN LEXICON("COUNT", count_, "SCALED", scaled).
}

// A measured peak belongs to a panel set and measurement type. Energy
// flow changes with Sun distance; exposure/mixed fallbacks cannot be scaled.
LOCAL FUNCTION _solarCacheReference {
    LOCAL info IS _solarPanelInfo().
    LOCAL peak IS stateGetNum("solar_axis_peak", -1).
    LOCAL distance_ IS stateGetNum("solar_axis_distance", 0).
    IF peak <= 0 OR distance_ <= 0 OR SUN:POSITION:MAG <= 0
            OR stateGetNum("solar_axis_panels", -1) <> info["COUNT"]
            OR stateGetNum("solar_axis_scaled", -1) <> info["SCALED"] { RETURN -1. }
    LOCAL distanceRatio IS distance_ / SUN:POSITION:MAG.
    IF info["SCALED"] > 0 { RETURN peak * distanceRatio ^ 2. }
    IF ABS(distanceRatio - 1) > 0.02 { RETURN -1. }
    RETURN peak.
}

LOCAL FUNCTION _solarSunOccluded {
    LOCAL toSun IS SUN:POSITION.
    IF toSun:MAG < 1 { RETURN TRUE. }
    LOCAL blocker IS SHIP:BODY.
    UNTIL blocker:NAME = SUN:NAME {
        LOCAL along_ IS VDOT(blocker:POSITION, toSun:NORMALIZED).
        IF along_ > 0 AND along_ < toSun:MAG {
            LOCAL miss IS (blocker:POSITION - along_ * toSun:NORMALIZED):MAG.
            IF miss <= blocker:RADIUS + SUN:RADIUS * along_ / toSun:MAG { RETURN TRUE. }
        }
        IF NOT blocker:HASBODY { BREAK. }
        SET blocker TO blocker:BODY.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _solarSearchGuardReason {
    PARAMETER overrideGuard IS FALSE.
    IF overrideGuard { RETURN "". }

    IF SOLAR_SEARCH_SKIP_FIRST_BOOT > 0
            AND stateGetNum("boot_count", 0) <= 1 {
        RETURN "first boot".
    }

    IF SHIP:BODY:NAME:TOUPPER <> "KERBIN" { RETURN "". }

    LOCAL launchTime IS stateGetNum("launch_time", 0).
    LOCAL launchAge IS TIME:SECONDS - launchTime.
    IF launchTime > 0 AND launchAge >= 0
            AND launchAge < SOLAR_SEARCH_LAUNCH_GUARD {
        RETURN "Kerbin launch T+"
            + ROUND(launchAge, 0) + "s".
    }

    IF SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED" {
        LOCAL ksc IS LATLNG(-0.0972, -74.5577).
        IF ksc:DISTANCE <= SOLAR_SEARCH_KSC_RADIUS {
            RETURN "near KSC pad".
        }
    }

    RETURN "".
}

LOCAL FUNCTION _logSolarSearchGuard {
    PARAMETER reason.
    LOCAL key IS "solar_search_guard_reason".
    IF stateGet(key, "") <> reason {
        stateSet(key, reason).
        mLog("Solar search skipped: " + reason + ".").
    }
}

// ============================================================
// orientForSolar — find and hold the attitude that maximizes
// MEASURED solar energy flow, then cache it (solar_axis) so later
// calls validate/reuse it before searching. Every decision is by measured
// flow, so no panel-layout assumption is needed:
//   1. Validate the saved axis against its measured peak, when available.
//   2. Otherwise measure the six panel-part axes and hold the best.
// ============================================================
GLOBAL FUNCTION orientForSolar {
    PARAMETER forceSearch IS FALSE.
    PARAMETER lockSteering IS FALSE.
    PARAMETER overrideLaunchGuard IS FALSE.
    PARAMETER deadlineUt IS 0.

    // Surface/pad states have no useful attitude search — bail here
    // so callers don't each repeat a status guard (this replaces the
    // status check the old trySolarOrient wrapper carried).
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED"
            OR SHIP:STATUS = "PRELAUNCH" {
        RETURN FALSE.
    }

    LOCAL guardReason IS _solarSearchGuardReason(overrideLaunchGuard).
    IF guardReason <> "" {
        _logSolarSearchGuard(guardReason).
        RETURN FALSE.
    }
    stateRemove("solar_search_guard_reason").

    LOCAL searchDeadline IS TIME:SECONDS + SOLAR_SEARCH_TIMEOUT.
    IF deadlineUt > 0 { SET searchDeadline TO MIN(searchDeadline,deadlineUt). }
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000,SOLAR_MIN_IPU) {
        stateSet("solar_prior_ipu",priorIpu).
        SET CONFIG:IPU TO MIN(2000,SOLAR_MIN_IPU).
    }
    // Avoid re-copying the entire boot log to the archive at every aim/sample.
    LOCAL priorLogDefer IS LOG_ARCHIVE_DEFERRED.
    SET LOG_ARCHIVE_DEFERRED TO 1.
    solarDiagnosticBegin(forceSearch,searchDeadline,priorIpu).
    LOCAL success IS _solarOrient(forceSearch,lockSteering,searchDeadline).
    solarDiagnosticFinish(success,deadlineUt).
    SET LOG_ARCHIVE_DEFERRED TO priorLogDefer.
    SET CONFIG:IPU TO priorIpu.
    stateRemove("solar_prior_ipu").
    RETURN success.
}

// Cache first; otherwise measure the six panel axes and hold the best.
// No tracking probe, inferred panel type, or mid-scan attitude-dependent axes.
LOCAL FUNCTION _solarOrient {
    PARAMETER forceSearch.
    PARAMETER lockSteering.
    PARAMETER deadlineUt.

    LOCAL panels IS LIST().
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") { panels:ADD(p). }
    }
    IF panels:LENGTH = 0 {
        mLogWarn("orientForSolar: no solar panels found — skipping.").
        RETURN FALSE.
    }
    SAS OFF.
    IF deadlineUt <= 0 { SET deadlineUt TO TIME:SECONDS + SOLAR_SEARCH_TIMEOUT. }
    ELSE { SET deadlineUt TO MIN(deadlineUt,TIME:SECONDS + SOLAR_SEARCH_TIMEOUT). }
    SET WARP TO 0.
    UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR TIME:SECONDS >= deadlineUt OR ABORT { WAIT 0.05. }
    IF ABORT OR NOT KUNIVERSE:TIMEWARP:ISSETTLED OR TIME:SECONDS >= deadlineUt { RETURN FALSE. }
    mLog("STATS solar search status=begin force=" + forceSearch
        + " budget=" + ROUND(deadlineUt-TIME:SECONDS,2) + " turnTimeout=" + SOLAR_AIM_TIMEOUT).
    LOCAL referenceFlow IS _solarCacheReference().

    LOCAL cached IS stateGet("solar_axis", LIST()).
    IF NOT forceSearch AND cached:ISTYPE("List") AND cached:LENGTH >= 3 {
        LOCAL aShip IS V(cached[0], cached[1], cached[2]).
        IF aShip:MAG > 0.5 {
            SET aShip TO aShip:NORMALIZED.
            IF NOT _solarAimSettle(aShip,deadlineUt,lockSteering,"cache",SOLAR_HOLD_TOLERANCE) { RETURN FALSE. }
            LOCAL cachedFlow IS shipSolarFlow().
            IF referenceFlow > 0 AND cachedFlow >= referenceFlow * SOLAR_REUSE_RATIO {
                _solarFinish(aShip, lockSteering, "cached axis validated", referenceFlow).
                RETURN TRUE.
            }
            IF cachedFlow < 0 OR _solarSunOccluded() {
                // Darkness/unreadable fields cannot invalidate a known axis
                // or replace its successful peak with a zero measurement.
                IF NOT lockSteering { UNLOCK STEERING. }
                mLog("Solar cached axis retained; flow cannot be validated in eclipse/unreadable telemetry.").
                RETURN TRUE.
            }
            mLog("STATS solar cache status=below-reference flow=" + ROUND(cachedFlow,2)
                + " reference=" + ROUND(referenceFlow,2) + " searching=true").
        }
    }

    // Snapshot the part's body-frame basis BEFORE moving the vessel.
    LOCAL pf IS panels[0]:FACING.
    LOCAL inv IS SHIP:FACING:INVERSE.
    LOCAL primary IS inv * pf:FOREVECTOR.
    LOCAL side IS inv * pf:TOPVECTOR.
    LOCAL other IS inv * pf:STARVECTOR.
    LOCAL cands IS LIST(primary,side,-1 * primary,other,-1 * side,-1 * other).
    mLog("Solar search: six fixed-panel axes for best energy flow.").
    LOCAL bestFlow IS -1.
    LOCAL bestAxis IS primary.
    LOCAL i IS 0.
    UNTIL i >= cands:LENGTH {
        IF NOT _solarAimSettle(cands[i],deadlineUt,lockSteering,"fixed-" + (i+1)) { RETURN FALSE. }
        LOCAL flow IS shipSolarFlow().
        IF flow < 0 {
            mLogWarn("Solar: no readable flow/exposure fields; search stopped.").
            UNLOCK STEERING.
            RETURN FALSE.
        }
        mLog("STATS solar sample axis=" + (i + 1) + "/6 flow=" + ROUND(flow, 2)).
        IF NOT forceSearch AND referenceFlow > 0 AND flow >= referenceFlow * SOLAR_REUSE_RATIO {
            _solarFinish(cands[i],lockSteering,"reference reached",referenceFlow).
            RETURN TRUE.
        }
        IF flow > bestFlow {
            SET bestFlow TO flow.
            SET bestAxis TO cands[i].
        }
        SET i TO i + 1.
    }

    IF bestFlow <= 0 {
        mLogWarn("Solar search: all axes zero flow — likely night.").
        mLog("STATS solar orient status=night charge="
            + ROUND(shipPowerFraction() * 100, 1) + "pct").
        UNLOCK STEERING.
        IF lockSteering { SET SAS TO FALSE. }
        RETURN FALSE.
    }

    IF NOT _solarAimSettle(bestAxis,deadlineUt,lockSteering,"best-hold") { RETURN FALSE. }
    _solarFinish(bestAxis, lockSteering, "best of 6", bestFlow).
    RETURN TRUE.
}

// ============================================================
// Warp-aware solar hold (for craft with no SAS source aboard).
//
// solarHoldTick: call every few seconds with the last reference
// flow. When the measured flow sags below SOLAR_HOLD_RATIO
// (0.92) of the reference, drop out of warp PROPERLY — wait for
// KUNIVERSE:TIMEWARP:ISSETTLED, the real release signal
// (flight-found at 125x: fixed waits returned while still on
// rails and the re-aim was a no-op) — re-aim the cached axis
// with the steering KEPT LOCKED, and restore the previous warp.
// Eclipse-aware: near-zero flow is shadow, not drift. Returns
// the updated reference flow.
// ============================================================
GLOBAL FUNCTION solarHoldTick {
    PARAMETER refFlow.
    PARAMETER deadlineUt IS 0.
    solarDiagnosticExport(deadlineUt).
    IF NOT shipHasSolarPanels() { RETURN refFlow. }
    LOCAL ratio IS 0.92.
    SET ratio TO SOLAR_HOLD_RATIO.
    LOCAL flow IS shipSolarFlow().
    IF flow < 0 { RETURN refFlow. }
    IF refFlow <= 0 {
        IF flow > 0 { RETURN flow. }
        IF _solarSunOccluded() { RETURN flow. }
    } ELSE {
        IF flow < refFlow * 0.15 { RETURN refFlow. }   // eclipse: wait it out
        IF flow > refFlow { RETURN flow. }              // ratchet the reference
        IF flow >= refFlow * ratio { RETURN refFlow. }

        // Defer cosmetic sag while batteries are comfortable. This is a
        // maintenance decision, not initialization of a steering hold.
        LOCAL ecTrigger IS SOLAR_HOLD_EC.
        IF shipPowerFraction() >= ecTrigger AND flow > refFlow * 0.25 {
            RETURN refFlow.
        }
    }
    IF deadlineUt > 0 AND TIME:SECONDS >= deadlineUt-3 { RETURN refFlow. }

    LOCAL began IS TIME:SECONDS.
    LOCAL savedWarp IS WARP.
    mLog("STATS solar hold status=reaim beforeFlow=" + flow + " reference=" + refFlow
        + " charge=" + ROUND(shipPowerFraction()*100,1) + "pct savedWarp=" + savedWarp).
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF deadlineUt > 0 AND TIME:SECONDS >= deadlineUt-2 { RETURN refFlow. }
    WAIT 1.
    UNLOCK STEERING.
    LOCAL aimed IS orientForSolar(FALSE, TRUE, FALSE,deadlineUt).
    IF deadlineUt <= 0 OR TIME:SECONDS+1 <= deadlineUt { WAIT 1. }
    LOCAL newRef IS shipSolarFlow().
    mLog("STATS solar hold status=result aimed=" + aimed + " beforeFlow=" + flow
        + " reference=" + refFlow + " afterFlow=" + newRef + " savedWarp=" + savedWarp
        + " elapsed=" + ROUND(TIME:SECONDS-began,2)).
    IF NOT aimed { RETURN refFlow. }
    IF savedWarp > 0 AND (deadlineUt <= 0 OR TIME:SECONDS < deadlineUt-2) {
        setWarpWithKac(savedWarp, "Solar hold restore").
    }
    RETURN MAX(newRef, 0).
}

// Blocking hold: maintain the solar attitude until endUt. If endUt
// is 0, hold indefinitely. The steering lock lives as long as this runs —
// on SAS-less craft that IS the hold.
GLOBAL FUNCTION solarMaintainHold {
    PARAMETER endUt IS 0.
    LOCAL refFlow IS shipSolarFlow().
    mLog("Solar hold engaged"
        + (CHOOSE " for " + ROUND(endUt - TIME:SECONDS, 0) + "s"
           IF endUt > 0 ELSE " indefinitely")
        + ". Warp at will.").
    UNTIL ABORT OR (endUt > 0 AND TIME:SECONDS >= endUt) {
        SET refFlow TO solarHoldTick(refFlow,endUt).
        IF ABORT OR (endUt > 0 AND TIME:SECONDS >= endUt) { BREAK. }
        IF endUt > 0 { WAIT MIN(5,MAX(0,endUt-TIME:SECONDS)). }
        ELSE { WAIT 5. }
    }
    UNLOCK STEERING.
    mLog("Solar hold ended.").
}
