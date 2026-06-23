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
