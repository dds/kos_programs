// ============================================================
// utils.ks  —  General-purpose utilities  (0:/lib/utils.ks)
// ============================================================

GLOBAL FUNCTION fmtDuration {
    PARAMETER secs.
    LOCAL h IS FLOOR(secs / 3600).
    LOCAL m IS FLOOR(MOD(secs, 3600) / 60).
    LOCAL s IS ROUND(MOD(secs, 60), 0).
    RETURN h + "h " + m + "m " + s + "s".
}

GLOBAL FUNCTION printOrbitRef {
    PARAMETER revs.
    PARAMETER currentPeR.
    PARAMETER bodyMu.
    PARAMETER bR.
    LOCAL dayLen IS SHIP:ORBIT:BODY:ROTATIONPERIOD.
    LOCAL period IS dayLen / revs.
    LOCAL sma IS (bodyMu * (period / (2 * CONSTANT:PI))^2)^(1/3).
    LOCAL apR IS 2 * sma - currentPeR.
    LOCAL apAlt IS apR - bR.
    LOCAL ecc IS 1 - currentPeR / sma.
    IF apAlt > 0 AND ecc < 1 AND ecc > 0 {
        PRINT "  " + revs + " rev/day: T=" + ROUND(period,0) + "s  Ap=" + ROUND(apAlt/1000,0) + "km  ecc=" + ROUND(ecc,3).
    }
}

GLOBAL FUNCTION hasFixedPanels {
    PARAMETER dc.
    LOCAL bfsQ IS LIST().
    FOR ch IN dc:CHILDREN { bfsQ:ADD(ch). }
    UNTIL bfsQ:LENGTH = 0 {
        LOCAL p IS bfsQ[0].
        bfsQ:REMOVE(0).
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL m IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF NOT m:HASEVENT("Extend Solar Panel")
                AND NOT m:HASEVENT("Retract Solar Panel")
                AND NOT m:HASEVENT("Toggle Solar Panel") {
                RETURN TRUE.
            }
        }
        FOR ch IN p:CHILDREN { bfsQ:ADD(ch). }
    }
    RETURN FALSE.
}

// ============================================================
// Geo-distance (Haversine) — surface distance in meters between
// two lat/lng pairs on SHIP:BODY.
// ============================================================
GLOBAL FUNCTION geoDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL oRad IS SHIP:BODY:RADIUS.
    LOCAL dLat IS lat2 - lat1.
    LOCAL dLng IS lng2 - lng1.
    LOCAL a IS SIN(dLat/2)^2
        + COS(lat1) * COS(lat2) * SIN(dLng/2)^2.
    LOCAL c IS 2 * ARCSIN(MIN(1, SQRT(a))).
    RETURN oRad * c * CONSTANT:PI / 180.
}

// ============================================================
// Waypoint lookups — find a waypoint by name or selection state,
// filtered to the current body.
// ============================================================
GLOBAL FUNCTION waypointNamed {
    PARAMETER waypointName.
    LOCAL allWps IS ALLWAYPOINTS().
    FOR wp IN allWps {
        IF wp:BODY:NAME = SHIP:BODY:NAME {
            IF wp:NAME = waypointName { RETURN wp. }
        }
    }
    RETURN 0.
}

GLOBAL FUNCTION selectedWaypoint {
    LOCAL allWps IS ALLWAYPOINTS().
    FOR wp IN allWps {
        IF wp:ISSELECTED {
            IF wp:BODY:NAME = SHIP:BODY:NAME { RETURN wp. }
        }
    }
    RETURN 0.
}

GLOBAL FUNCTION printSequence {
    PARAMETER seq.
    LOCAL i IS 0.
    UNTIL i >= seq:LENGTH {
        LOCAL line IS "  ".
        LOCAL j IS i.
        UNTIL j >= seq:LENGTH OR line:LENGTH > 42 {
            IF j > i { SET line TO line + " > ". }
            SET line TO line + seq[j].
            SET j TO j + 1.
        }
        PRINT line.
        SET i TO j.
    }
}

// ============================================================
// Solar attitude + power helpers
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
