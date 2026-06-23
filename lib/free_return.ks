// ============================================================
// free_return.ks — free-return trajectory targeting (0:/lib/free_return.ks)
//
// A Mun (or any moon) flyby is a "free return" when the encounter is
// shaped so the craft leaves the moon's SOI already on a Kerbin
// RE-ENTRY trajectory — no return burn needed. That's the crewed-safety
// property: a failure after trans-Munar injection still brings the crew
// home (passive abort).
//
// This lib is deliberately ISOLATED from arrival_bplane (the
// flight-proven capture path): its objective is different — drive the
// POST-FLYBY home-body periapsis to the reentry corridor, not the moon
// encounter periapsis. A free-return mission uses the FREE_RT_BPLANE
// phase instead of BPLANE/REFINE_BPLANE.
//
// Config:
//   FREE_RETURN              — flag: this mission wants a free return
//   FREE_RETURN_PE           — target post-flyby home periapsis (m);
//                              -1 => use REENTRY_PE
//   FREE_RETURN_PE_TOL       — acceptable post-flyby Pe error (m)
//   FREE_RETURN_MUN_PE_FLOOR — minimum moon flyby periapsis (m); the
//                              solver never trades safety at the moon
//                              for the return
// ============================================================

GLOBAL FREE_RETURN IS FALSE.
GLOBAL FREE_RETURN_PE IS -1.
GLOBAL FREE_RETURN_PE_TOL IS 5000.
GLOBAL FREE_RETURN_MUN_PE_FLOOR IS 10000.

// Target post-flyby home periapsis: explicit FREE_RETURN_PE, else the
// shared reentry corridor (REENTRY_PE, owned by the return libs).
GLOBAL FUNCTION freeReturnTargetPe {
    IF FREE_RETURN_PE >= 0 { RETURN FREE_RETURN_PE. }
    RETURN REENTRY_PE.
}

// freeReturnPostFlybyPe — the quantity that read ~4000 km on the broken
// plan: the periapsis of the patch the craft is on AFTER it exits the
// moon's SOI, back in the home body's SOI. This is the number the
// free-return solver drives to freeReturnTargetPe().
//
// Returns the post-flyby home periapsis (m, altitude over the home
// body), or -1 when the patch chain shows no return to the home SOI
// (no encounter, the flyby doesn't exit in view, or KSP's conic patch
// limit is too low to show the return — raise it if so).
GLOBAL FUNCTION freeReturnPostFlybyPe {
    PARAMETER fromNode.      // a node to measure with, or 0 for live orbit
    PARAMETER targetBody.    // the moon being flown by (e.g. Mun)

    LOCAL home IS targetBody:BODY.            // body the moon orbits (Kerbin)
    LOCAL hit IS findArrivalPatch(fromNode, targetBody).
    IF hit = 0 { RETURN -1. }                 // no moon encounter
    LOCAL p IS hit["patch"].                  // the flyby patch (moon SOI)
    IF NOT p:HASNEXTPATCH { RETURN -1. }      // flyby doesn't exit in view
    SET p TO p:NEXTPATCH.                      // back out into home SOI
    IF p:BODY <> home { RETURN -1. }          // didn't return home
    RETURN p:PERIAPSIS.
}

// Convenience: log the current free-return geometry (encounter Pe at the
// moon + post-flyby home Pe vs target). Safe to call any time a patch
// chain exists — a diagnostic for tuning and for confirming the solver.
GLOBAL FUNCTION freeReturnReport {
    PARAMETER targetBody.
    LOCAL homePe IS freeReturnPostFlybyPe(0, targetBody).
    LOCAL want IS freeReturnTargetPe().
    LOCAL meas IS measureArrival(0, targetBody).
    LOCAL munPe IS -1.
    IF meas <> 0 { SET munPe TO meas["pe"]. }
    mLogWarn("STATS free-return body=" + targetBody:NAME
        + " munPeKm=" + ROUND(munPe / 1000, 1)
        + " postFlybyPeKm=" + ROUND(homePe / 1000, 1)
        + " wantPeKm=" + ROUND(want / 1000, 1)
        + " returns=" + (homePe >= 0)).
    RETURN homePe.
}

// ============================================================
// Solver — FREE_RT_BPLANE phase
//
// From the XING encounter, numerically nudge a small correction node
// so the post-flyby home periapsis lands in the reentry corridor, with
// the moon flyby periapsis kept above FREE_RETURN_MUN_PE_FLOOR. Pure
// hill-climb on the game's own patch propagation (trustworthy) — no
// analytic B-plane signs, so left-handed-frame traps can't bite. A hard
// safety gate refuses to fly anything that doesn't return home or that
// grazes the moon: it holds for the operator instead.
// ============================================================
GLOBAL FREE_RT_TARGET IS "".
GLOBAL FREE_RT_LEAD IS 120.
GLOBAL FREE_RT_DV_CAP IS 100.
GLOBAL FREE_RT_ACCEPT_TOL IS 10000.
GLOBAL FREE_RT_MAX_RETRIES IS 5.

LOCAL FUNCTION _frTargetBody {
    LOCAL nm IS FREE_RT_TARGET.
    IF nm = "" { SET nm TO getTarget(""). }
    IF nm = "" OR NOT BODYEXISTS(nm) { RETURN 0. }
    RETURN BODY(nm).
}

LOCAL FUNCTION _frNodeGet {
    PARAMETER nd. PARAMETER axis.
    IF axis = "PROGRADE" { RETURN nd:PROGRADE. }
    IF axis = "RADIALOUT" { RETURN nd:RADIALOUT. }
    RETURN nd:NORMAL.
}

