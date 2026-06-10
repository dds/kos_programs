// ============================================================
// orbit_draw.ks  —  Maneuver briefs and ASCII orbit diagrams
// (0:/lib/orbit_draw.ks)
//
// maneuverBrief(nd) renders a card before every burn (called
// from executeManeuver): dV magnitude and components, timing,
// the orbit BEFORE -> AFTER the node, and a top-down diagram of
// both orbits around the body:
//
//   .  current orbit        o  orbit after the burn
//   *  burn point           P / A  new periapsis / apoapsis
//   @  body (or # outline when it is big enough on screen)
//
// The diagram is drawn in the current orbit's plane with the
// current periapsis to the right; the new orbit is rotated by
// the change in (LAN + AoP) — exact for coplanar burns, an
// honest approximation for plane changes. Hyperbolic arcs are
// clipped naturally by the frame. Never clears the screen.
//
// Self-contained on purpose: loads with `maneuver` in every
// burn band, where flightplan.ks may not be present.
// ============================================================

@LAZYGLOBAL OFF.

GLOBAL ORBIT_DRAW_READY IS TRUE.

LOCAL GRID_H IS 17.

LOCAL FUNCTION _odInner {
    RETURN MAX(36, MIN(TERMINAL:WIDTH - 6, 56)).
}

LOCAL FUNCTION _odRun {
    PARAMETER ch, n.
    RETURN "":PADLEFT(MAX(0, n)):REPLACE(" ", ch).
}

LOCAL FUNCTION _odText {
    PARAMETER s.
    LOCAL w IS _odInner().
    IF s:LENGTH > w { SET s TO s:SUBSTRING(0, w - 1) + "~". }
    PRINT "  | " + s:PADRIGHT(w) + " |".
}

LOCAL FUNCTION _odEdge {
    PARAMETER ch.
    PRINT "  +" + _odRun(ch, _odInner() + 2) + "+".
}

LOCAL FUNCTION _odRow {
    PARAMETER label, value.
    _odText(label:PADRIGHT(13) + ": " + value).
}

LOCAL FUNCTION _odFmtT {
    PARAMETER s.
    SET s TO ROUND(s, 0).
    LOCAL h IS FLOOR(s / 3600).
    LOCAL m IS FLOOR(MOD(s, 3600) / 60).
    LOCAL sec IS MOD(s, 60).
    IF h > 0 { RETURN h + "h " + m + "m " + sec + "s". }
    IF m > 0 { RETURN m + "m " + sec + "s". }
    RETURN sec + "s".
}

LOCAL FUNCTION _odKm {
    PARAMETER meters.
    RETURN ROUND(meters / 1000, 1) + "km".
}

LOCAL FUNCTION _odOrbitLine {
    PARAMETER o.
    IF o:ECCENTRICITY >= 1 {
        RETURN "ESCAPE (Pe " + _odKm(o:PERIAPSIS)
            + ", inc " + ROUND(o:INCLINATION, 1) + ")".
    }
    RETURN _odKm(o:PERIAPSIS) + " x " + _odKm(o:APOAPSIS)
        + "  inc " + ROUND(o:INCLINATION, 1)
        + "  T " + _odFmtT(o:PERIOD).
}

// ------------------------------------------------------------
// Character grid (kOS strings are immutable: keep rows as LISTs
// of single-char strings and JOIN at print time).
// ------------------------------------------------------------

LOCAL FUNCTION _odGrid {
    PARAMETER w, h.
    LOCAL grid IS LIST().
    FROM { LOCAL t IS 0. } UNTIL t >= h STEP { SET t TO t + 1. } DO {
        LOCAL row IS LIST().
        FROM { LOCAL c IS 0. } UNTIL c >= w STEP { SET c TO c + 1. } DO {
            row:ADD(" ").
        }
        grid:ADD(row).
    }
    RETURN grid.
}

LOCAL FUNCTION _odPlot {
    PARAMETER grid, w, h, x, y, ch.
    // World -> grid: +x right, +y up; terminal rows count down and
    // characters are ~2x taller than wide, so y is halved.
    LOCAL col IS ROUND(w / 2 + x).
    LOCAL row IS ROUND(h / 2 - y * 0.5).
    IF col >= 0 AND col < w AND row >= 0 AND row < h {
        SET grid[row][col] TO ch.
    }
}

// Plot one conic: r(ta) = p / (1 + e cos ta), rotated by rotDeg.
LOCAL FUNCTION _odPlotOrbit {
    PARAMETER grid, w, h, scale, p, ecc, rotDeg, ch.
    FROM { LOCAL ta IS 0. } UNTIL ta >= 360 STEP { SET ta TO ta + 3. } DO {
        LOCAL denom IS 1 + ecc * COS(ta).
        IF denom > 0.05 {
            LOCAL t IS p / denom.
            _odPlot(grid, w, h,
                t * scale * COS(ta + rotDeg),
                t * scale * SIN(ta + rotDeg), ch).
        }
    }
}

// Largest radius an orbit reaches, capped at the SOI edge.
LOCAL FUNCTION _odMaxR {
    PARAMETER o.
    IF o:ECCENTRICITY < 1 {
        RETURN o:SEMIMAJORAXIS * (1 + o:ECCENTRICITY).
    }
    RETURN SHIP:BODY:SOIRADIUS.
}

