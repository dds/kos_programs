// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL BURN_BRIEF IS 1.


LOCAL CF        IS 0.001.
LOCAL AC           IS 0.0001.
LOCAL ATOL      IS 2.0.
LOCAL CRT IS 300.
LOCAL CRL  IS 180.

GLOBAL FUNCTION executeManeuver {
    WAIT 0.1.
    IF NOT HASNODE {
        mLogError("executeManeuver: no node on flight plan.").
        HUDTEXT("ERROR: No maneuver node!", 5, 2, 18, RED, FALSE).
        RETURN FALSE.
    }

    LOCAL nd    IS NEXTNODE.
    LOCAL ntm IS nd:TIME.
    LOCAL bdv  IS nd:DELTAV:MAG.
    LOCAL st IS _cst(nd).
    _mpb(nd, bdv, st).

    IF bdv < 10 { _stl(0.25). }
    IF bdv < 2  { _stl(0.10). }
    IF bdv < 0.5 { _stl(0.05). }

    IF st < TIME:SECONDS {
        mLogWarn("Burn window already passed by " + ROUND(TIME:SECONDS - st, 0) + "s — removing node.").
        HUDTEXT("Burn window missed — replanning", 5, 2, 15, YELLOW, FALSE).
        REMOVE nd.
        _cpb("missed-window").
        RETURN FALSE.
    }

    _rmb(nd).

    mLog("Maneuver: dV=" + ROUND(bdv,1) + " m/s  ETA=" + ROUND(st - TIME:SECONDS,1) + "s").
    mLogWarn("STATS burn setup dv=" + ROUND(bdv,1)
        + " eta=" + ROUND(st - TIME:SECONDS,1)
        + " nodeEta=" + ROUND(nd:ETA,1)
        + " body=" + SHIP:BODY:NAME
        + " maxAcc=" + ROUND(_sma(),2)).
    IF _sma() <= 0 {
        mLogWarn("STATS burn thrust status=no-thrust maxThrust="
            + ROUND(SHIP:MAXTHRUST,1)
            + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).
    }

    LOCAL aid IS maneuverEnsureBurnAlarm(st, bdv, "Burn").

    // Imminent burn: clear any player warp first. If the burn is
    // still far enough from the T-60 KAC alarm, the guarded approach
    // auto-warp below can restart at an appropriate low rate.
    IF st - TIME:SECONDS < CRT {
        SET WARP TO 0.
    }

    SET SAS TO FALSE.
    WAIT 0.1.
    LOCK STEERING TO nd:BURNVECTOR.
    mLog("Aligning to burn vector...").

    LOCAL rt IS st - CRL.
    IF TIME:SECONDS < rt - CRT {
        // Spend the long coast sun-pointed for power; the checkpoint
        // re-locks below reacquire the burn vector before ignition.
        orientForSolar(FALSE, TRUE).
        mLog("Long coast wait (" + ROUND(rt - TIME:SECONDS, 0) + "s).").
        HUDTEXT("Coasting. Burn in " + ROUND(st - TIME:SECONDS, 0) + "s", 5, 2, 13, CYAN, FALSE).
        IF COAST_HIBERNATE > 0
                AND rt - TIME:SECONDS >= COAST_HIBERNATE_MIN {
            _hc().
        }
        coastAutoWarp(rt, "Burn coast", aid).
        LOCAL sr IS -1.
        UNTIL TIME:SECONDS >= rt {
            SET sr TO trySolarHoldTick(sr).
            WAIT MIN(10, MAX(0.5, rt - TIME:SECONDS)).
        }
        SET WARP TO 0.
        SET SAS TO FALSE.
        WAIT 0.1.
        LOCK STEERING TO nd:BURNVECTOR.
        mLog("Re-aligning — " + ROUND(st - TIME:SECONDS, 0) + "s to burn.").
        HUDTEXT("Re-aligning. Burn in " + ROUND(st - TIME:SECONDS, 0) + "s", 5, 2, 13, GREEN, FALSE).
    }

    LOCAL apt IS st - 60.
    IF TIME:SECONDS < apt {
        coastAutoWarp(apt, "Burn approach", aid).
    }
    WAIT UNTIL TIME:SECONDS >= apt.
    mLog("Burn in T-60").
    LOCK STEERING TO nd:BURNVECTOR.
    mLogWarn("STATS burn relock checkpoint=T-60 angle="
        + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR), 1)
        + " timeToBurn=" + ROUND(st - TIME:SECONDS, 1)).

    LOCAL adl IS st - 5.
    LOCAL t10 IS st - 10.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ATOL
            OR TIME:SECONDS >= t10 {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }
    IF TIME:SECONDS < t10 { WAIT UNTIL TIME:SECONDS >= t10. }
    LOCK STEERING TO nd:BURNVECTOR.
    mLogWarn("STATS burn relock checkpoint=T-10 angle="
        + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR), 1)
        + " timeToBurn=" + ROUND(st - TIME:SECONDS, 1)).

    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ATOL
            OR TIME:SECONDS >= adl {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }

    LOCAL ae IS VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR).
    mLogWarn("STATS burn align angle=" + ROUND(ae,1)
        + " tol=" + ATOL
        + " timeToBurn=" + ROUND(st - TIME:SECONDS,1)).
    IF ae >= ATOL {
        mLogWarn("Burn starting with " + ROUND(ae,1) + "° misalignment.").
    } ELSE {
        mLog("Aligned. Waiting for burn window...").
    }

    WAIT UNTIL TIME:SECONDS >= adl.
    HUDTEXT("Burn in T-4", 3, 2, 15, WHITE, FALSE).
    countdown(4).

    WAIT UNTIL TIME:SECONDS >= st.
    LOCK STEERING TO nd:BURNVECTOR.
    mLogWarn("STATS burn relock checkpoint=T-0 angle="
        + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR), 1)
        + " timeToBurn=" + ROUND(st - TIME:SECONDS, 1)).
    LOCAL ie IS VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR).
    IF ie > 15 {
        mLogError("Refusing burn: " + ROUND(ie, 1)
            + " deg off the burn vector at ignition.").
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        SET SAS TO FALSE.
        RETURN FALSE.
    }
    mLog("Burn start. dV=" + ROUND(bdv,1) + " m/s").
    LOCAL bsc IS TIME:SECONDS.

    LOCAL obv IS nd:BURNVECTOR.
    LOCAL db2 IS FALSE.
    LOCAL dra IS FALSE.
    LOCAL rdv IS 0.

    UNTIL _ic(nd, bdv) {
        LOCK STEERING TO nd:BURNVECTOR.

        IF _ns() {
            HUDTEXT("Staging!", 2, 2, 15, YELLOW, FALSE).
            mLog("Auto-stage triggered.").
            LOCK THROTTLE TO 0.
            WAIT 0.3.
            STAGE.
            WAIT 0.7.
        }

        LOCAL rem IS nd:DELTAV:MAG.
        LOCAL ma    IS _sma().
        LOCAL dc IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).
        IF rem < 2 {
            SET db2 TO TRUE.
        } ELSE IF db2 AND rem > 2 {
            SET dra TO TRUE.
            SET rdv TO rem.
            mLogError("Burn dV rebounded after trim phase: remaining="
                + ROUND(rem, 2) + " m/s — stopping maneuver.").
            LOCK THROTTLE TO 0.
            BREAK.
        }

        IF dc < 0 { LOCK THROTTLE TO 0. BREAK. }

        IF rem > 5.0 {
            LOCK THROTTLE TO 1.0.
        } ELSE IF rem > 0.5 {
            LOCAL tts IS rem / ma.
            LOCK THROTTLE TO MAX(0.02, MIN(0.5, tts)).
        } ELSE IF rem >= 0.04 {
            LOCK THROTTLE TO 0.01.
        } ELSE {
            LOCK THROTTLE TO 0.
            BREAK.
        }
        WAIT 0.01.
    }

    LOCAL res IS nd:DELTAV:MAG.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    _ren(ntm).
    _stl(1.0).
    IF dra {
        _cpb("dv-rebound").
    } ELSE {
        _cpb("complete").
    }

    // Clean up the KAC alarm now that the burn is done.
    IF aid <> "" {
        DELETEALARM(aid).
    }

    IF dra {
        mLogWarn("STATS burn abort reason=dv-rebound"
            + " dv=" + ROUND(bdv,1)
            + " reboundDv=" + ROUND(rdv,2)
            + " duration=" + ROUND(TIME:SECONDS - bsc,1)
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
            + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
        RETURN FALSE.
    }

    mLog("Burn complete. Residual dV ~" + ROUND(res, 2) + " m/s.").
    mLogWarn("STATS burn result dv=" + ROUND(bdv,1)
        + " residual=" + ROUND(res,2)
        + " duration=" + ROUND(TIME:SECONDS - bsc,1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
    HUDTEXT("Burn complete", 3, 2, 15, GREEN, FALSE).
    RETURN TRUE.
}

LOCAL FUNCTION _rmb {
    PARAMETER nd.
    LOCAL wb IS TRUE.
    IF BURN_BRIEF = 0 {
        SET wb TO FALSE.
    }

    IF wb AND HOMECONNECTION:ISCONNECTED {
        IF EXISTS("0:/lib/maneuver_ui.ks") {
            RUNPATH("0:/lib/maneuver_ui.ks", nd).
        }
    }
}

GLOBAL FUNCTION maneuverUiArchiveLog {
    PARAMETER label IS "maneuver".
    IF HOMECONNECTION:ISCONNECTED {
        IF EXISTS("0:/lib/maneuver_ui.ks") {
            RUNPATH("0:/lib/maneuver_ui.ks", 0, label).
        }
    }
}

LOCAL FUNCTION _stl {
    PARAMETER pct.
    FOR eng IN SHIP:ENGINES {
        SET eng:THRUSTLIMIT TO pct * 100.
    }
}

// Speed at a given radius ON THE SHIP'S CURRENT ORBIT — pure
// vis-viva from the live elements, zero future-state prediction.
// Flight-found (twice): both VELOCITYAT and POSITIONAT-difference
// predictions are contaminated by the parent body's own motion in
// this kOS build (~60-500 m/s at the Mun), which flipped planned
// burns retrograde. Orbit elements cannot lie.
LOCAL FUNCTION _sar {
    PARAMETER rBurn.
    RETURN SQRT(SHIP:BODY:MU
        * (2 / rBurn - 1 / SHIP:ORBIT:SEMIMAJORAXIS)).
}

GLOBAL FUNCTION planCircularize {
    LOCAL ea IS ETA:APOAPSIS.
    LOCAL mu  IS SHIP:ORBIT:BODY:MU.
    LOCAL vc IS SQRT(mu / (SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS)).
    LOCAL vn  IS _sar(SHIP:ORBIT:BODY:RADIUS + SHIP:APOAPSIS).
    LOCAL dv    IS vc - vn.

    LOCAL nd IS NODE(TIME:SECONDS + ea, 0, 0, dv).
    ADD nd.
    mLog("Circularize node: dV=" + ROUND(dv,1) + " m/s at Ap in " + ROUND(ea,0) + "s").
    mLogWarn("STATS circularize plan dv=" + ROUND(dv,1)
        + " eta=" + ROUND(ea,0)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    maneuverUiArchiveLog("circularize").
    RETURN nd.
}

GLOBAL FUNCTION planCapture {
    PARAMETER tb.
    PARAMETER ta.
    LOCAL mu    IS tb:MU.
    LOCAL rp   IS tb:RADIUS + SHIP:PERIAPSIS.
    LOCAL ra   IS tb:RADIUS + ta.
    LOCAL ts  IS (rp + ra) / 2.
    LOCAL vc IS SQRT(mu * (2/rp - 1/ts)).
    LOCAL vp    IS _sar(rp).
    LOCAL dv       IS vc - vp.
    LOCAL nd IS NODE(TIME:SECONDS + ETA:PERIAPSIS, 0, 0, dv).
    ADD nd.
    mLog("Capture node: dV=" + ROUND(dv,1)
        + " m/s at Pe in " + ROUND(ETA:PERIAPSIS,0)
        + "s  targetAp=" + ROUND(ta/1000,1) + "km").
    mLogWarn("STATS capture plan target=" + tb:NAME
        + " dv=" + ROUND(dv,1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " targetApKm=" + ROUND(ta/1000,1)
        + " etaPe=" + ROUND(ETA:PERIAPSIS,0)).
    maneuverUiArchiveLog("capture").
    RETURN nd.
}

GLOBAL FUNCTION planRaisePeNow {
    PARAMETER tp.
    LOCAL mu   IS SHIP:ORBIT:BODY:MU.
    LOCAL rn IS SHIP:ORBIT:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL rp  IS SHIP:ORBIT:BODY:RADIUS + tp.
    LOCAL vn IS SHIP:VELOCITY:ORBIT:MAG.
    LOCAL ts IS (rn + rp) / 2.
    LOCAL vv IS SQRT(mu * (2/rn - 1/ts)).
    LOCAL dv   IS vv - vn.
    LOCAL lead IS 60.
    IF ABS(dv) > 100 { SET lead TO 90. }
    IF ABS(dv) > 300 { SET lead TO 120. }
    LOCAL nd IS NODE(TIME:SECONDS + lead, 0, 0, dv).
    ADD nd.
    mLog("Raise Pe node: dV=" + ROUND(dv,1)
        + " m/s  targetPe=" + ROUND(tp/1000,1) + "km").
    mLogWarn("STATS raise-pe plan dv=" + ROUND(dv,1)
        + " targetPeKm=" + ROUND(tp/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).
    maneuverUiArchiveLog("raise-pe").
    RETURN nd.
}

GLOBAL FUNCTION planLowerPe {
    PARAMETER tp.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL br IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL bt IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL rb IS br + SHIP:APOAPSIS.
    LOCAL rt IS br + tp.
    LOCAL ts IS (rb + rt) / 2.
    LOCAL vn IS _sar(rb).
    LOCAL vv IS SQRT(mu * (2 / rb - 1 / ts)).
    LOCAL nd IS NODE(bt, 0, 0, vv - vn).
    ADD nd.
    mLog("Lower Pe node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPe=" + ROUND(tp/1000,1) + "km").
    mLogWarn("STATS lower-pe plan dv=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPeKm=" + ROUND(tp/1000,1)
        + " startPeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " startApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " etaAp=" + ROUND(ETA:APOAPSIS,0)).
    maneuverUiArchiveLog("lower-pe").
    RETURN nd.
}

GLOBAL FUNCTION planAoPChange {
    PARAMETER taop.
    LOCAL caop IS SHIP:ORBIT:ARGUMENTOFPERIAPSIS.
    LOCAL da IS taop - caop.
    IF da > 180  { SET da TO da - 360. }
    IF da < -180 { SET da TO da + 360. }
    IF ABS(da) < 2 { RETURN 0. }
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL a  IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL e  IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL h  IS SQRT(mu * a * (1 - e^2)).
    // Exact apsidal rotation: orbits with equal a,e rotated by
    // deltaAoP intersect at ta = deltaAoP/2 (+180). The required
    // radial-out impulse there is -2(mu/h) e sin(deltaAoP/2) —
    // SIGNED by deltaAoP (flight-found: the old hardcoded sign
    // was correct for positive rotations only; a -64 deg rotation
    // burned the wrong way and sent AoP to 17 instead of 269).
    LOCAL dv1 IS -2 * (mu / h) * e * SIN(da / 2).
    LOCAL t1 IS da / 2.
    LOCAL t2 IS t1 + 180.
    LOCAL e1 IS etaToTrueAnomaly(t1).
    LOCAL e2 IS etaToTrueAnomaly(t2).
    LOCAL be IS e1.
    LOCAL dr IS dv1.
    IF e2 < e1 {
        SET be TO e2.
        SET dr TO -dv1.
    }
    LOCAL bu IS TIME:SECONDS + be.
    LOCAL nd IS NODE(bu, dr, 0, 0).
    ADD nd.
    mLog("AoP node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s  targetAoP=" + ROUND(taop,1)
        + " ETA=" + ROUND(be,0) + "s").
    maneuverUiArchiveLog("aop").
    RETURN nd.
}

// Estimated total burn duration. NODE:BURNTIME does not exist in
// this kOS build (flight-found) — use KerbalEngineer when present,
// else constant-mass dv/acc.
LOCAL FUNCTION _bte {
    PARAMETER nd.
    IF ADDONS:KE:AVAILABLE {
        RETURN ADDONS:KE:NODEHALFBURNTIME * 2.
    }
    LOCAL acc IS _sma().
    IF acc <= 0 { RETURN 0. }
    RETURN nd:DELTAV:MAG / acc.
}

LOCAL FUNCTION _cst {
    PARAMETER nd.
    LOCAL hb IS _bte(nd) / 2.
    LOCAL lead IS MIN(2.0, hb * 0.02).
    RETURN nd:TIME - hb - lead.
}

LOCAL FUNCTION _sma {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _ic {
    PARAMETER nd, origDV.
    LOCAL rem IS nd:DELTAV:MAG.
    LOCAL th IS MAX(AC, origDV * CF).
    LOCAL dc IS VDOT(nd:BURNVECTOR:NORMALIZED, nd:DELTAV:NORMALIZED).
    IF rem < 1.0 {
        RETURN rem < th OR dc < COS(ATOL).
    }
    RETURN rem < th OR dc < 0.
}

LOCAL FUNCTION _ns {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

LOCAL FUNCTION _ren {
    PARAMETER ntm.
    IF NOT HASNODE { RETURN. }

    LOCAL nt IS NEXTNODE:TIME.
    IF ABS(nt - ntm) < 0.5 {
        REMOVE NEXTNODE.
        WAIT 0.1.
    } ELSE {
        mLog("Preserving remaining maneuver node at T+"
            + ROUND(nt - TIME:SECONDS, 1) + "s.").
    }
}

LOCAL FUNCTION _mpb {
    PARAMETER nd.
    PARAMETER bdv.
    PARAMETER st.
    stateSet("burn_pending", "true").
    stateSet("burn_phase", stateGet("phase", "")).
    stateSet("burn_node_time", nd:TIME).
    stateSet("burn_start_time", st).
    stateSet("burn_dv", bdv).
}

LOCAL FUNCTION _cpb {
    PARAMETER reason.
    IF stateGet("burn_pending", "") = "true" {
        mLog("Clearing pending burn state: " + reason + ".").
    }
    FOR key IN LIST(
        "burn_pending", "burn_phase", "burn_node_time",
        "burn_start_time", "burn_dv"
    ) {
        stateRemove(key).
    }
}

LOCAL FUNCTION _hc {
    LOCAL found IS FALSE.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleCommand") {
            LOCAL cm IS p:GETMODULE("ModuleCommand").
            IF cm:HASFIELD("hibernation") {
                cm:SETFIELD("hibernation", TRUE).
                SET found TO TRUE.
            }
        }
    }
    IF found {
        mLog("Command module hibernating for long coast.").
    } ELSE {
        mLogWarn("Long coast hibernation requested but no toggle found.").
    }
}