LOCAL FUNCTION _frNodeSet {
    PARAMETER nd. PARAMETER axis. PARAMETER val.
    IF axis = "PROGRADE" { SET nd:PROGRADE TO val. }
    ELSE IF axis = "RADIALOUT" { SET nd:RADIALOUT TO val. }
    ELSE { SET nd:NORMAL TO val. }
}

// Cost of the trajectory the node currently produces. Lower is better;
// 9e11 marks an unflyable case (lost encounter, moon impact, no return).
LOCAL FUNCTION _frCost {
    PARAMETER nd. PARAMETER targetBody. PARAMETER want.
    WAIT 0.1.   // let KSP recompute the node's patches
    LOCAL meas IS measureArrival(nd, targetBody).
    IF meas = 0 { RETURN 9.0e11. }
    LOCAL munPe IS meas["pe"].
    IF munPe < 0 { RETURN 9.0e11. }
    LOCAL homePe IS freeReturnPostFlybyPe(nd, targetBody).
    IF homePe < 0 { RETURN 9.0e11. }
    LOCAL c IS ABS(homePe - want).
    IF munPe < FREE_RETURN_MUN_PE_FLOOR {
        SET c TO c + (FREE_RETURN_MUN_PE_FLOOR - munPe) * 5.
    }
    RETURN c.
}

// Plan a free-return correction node (added to the flight plan).
LOCAL FUNCTION _frSolve {
    PARAMETER targetBody.
    LOCAL want IS freeReturnTargetPe().
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
    LOCAL nd IS NODE(TIME:SECONDS + FREE_RT_LEAD, 0, 0, 0).
    ADD nd.
    LOCAL best IS _frCost(nd, targetBody, want).

    FOR step IN LIST(40, 12, 4, 1, 0.3) {
        LOCAL improved IS TRUE.
        LOCAL guard IS 0.
        UNTIL NOT improved OR guard >= 8 {
            SET improved TO FALSE.
            SET guard TO guard + 1.
            FOR ax IN LIST("PROGRADE", "NORMAL", "RADIALOUT") {
                FOR sgn IN LIST(1, -1) {
                    LOCAL old IS _frNodeGet(nd, ax).
                    _frNodeSet(nd, ax, old + step * sgn).
                    LOCAL c IS _frCost(nd, targetBody, want).
                    IF c < best - 50 {
                        SET best TO c.
                        SET improved TO TRUE.
                    } ELSE {
                        _frNodeSet(nd, ax, old).
                    }
                }
            }
        }
    }
    RETURN nd.
}

GLOBAL FUNCTION phaseFreeRtBplane {
    LOCAL targetBody IS _frTargetBody().
    IF targetBody = 0 {
        mLogError("FREE_RT_BPLANE: no valid target body — set FREE_RT_TARGET or TARGET_.").
        yieldToPrompt().
        RETURN.
    }
    IF measureArrival(0, targetBody) = 0 {
        mLogError("FREE_RT_BPLANE: no " + targetBody:NAME
            + " encounter to free-return from (XING must run first).").
        yieldToPrompt().
        RETURN.
    }

    LOCAL want IS freeReturnTargetPe().
    mLogWarn("STATS free-rt setup body=" + targetBody:NAME
        + " wantPeKm=" + ROUND(want / 1000, 1)
        + " startPostFlybyKm=" + ROUND(freeReturnPostFlybyPe(0, targetBody) / 1000, 1)).

    LOCAL attempt IS 0.
    UNTIL attempt >= FREE_RT_MAX_RETRIES {
        SET attempt TO attempt + 1.
        LOCAL nd IS _frSolve(targetBody).

        // --- Hard safety gate: only fly a real, safe free return ---
        LOCAL homePe IS freeReturnPostFlybyPe(nd, targetBody).
        LOCAL meas IS measureArrival(nd, targetBody).
        LOCAL munPe IS -1.
        IF meas <> 0 { SET munPe TO meas["pe"]. }
        LOCAL dv IS nd:DELTAV:MAG.
        mLogWarn("STATS free-rt result attempt=" + attempt
            + " postFlybyKm=" + ROUND(homePe / 1000, 1)
            + " munPeKm=" + ROUND(munPe / 1000, 1)
            + " dv=" + ROUND(dv, 1)).

        IF homePe >= 0
                AND ABS(homePe - want) <= FREE_RT_ACCEPT_TOL
                AND munPe >= FREE_RETURN_MUN_PE_FLOOR
                AND dv <= FREE_RT_DV_CAP {
            mLog("Free return found: post-flyby Pe "
                + ROUND(homePe / 1000, 1) + "km, Mun Pe "
                + ROUND(munPe / 1000, 1) + "km, dV " + ROUND(dv, 1) + ".").
            IF executeManeuver() {
                nextPhase(xferSeq).
                RETURN.
            }
            mLog("FREE_RT_BPLANE: correction burn missed — replanning.").
            WAIT 5.
        } ELSE {
            mLogWarn("FREE_RT_BPLANE: attempt " + attempt
                + " not a safe free return — retrying.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
            WAIT 3.
        }
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
    mLogError("FREE_RT_BPLANE: could not find a safe free return in "
        + FREE_RT_MAX_RETRIES + " attempts — holding for operator. "
        + "Do NOT continue to the flyby without a return trajectory.").
    yieldToPrompt().
}