// ------------------------------------------------------------
// orbitDrawBurn — diagram of SHIP:ORBIT vs nd:ORBIT.
// ------------------------------------------------------------
GLOBAL FUNCTION orbitDrawBurn {
    PARAMETER nd.

    LOCAL o1 IS SHIP:ORBIT.
    LOCAL o2 IS nd:ORBIT.
    LOCAL bodyR IS SHIP:BODY:RADIUS.

    LOCAL w IS _odInner().
    LOCAL h IS GRID_H.

    // Frame: current Pe to the right. The new orbit's apsis line
    // is rotated by the change in (LAN + AoP).
    LOCAL rot2 IS (o2:LAN + o2:ARGUMENTOFPERIAPSIS)
        - (o1:LAN + o1:ARGUMENTOFPERIAPSIS).

    LOCAL rMax IS MAX(bodyR * 1.3, MAX(_odMaxR(o1), _odMaxR(o2))).
    SET rMax TO MIN(rMax, SHIP:BODY:SOIRADIUS).
    // Vertical is the binding constraint (y plots at half scale).
    LOCAL scale IS MIN((w / 2 - 1) / rMax, (h - 2) / rMax).

    LOCAL grid IS _odGrid(w, h).

    LOCAL p1 IS o1:SEMIMAJORAXIS * (1 - o1:ECCENTRICITY ^ 2).
    LOCAL p2 IS o2:SEMIMAJORAXIS * (1 - o2:ECCENTRICITY ^ 2).
    _odPlotOrbit(grid, w, h, scale, p1, o1:ECCENTRICITY, 0, ".").
    _odPlotOrbit(grid, w, h, scale, p2, o2:ECCENTRICITY, rot2, "o").

    // New orbit's Pe / Ap markers.
    LOCAL rPe2 IS p2 / (1 + o2:ECCENTRICITY).
    _odPlot(grid, w, h, rPe2 * scale * COS(rot2), rPe2 * scale * SIN(rot2), "P").
    IF o2:ECCENTRICITY < 1 {
        LOCAL rAp2 IS p2 / (1 - o2:ECCENTRICITY).
        _odPlot(grid, w, h,
            rAp2 * scale * COS(rot2 + 180),
            rAp2 * scale * SIN(rot2 + 180), "A").
    }

    // Burn point: true anomaly on the current orbit at node time.
    IF o1:ECCENTRICITY > 0.005 {
        LOCAL rv IS POSITIONAT(SHIP, nd:TIME) - POSITIONAT(SHIP:BODY, nd:TIME).
        LOCAL cosTa IS MAX(-1, MIN(1,
            (p1 / rv:MAG - 1) / o1:ECCENTRICITY)).
        LOCAL ta IS ARCCOS(cosTa).
        IF VDOT(rv, VELOCITYAT(SHIP, nd:TIME):ORBIT) < 0 { SET ta TO -ta. }
        _odPlot(grid, w, h, rv:MAG * scale * COS(ta), rv:MAG * scale * SIN(ta), "*").
    }

    // Body last so nothing overwrites it.
    IF bodyR * scale >= 2 {
        _odPlotOrbit(grid, w, h, scale, bodyR, 0, 0, "#").
    }
    _odPlot(grid, w, h, 0, 0, "@").

    FROM { LOCAL t IS 0. } UNTIL t >= h STEP { SET t TO t + 1. } DO {
        _odText(grid[t]:JOIN("")).
    }
    _odText(". now   o after   * burn   P/A new Pe/Ap").
}

// ------------------------------------------------------------
// maneuverBrief — full pre-burn card. Gate with CFG BURN_BRIEF=0
// (numbers) / BURN_ART=0 (diagram) if a mission wants quiet.
// ------------------------------------------------------------
GLOBAL FUNCTION maneuverBrief {
    PARAMETER nd.
    PARAMETER label IS "MANEUVER".

    IF DEFINED CFG AND CFG:HASKEY("BURN_BRIEF") AND CFG["BURN_BRIEF"] = 0 {
        RETURN.
    }

    _odEdge("=").
    _odText(label + " BRIEF").
    _odEdge("-").
    _odRow("DELTA-V", ROUND(nd:DELTAV:MAG, 1) + " m/s"
        + "  (p " + ROUND(nd:PROGRADE, 1)
        + " n " + ROUND(nd:NORMAL, 1)
        + " r " + ROUND(nd:RADIALOUT, 1) + ")").
    _odRow("NODE ETA", _odFmtT(nd:ETA)).
    _odRow("BURN TIME", "~" + _odFmtT(nd:BURNTIME)).
    _odRow("BEFORE", _odOrbitLine(SHIP:ORBIT)).
    _odRow("AFTER", _odOrbitLine(nd:ORBIT)).

    LOCAL wantArt IS TRUE.
    IF DEFINED CFG AND CFG:HASKEY("BURN_ART") AND CFG["BURN_ART"] = 0 {
        SET wantArt TO FALSE.
    }
    IF TERMINAL:HEIGHT < GRID_H + 12 { SET wantArt TO FALSE. }
    IF wantArt {
        _odEdge("-").
        orbitDrawBurn(nd).
    }
    _odEdge("=").
}
