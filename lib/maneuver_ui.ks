// ============================================================
// maneuver_ui.ks  -  Archive-only maneuver diagnostics
// (0:/lib/maneuver_ui.ks)
//
// This file is intentionally absent from dependencies.txt. It runs
// straight from 0:/ when a KSC link is available.
// ============================================================

@LAZYGLOBAL OFF.

PARAMETER nd IS 0.
PARAMETER label IS "".

LOCAL FUNCTION _orbitLine {
    PARAMETER o.
    IF o:ECCENTRICITY >= 1 {
        RETURN "ESCAPE (Pe " + ROUND(o:PERIAPSIS/1000,1)
            + "km, inc " + ROUND(o:INCLINATION,1) + ")".
    }
    RETURN ROUND(o:PERIAPSIS/1000,1) + " x " + ROUND(o:APOAPSIS/1000,1)
        + " km  inc " + ROUND(o:INCLINATION,1).
}

LOCAL FUNCTION _safeMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _burnTimeEstimate {
    PARAMETER nd_.
    IF ADDONS:KE:AVAILABLE {
        RETURN ADDONS:KE:NODEHALFBURNTIME * 2.
    }
    LOCAL acc IS _safeMaxAcc().
    IF acc <= 0 { RETURN 0. }
    RETURN nd_:DELTAV:MAG / acc.
}

// Compact pre-burn brief: dV breakdown, timing, and the orbit this
// node turns into. Set CFG BURN_BRIEF=0 for quiet missions.
LOCAL FUNCTION _burnBrief {
    PARAMETER nd_.
    IF DEFINED CFG AND CFG:HASKEY("BURN_BRIEF") AND CFG["BURN_BRIEF"] = 0 {
        RETURN.
    }
    PRINT " ".
    PRINT "  -- " + stateGet("phase", "MANEUVER") + " BURN --".
    PRINT "  dV " + ROUND(nd_:DELTAV:MAG,1)
        + " m/s (p " + ROUND(nd_:PROGRADE,1)
        + " n " + ROUND(nd_:NORMAL,1)
        + " r " + ROUND(nd_:RADIALOUT,1)
        + ")  ETA " + ROUND(nd_:ETA,0)
        + "s  burn ~" + ROUND(_burnTimeEstimate(nd_),0) + "s".
    PRINT "  now    " + _orbitLine(SHIP:ORBIT).
    PRINT "  after  " + _orbitLine(nd_:ORBIT).
    mLog("Plan: " + _orbitLine(SHIP:ORBIT) + " -> " + _orbitLine(nd_:ORBIT)).

    // The now/after lines describe the orbit around the CURRENT
    // body. When the post-burn trajectory enters another SOI, show
    // what actually matters: the arrival patch elements there.
    LOCAL p IS nd_:ORBIT.
    LOCAL hops IS 0.
    UNTIL NOT p:HASNEXTPATCH OR hops >= 4 {
        SET p TO p:NEXTPATCH.
        SET hops TO hops + 1.
        IF p:BODY <> SHIP:BODY {
            LOCAL arr IS p:BODY:NAME + " arrival: Pe "
                + ROUND(p:PERIAPSIS/1000,1) + "km  inc "
                + ROUND(p:INCLINATION,1) + "  lan "
                + ROUND(p:LAN,1).
            PRINT "  " + arr.
            mLog(arr).
            BREAK.
        }
    }

    // Orbit diagram is ARCHIVE-ONLY display code. BURN_ART=0 disables.
    LOCAL wantArt IS TRUE.
    IF DEFINED CFG AND CFG:HASKEY("BURN_ART") AND CFG["BURN_ART"] = 0 {
        SET wantArt TO FALSE.
    }
    IF wantArt AND HOMECONNECTION:ISCONNECTED
            AND TERMINAL:HEIGHT >= 28
            AND EXISTS("0:/lib/orbit_draw.ks") {
        RUNONCEPATH("0:/lib/orbit_draw.ks").
        orbitDrawBurn(nd_).
    }
}

LOCAL FUNCTION archivePlannedManeuverLog {
    PARAMETER label_ IS "maneuver".
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Planned maneuver log archived: " + label_ + ".").
    } ELSE {
        mLog("Planned maneuver log archive skipped: no KSC link (" + label_ + ").").
    }
}

IF label <> "" {
    archivePlannedManeuverLog(label).
} ELSE {
    _burnBrief(nd).
}
