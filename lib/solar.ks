// ============================================================
// solar.ks  —  Solar attitude + power readouts  (0:/lib/solar.ks)
//
// Small and standalone on purpose: anything that spends time in
// space can load it. orientForSolar finds the attitude that
// maximizes MEASURED panel energy flow (no assumption about the
// panel layout) and hands the hold to SAS. Power readers included
// for telemetry; electrical management itself belongs to AmpYear.
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL SOLAR_HOLD_RATIO IS 0.92.
GLOBAL SOLAR_HOLD_EC IS 0.75.
GLOBAL SOLAR_SEARCH_SKIP_FIRST_BOOT IS 1.
GLOBAL SOLAR_SEARCH_LAUNCH_GUARD IS 300.
GLOBAL SOLAR_SEARCH_KSC_RADIUS IS 10000.
GLOBAL SOLAR_CHARGE_CHECK_DT IS 5.
GLOBAL SOLAR_CHARGE_CHECK_MIN_DELTA IS 0.01.
GLOBAL SOLAR_CHARGE_FULL_EC IS 0.995.

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

// Servo an arbitrary ship-frame axis onto the Sun. The LOCK is
// self-referential, so it converges like a pointing servo.
LOCAL FUNCTION _solarAim {
    PARAMETER aShip.
    LOCK STEERING TO
        ROTATEFROMTO(SHIP:FACING * aShip, SUN:POSITION) * SHIP:FACING.
}

// Aim the axis at the Sun and wait until the ship is BOTH pointed and
// has stopped rotating before returning — measuring flow mid-slew is
// what made the coarse search bleed one axis's reading into the next.
LOCAL FUNCTION _solarAimSettle {
    PARAMETER aShip.
    _solarAim(aShip).
    LOCAL deadline IS TIME:SECONDS + 30.
    UNTIL TIME:SECONDS > deadline {
        IF VANG(SHIP:FACING * aShip, SUN:POSITION) < 2
                AND SHIP:ANGULARVEL:MAG < 0.03 {
            BREAK.
        }
        WAIT 0.2.
    }
    WAIT 1.5.   // let panel sun-tracking and the flow readout catch up
}

