// ============================================================
// orbit_draw.ks  —  ASCII orbit diagram (ARCHIVE-ONLY)
// (0:/lib/orbit_draw.ks)
//
// *** This file is NEVER synced to a probe core. ***
// It has no row in dependencies.txt and costs zero local bytes.
// maneuver.ks runs it straight from the archive
// (RUNONCEPATH("0:/lib/orbit_draw.ks")) when a KSC link is up,
// then calls orbitDrawBurn(nd). No link, no art — the numeric
// burn brief still prints. A kOS GUI module may replace this
// terminal renderer some day; same archive-only rule will apply.
//
// orbitDrawBurn(nd) draws a top-down diagram of the current and
// post-burn orbits around the body:
//
//   .  current orbit        o  orbit after the burn
//   *  burn point           P / A  new periapsis / apoapsis
//   @  body (or # outline when it is big enough on screen)
//
// Frame: the current orbit's plane, current periapsis to the
// right; the new orbit is rotated by the change in (LAN + AoP) —
// exact for coplanar burns, an honest approximation for plane
// changes. Hyperbolic arcs clip naturally at the frame edge.
// Never clears the screen.
// ============================================================

@LAZYGLOBAL OFF.

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

// Character grid (kOS strings are immutable: keep rows as LISTs
// of single-char strings and JOIN at print time).
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

GLOBAL FUNCTION orbitDrawBurn {
    PARAMETER nd.

    LOCAL o1 IS SHIP:ORBIT.
    LOCAL o2 IS nd:ORBIT.
    LOCAL bodyR IS SHIP:BODY:RADIUS.

    LOCAL w IS _odInner().
    LOCAL h IS GRID_H.

    LOCAL rot2 IS (o2:LAN + o2:ARGUMENTOFPERIAPSIS)
        - (o1:LAN + o1:ARGUMENTOFPERIAPSIS).

    LOCAL rMax IS MAX(bodyR * 1.3, MAX(_odMaxR(o1), _odMaxR(o2))).
    SET rMax TO MIN(rMax, SHIP:BODY:SOIRADIUS).
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

    _odEdge("-").
    FROM { LOCAL t IS 0. } UNTIL t >= h STEP { SET t TO t + 1. } DO {
        _odText(grid[t]:JOIN("")).
    }
    _odText(". now   o after   * burn   P/A new Pe/Ap").
    _odEdge("-").
}
