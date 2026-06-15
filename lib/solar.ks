// ============================================================
// solar.ks  —  Solar attitude + power readouts  (0:/lib/solar.ks)
//
// Small and standalone on purpose: anything that spends time in
// space can load it. orientForSolar finds the attitude that
// maximizes MEASURED panel energy flow (no assumption about the
// panel layout) and hands the hold to SAS. Power readers included
// for telemetry; electrical management itself belongs to AmpYear.
// ============================================================

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

GLOBAL FUNCTION shipPowerFraction {
    FOR res IN SHIP:RESOURCES {
        IF res:NAME = "ELECTRICCHARGE" AND res:CAPACITY > 0 {
            RETURN res:AMOUNT / res:CAPACITY.
        }
    }
    RETURN 1.
}

// AMP reserve power aboard (0 when the mod/resource is absent).
GLOBAL FUNCTION shipReservePower {
    FOR res IN SHIP:RESOURCES {
        IF res:NAME = "RESERVEPOWER" { RETURN res:AMOUNT. }
    }
    RETURN 0.
}

// Servo an arbitrary ship-frame axis onto the Sun. The LOCK is
// self-referential, so it converges like a pointing servo.
LOCAL FUNCTION _solarAim {
    PARAMETER aShip.
    LOCK STEERING TO
        ROTATEFROMTO(SHIP:FACING * aShip, SUN:POSITION) * SHIP:FACING.
}

LOCAL FUNCTION _solarAimSettle {
    PARAMETER aShip.
    _solarAim(aShip).
    LOCAL deadline IS TIME:SECONDS + 25.
    UNTIL VANG(SHIP:FACING * aShip, SUN:POSITION) < 3
            OR TIME:SECONDS > deadline {
        WAIT 0.2.
    }
    WAIT 2.   // let panel tracking and the flow readout update
}

// ============================================================
// orientForSolar — find and hold the attitude that maximizes
// MEASURED solar energy flow. Panel layouts differ (one panel
// on one side is common), so no geometric assumption survives:
// the six body axes of the first panel part are physically
// tried, total energy flow is read from the panel modules, and
// the winner is held — then cached in state (solar_axis) so
// later calls skip the search. The hold is plain SAS, so
// keeping the attitude costs (almost) no battery.
// ============================================================
GLOBAL FUNCTION orientForSolar {
    PARAMETER forceSearch IS FALSE.
    PARAMETER lockSteering IS FALSE.

    LOCAL panels IS LIST().
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableSolarPanel") { panels:ADD(p). }
    }
    IF panels:LENGTH = 0 {
        mLogWarn("orientForSolar: no solar panels found — skipping.").
        RETURN.
    }
    SAS OFF.

    LOCAL cached IS stateGet("solar_axis", "").
    LOCAL retryUt IS stateGetNum("solar_retry_ut", 0).
    IF retryUt > TIME:SECONDS AND (forceSearch OR cached = "") {
        mLog("Solar search deferred for "
            + ROUND(retryUt - TIME:SECONDS, 0) + "s.").
        RETURN.
    }
    IF NOT forceSearch AND cached <> "" {
        LOCAL parts IS cached:SPLIT(",").
        LOCAL aShip IS V(parts[0]:TONUMBER(0), parts[1]:TONUMBER(0),
            parts[2]:TONUMBER(0)).
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

    // Candidate sun-pointing axes: the panel part's six body
    // axes, expressed in the SHIP frame so they survive turns.
    LOCAL pf IS panels[0]:FACING.
    LOCAL inv IS SHIP:FACING:INVERSE.
    LOCAL cands IS LIST(
        inv * pf:FOREVECTOR, inv * (-1 * pf:FOREVECTOR),
        inv * pf:TOPVECTOR,  inv * (-1 * pf:TOPVECTOR),
        inv * pf:STARVECTOR, inv * (-1 * pf:STARVECTOR)).

    mLog("Solar search: trying 6 panel axes for best energy flow.").
    LOCAL bestFlow IS -2.
    LOCAL bestAxis IS cands[0].
    LOCAL i IS 0.
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

    IF bestFlow < 0 {
        mLogWarn("Solar search: panels found but no readable flow/exposure fields — skipping.").
        UNLOCK STEERING.
        IF lockSteering {
            SET SAS TO FALSE.
        }
        RETURN.
    }
    IF bestFlow <= 0 {
        LOCAL retryAt IS TIME:SECONDS + 300.
        stateSetNum("solar_retry_ut", retryAt).
        mLogWarn("Solar search: all axes have zero flow — likely night; retry later.").
        mLogWarn("STATS solar orient status=night retryIn=300"
            + " charge=" + ROUND(shipPowerFraction() * 100, 1) + "pct").
        UNLOCK STEERING.
        IF lockSteering {
            SET SAS TO FALSE.
        }
        RETURN.
    }

    // Refine around the winner: the panel normal need not lie on
    // a part axis (angled mounts, offset cells), so the coarse
    // best can sit on a cosine shoulder. Hill-climb the aim with
    // shrinking angular steps, keeping only candidates that
    // MEASURE better. (VCRS here only generates trial directions
    // — every decision is by measured flow, so the left-handed
    // frame can't bite.)
    LOCAL i2 IS 0.
    FOR step IN LIST(15, 5) {
        LOCAL refAxis IS V(1, 0, 0).
        IF ABS(bestAxis:X) > 0.9 { SET refAxis TO V(0, 1, 0). }
        LOCAL perpU IS VCRS(bestAxis, refAxis):NORMALIZED.
        LOCAL perpW IS VCRS(bestAxis, perpU):NORMALIZED.
        FOR rotAxis IN LIST(perpU, perpW) {
            FOR sgn IN LIST(1, -1) {
                LOCAL cand IS
                    (ANGLEAXIS(step * sgn, rotAxis) * bestAxis):NORMALIZED.
                _solarAimSettle(cand).
                LOCAL flow IS shipSolarFlow().
                SET i2 TO i2 + 1.
                IF flow > bestFlow + 0.005 {
                    mLog("  refine " + step + "deg: flow "
                        + ROUND(bestFlow, 3) + " -> " + ROUND(flow, 3) + ".").
                    SET bestFlow TO flow.
                    SET bestAxis TO cand.
                }
            }
        }
    }

    _solarAimSettle(bestAxis).
    stateSetNum("solar_retry_ut", 0).
    stateSet("solar_axis", ROUND(bestAxis:X, 4) + ","
        + ROUND(bestAxis:Y, 4) + "," + ROUND(bestAxis:Z, 4)).
    if lockSteering {
    } else {
        UNLOCK STEERING.
    }
    mLog("Solar attitude set: flow=" + ROUND(shipSolarFlow(), 2)
        + " (best of search " + ROUND(bestFlow, 2) + ").").
    mLogWarn("STATS solar orient flow=" + ROUND(shipSolarFlow(), 2)
        + " charge=" + ROUND(shipPowerFraction() * 100, 1) + "pct").
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
    IF DEFINED CFG { SET ratio TO cfgNum("SOLAR_HOLD_RATIO", 0.92). }
    LOCAL flow IS shipSolarFlow().
    IF flow < 0 { RETURN refFlow. }
    IF refFlow <= 0 {
        IF flow <= 0 {
            LOCAL retryUt IS stateGetNum("solar_retry_ut", 0).
            IF retryUt <= TIME:SECONDS {
                orientForSolar(TRUE, TRUE).
            }
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
    IF DEFINED CFG { SET ecTrigger TO cfgNum("SOLAR_HOLD_EC", 0.75). }
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
    IF savedWarp > 0 { SET WARP TO savedWarp. }
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