// Cache the winning axis, release/keep steering per the caller, and log.
LOCAL FUNCTION _solarFinish {
    PARAMETER aShip.
    PARAMETER lockSteering.
    PARAMETER note.
    stateSet("solar_axis", LIST(
        ROUND(aShip:X, 4), ROUND(aShip:Y, 4), ROUND(aShip:Z, 4))).
    IF NOT lockSteering { UNLOCK STEERING. }
    mLog("Solar attitude set (" + note + "): flow="
        + ROUND(shipSolarFlow(), 2) + ".").
    mLog("STATS solar orient flow=" + ROUND(shipSolarFlow(), 2)
        + " charge=" + ROUND(shipPowerFraction() * 100, 1) + "pct").
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
// calls skip the search. Every decision is by measured flow, so no
// panel-layout assumption is needed:
//   1. Aim the panel's own normal at the Sun and settle (the settle
//      waits for rotation to STOP before reading — otherwise the
//      coarse search bleeds one axis's flow into the next).
//   2. Tracking test: swing 45 deg off-Sun. If flow holds, the panels
//      self-track — keep this aim and let them work (a search would
//      just fight their motion).
//   3. Fixed panels only: try the part's six body axes, hold the best.
// ============================================================
GLOBAL FUNCTION orientForSolar {
    PARAMETER forceSearch IS FALSE.
    PARAMETER lockSteering IS FALSE.
    PARAMETER overrideLaunchGuard IS FALSE.

    // Surface/pad states have no useful attitude search — bail here
    // so callers don't each repeat a status guard (this replaces the
    // status check the old trySolarOrient wrapper carried).
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED"
            OR SHIP:STATUS = "PRELAUNCH" {
        RETURN.
    }

    LOCAL guardReason IS _solarSearchGuardReason(overrideLaunchGuard).
    IF guardReason <> "" {
        _logSolarSearchGuard(guardReason).
        RETURN.
    }
    stateRemove("solar_search_guard_reason").

    LOCAL panels IS LIST().
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") { panels:ADD(p). }
    }
    IF panels:LENGTH = 0 {
        mLogWarn("orientForSolar: no solar panels found — skipping.").
        RETURN.
    }
    SAS OFF.

    LOCAL cached IS stateGet("solar_axis", LIST()).
    IF NOT forceSearch AND cached:ISTYPE("List") AND cached:LENGTH >= 3 {
        LOCAL aShip IS V(cached[0], cached[1], cached[2]).
        IF aShip:MAG > 0.5 {
            _solarAimSettle(aShip).
            IF NOT lockSteering {
                UNLOCK STEERING.
            }
            mLog("Solar attitude restored (flow="
                + ROUND(shipSolarFlow(), 2) + ").").
            RETURN.
        }
    }

    // Point the panel part's own normal (its forward) at the Sun and
    // measure once. This is candidate zero for fixed panels and the
    // hold for self-tracking panels.
    LOCAL pf IS panels[0]:FACING.
    LOCAL inv IS SHIP:FACING:INVERSE.
    LOCAL primary IS inv * pf:FOREVECTOR.
    _solarAimSettle(primary).
    LOCAL f1 IS shipSolarFlow().
    IF f1 < 0 {
        mLogWarn("Solar: panels found but no readable flow/exposure fields — skipping.").
        UNLOCK STEERING.
        IF lockSteering { SET SAS TO FALSE. }
        RETURN.
    }

    // Tracking test: swing ~45 deg off the Sun. Sun-tracking panels
    // re-aim themselves, so flow barely drops; fixed panels fall off
    // like a cosine (cos 45 ~ 0.71). If they track, any sun-ish hold
    // works — keep this aim and let the panel do the rest, instead of
    // a six-axis search that would only fight its motion.
    IF f1 > 0 {
        LOCAL refV IS V(1, 0, 0).
        IF ABS(primary:X) > 0.9 { SET refV TO V(0, 1, 0). }
        LOCAL perp IS VCRS(primary, refV):NORMALIZED.
        LOCAL offAxis IS (ANGLEAXIS(45, perp) * primary):NORMALIZED.
        _solarAimSettle(offAxis).
        LOCAL f2 IS shipSolarFlow().
        IF f2 >= f1 * 0.8 {
            _solarAimSettle(primary).
            _solarFinish(primary, lockSteering, "tracking panels").
            RETURN.
        }
    }

    // Fixed panels: hold the best-measured of the part's six body axes.
    LOCAL cands IS LIST(
        primary, inv * (-1 * pf:FOREVECTOR),
        inv * pf:TOPVECTOR,  inv * (-1 * pf:TOPVECTOR),
        inv * pf:STARVECTOR, inv * (-1 * pf:STARVECTOR)).
    mLog("Solar search: six fixed-panel axes for best energy flow.").
    LOCAL bestFlow IS f1.
    LOCAL bestAxis IS primary.
    LOCAL i IS 1.   // primary already measured as cands[0]
    UNTIL i >= cands:LENGTH {
        _solarAimSettle(cands[i]).
        LOCAL flow IS shipSolarFlow().
        mLog("  axis " + (i + 1) + "/6: flow=" + ROUND(flow, 2) + ".").
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
        RETURN.
    }

    _solarAimSettle(bestAxis).
    _solarFinish(bestAxis, lockSteering, "best of 6").
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
    IF NOT shipHasSolarPanels() { RETURN refFlow. }
    LOCAL ratio IS 0.92.
    SET ratio TO SOLAR_HOLD_RATIO.
    LOCAL flow IS shipSolarFlow().
    IF flow < 0 { RETURN refFlow. }
    IF refFlow <= 0 {
        IF flow <= 0 {
            orientForSolar(TRUE, TRUE).
            RETURN flow.
        }
        RETURN flow.
    }
    IF flow < refFlow * 0.15 { RETURN refFlow. }   // eclipse: wait it out
    IF flow > refFlow { RETURN flow. }              // ratchet the reference
    IF flow >= refFlow * ratio { RETURN refFlow. }

    // EC-aware deferral: while the battery is comfortable (above
    // SOLAR_HOLD_EC, default 75%) and the panels still make SOME
    // power, let the sag ride — interplanetary legs at 100000x
    // should not drop warp to fix a cosmetic 10% loss. The re-aim
    // happens when charge actually needs it; the flow ratio is
    // the quality floor once it does.
    LOCAL ecTrigger IS 0.75.
    SET ecTrigger TO SOLAR_HOLD_EC.
    IF shipPowerFraction() >= ecTrigger AND flow > refFlow * 0.25 {
        RETURN refFlow.
    }

    LOCAL savedWarp IS WARP.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    WAIT 1.
    UNLOCK STEERING.
    orientForSolar(FALSE, TRUE).
    WAIT 1.
    LOCAL newRef IS shipSolarFlow().
    mLog("Solar hold: re-aimed at "
        + ROUND(100 * flow / refFlow, 0) + "% — flow "
        + ROUND(newRef, 2) + ". Restoring warp " + savedWarp + ".").
    IF savedWarp > 0 { setWarpWithKac(savedWarp, "Solar hold restore"). }
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
    UNTIL (endUt > 0 AND TIME:SECONDS >= endUt) {
        SET refFlow TO solarHoldTick(refFlow).
        WAIT 5.
    }
    UNLOCK STEERING.
    mLog("Solar hold ended.").
}
