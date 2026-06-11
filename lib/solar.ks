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
    IF NOT forceSearch AND cached <> "" {
        LOCAL parts IS cached:SPLIT(",").
        LOCAL aShip IS V(parts[0]:TONUMBER(0), parts[1]:TONUMBER(0),
            parts[2]:TONUMBER(0)).
        IF aShip:MAG > 0.5 {
            _solarAimSettle(aShip).
            UNLOCK STEERING.
            SET SAS TO TRUE.
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

    _solarAimSettle(bestAxis).
    stateSet("solar_axis", ROUND(bestAxis:X, 4) + ","
        + ROUND(bestAxis:Y, 4) + "," + ROUND(bestAxis:Z, 4)).
    UNLOCK STEERING.
    SET SAS TO TRUE.
    mLog("Solar attitude set: flow=" + ROUND(shipSolarFlow(), 2)
        + " (best of search " + ROUND(bestFlow, 2) + ").").
    mLogWarn("STATS solar orient flow=" + ROUND(shipSolarFlow(), 2)
        + " charge=" + ROUND(shipPowerFraction() * 100, 1) + "pct").
}
