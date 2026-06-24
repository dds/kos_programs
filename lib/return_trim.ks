// ============================================================
// return_trim.ks — high-leverage reentry-longitude trim (0:/lib/return_trim.ks)
//
// Runs on the home-body approach AFTER a flyby (FLYBY -> RETURN_TRIM ->
// AEROBRAKE). A small burn far from periapsis has enormous leverage on
// where the craft hits the ground: a few m/s shifts the arrival time by
// minutes, and the body rotates degrees underneath in that time. This
// phase spends that leverage to walk the predicted atmosphere-entry
// sub-point toward the target longitude (e.g. KSC), so AEROBRAKE's
// short-range (~200 km) impact nudge has something close to refine.
//
// Why not Trajectories: TR can't resolve an impact far out on a fast,
// shallow return (the same reason AEROBRAKE no longer warp-waits for it).
// So the predictor is numeric and node-aware: sample POSITIONAT to find
// where the (post-node) trajectory crosses the atmosphere interface, and
// convert that world position to a surface sub-point, rotating the body
// forward to the crossing time. Pure hill-climb on the game's own
// propagation — no analytic plane math, so left-handed-frame sign traps
// can't bite.
//
// SAFETY: the free return already guarantees a safe reentry periapsis, so
// this trim is purely OPTIONAL precision. It never holds the return — if
// it can't find a trim that meaningfully improves the miss within the dV
// cap AND keeps Pe inside the safe corridor, it hands off to AEROBRAKE
// untouched. A wrong prediction costs accuracy, never the crew.
//
// Config:
//   RETURN_TRIM            — flag: run this phase (else skip through)
//   RETURN_TRIM_TARGET_LAT/LNG — site; -9999 => use TARGET_LAT/TARGET_LNG
//   RETURN_TRIM_TOL_KM     — miss this close => good enough, skip
//   RETURN_TRIM_DV_CAP     — never fly a trim bigger than this (m/s)
//   RETURN_TRIM_LEAD       — node placed this many seconds out
//   RETURN_TRIM_PE_MIN/MAX — reentry-Pe corridor the trim must preserve
//   RETURN_TRIM_MIN_PE_ETA — too close to Pe for leverage => leave to AEROBRAKE
//   RETURN_TRIM_MAX_RETRIES
// Depends on: maneuver (executeManeuver), utils (geoDistance)
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL RETURN_TRIM IS FALSE.
GLOBAL RETURN_TRIM_TARGET_LAT IS -9999.
GLOBAL RETURN_TRIM_TARGET_LNG IS -9999.
GLOBAL RETURN_TRIM_TOL_KM IS 120.
GLOBAL RETURN_TRIM_DV_CAP IS 80.
GLOBAL RETURN_TRIM_LEAD IS 120.
GLOBAL RETURN_TRIM_PE_MIN IS 18000.
GLOBAL RETURN_TRIM_PE_MAX IS 55000.
GLOBAL RETURN_TRIM_MIN_PE_ETA IS 600.
GLOBAL RETURN_TRIM_MAX_RETRIES IS 5.

LOCAL FUNCTION _rtNorm180 {
    PARAMETER deg.
    LOCAL d IS MOD(deg, 360).
    IF d > 180 { SET d TO d - 360. }
    IF d < -180 { SET d TO d + 360. }
    RETURN d.
}

LOCAL FUNCTION _rtTargetGeo {
    LOCAL la IS -0.0972.   // KSC pad
    LOCAL ln IS -74.5577.
    IF DEFINED TARGET_LAT { SET la TO TARGET_LAT. }
    IF DEFINED TARGET_LNG { SET ln TO TARGET_LNG. }
    IF RETURN_TRIM_TARGET_LAT > -9999 { SET la TO RETURN_TRIM_TARGET_LAT. }
    IF RETURN_TRIM_TARGET_LNG > -9999 { SET ln TO RETURN_TRIM_TARGET_LNG. }
    RETURN LATLNG(la, ln).
}

LOCAL FUNCTION _rtAtmoHeight {
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN -1. }
    RETURN SHIP:BODY:ATM:HEIGHT.
}

// Altitude (m, over the body's surface radius) the ship will have at
// time t, on its currently-planned trajectory (which includes a planned
// node). Frame-safe: both POSITIONATs are taken at the same time t, so
// the body's own motion cancels in the difference.
LOCAL FUNCTION _rtAltAt {
    PARAMETER t.
    RETURN (POSITIONAT(SHIP, t) - POSITIONAT(SHIP:BODY, t)):MAG
        - SHIP:BODY:RADIUS.
}

// Time the (planned) trajectory first descends through the atmosphere
// interface. Searches a window bracketing the live periapsis, so it's
// cheap even when periapsis is hours away. -1 = never enters in window
// (a skip-out / too-shallow graze).
LOCAL FUNCTION _rtEntryTime {
    LOCAL atmo IS _rtAtmoHeight().
    IF atmo < 0 { RETURN -1. }
    LOCAL t0 IS TIME:SECONDS.
    LOCAL peUt IS t0 + ETA:PERIAPSIS.
    LOCAL scanStart IS MAX(t0 + 5, peUt - 900).
    LOCAL tEnd IS peUt + 120.
    LOCAL prev IS scanStart.
    LOCAL t IS scanStart + 10.
    UNTIL t > tEnd {
        IF _rtAltAt(t) < atmo {
            LOCAL lo IS prev.
            LOCAL hi IS t.
            FROM { LOCAL i IS 0. } UNTIL i >= 16 STEP { SET i TO i + 1. } DO {
                LOCAL mid IS (lo + hi) / 2.
                IF _rtAltAt(mid) < atmo { SET hi TO mid. } ELSE { SET lo TO mid. }
            }
            RETURN (lo + hi) / 2.
        }
        SET prev TO t.
        SET t TO t + 10.
    }
    RETURN -1.
}

// Surface sub-point of the (planned) trajectory at time tE. GEOPOSITIONOF
// reads the body at its CURRENT orientation, so rotate longitude forward
// by the body's rotation over (tE - now). Latitude is rotation-invariant.
LOCAL FUNCTION _rtEntrySubGeo {
    PARAMETER tE.
    LOCAL g IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, tE)).
    LOCAL rotRate IS 360 / SHIP:BODY:ROTATIONPERIOD.   // deg/s, eastward
    RETURN LATLNG(g:LAT, _rtNorm180(g:LNG - rotRate * (tE - TIME:SECONDS))).
}

LOCAL FUNCTION _rtNodeGet {
    PARAMETER nd. PARAMETER axis.
    IF axis = "PROGRADE" { RETURN nd:PROGRADE. }
    RETURN nd:NORMAL.
}

LOCAL FUNCTION _rtNodeSet {
    PARAMETER nd. PARAMETER axis. PARAMETER val.
    IF axis = "PROGRADE" { SET nd:PROGRADE TO val. }
    ELSE { SET nd:NORMAL TO val. }
}

// Cost of the trajectory the node currently produces: great-circle miss
// (m) from the predicted entry sub-point to the site. 9e11 rejects an
// unflyable case — Pe out of the safe corridor, or no atmosphere entry.
LOCAL FUNCTION _rtCost {
    PARAMETER nd. PARAMETER tgt.
    WAIT 0.1.   // let KSP recompute the node's orbit/patches
    LOCAL pe IS nd:ORBIT:PERIAPSIS.
    IF pe < RETURN_TRIM_PE_MIN OR pe > RETURN_TRIM_PE_MAX { RETURN 9.0e11. }
    LOCAL tE IS _rtEntryTime().
    IF tE < 0 { RETURN 9.0e11. }
    LOCAL sub IS _rtEntrySubGeo(tE).
    RETURN geoDistance(sub:LAT, sub:LNG, tgt:LAT, tgt:LNG).
}

// Hill-climb a small prograde/normal node to minimize the entry miss,
// coarse-to-fine over decreasing steps (the free_return recipe).
LOCAL FUNCTION _rtSolve {
    PARAMETER tgt.
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
    LOCAL nd IS NODE(TIME:SECONDS + RETURN_TRIM_LEAD, 0, 0, 0).
    ADD nd.
    LOCAL best IS _rtCost(nd, tgt).

    FOR step IN LIST(20, 6, 2, 0.5) {
        LOCAL improved IS TRUE.
        LOCAL guard IS 0.
        UNTIL NOT improved OR guard >= 8 {
            SET improved TO FALSE.
            SET guard TO guard + 1.
            FOR ax IN LIST("PROGRADE", "NORMAL") {
                FOR sgn IN LIST(1, -1) {
                    LOCAL old IS _rtNodeGet(nd, ax).
                    _rtNodeSet(nd, ax, old + step * sgn).
                    LOCAL c IS _rtCost(nd, tgt).
                    IF c < best - 1000 {   // require >1km improvement
                        SET best TO c.
                        SET improved TO TRUE.
                    } ELSE {
                        _rtNodeSet(nd, ax, old).
                    }
                }
            }
        }
    }
    RETURN nd.
}

GLOBAL FUNCTION phaseReturnTrim {
    mLogPhase("RETURN_TRIM").

    IF NOT RETURN_TRIM {
        mLog("RETURN_TRIM disabled by config — skipping.").
        nextPhase(xferSeq). RETURN.
    }
    IF NOT SHIP:BODY:ATM:EXISTS {
        mLog("RETURN_TRIM: " + SHIP:BODY:NAME + " has no atmosphere — "
            + "not a reentry approach; skipping.").
        nextPhase(xferSeq). RETURN.
    }
    LOCAL atmo IS _rtAtmoHeight().
    IF SHIP:PERIAPSIS >= atmo {
        mLog("RETURN_TRIM: periapsis " + ROUND(SHIP:PERIAPSIS / 1000, 1)
            + "km is above the atmosphere — no reentry to trim; skipping.").
        nextPhase(xferSeq). RETURN.
    }
    LOCAL peEta IS ETA:PERIAPSIS.
    IF peEta < RETURN_TRIM_MIN_PE_ETA {
        mLog("RETURN_TRIM: only " + ROUND(peEta) + "s to periapsis — too "
            + "close for a high-leverage trim; leaving it to AEROBRAKE.").
        nextPhase(xferSeq). RETURN.
    }

    LOCAL tgt IS _rtTargetGeo().
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
    LOCAL baseTE IS _rtEntryTime().
    IF baseTE < 0 {
        mLog("RETURN_TRIM: no atmosphere entry on the current trajectory "
            + "(shallow graze / skip-out) — leaving it to AEROBRAKE.").
        nextPhase(xferSeq). RETURN.
    }
    LOCAL baseSub IS _rtEntrySubGeo(baseTE).
    LOCAL baseDist IS geoDistance(baseSub:LAT, baseSub:LNG, tgt:LAT, tgt:LNG).
    mLogWarn("STATS return-trim setup targetLng=" + ROUND(tgt:LNG, 2)
        + " entrySubLat=" + ROUND(baseSub:LAT, 2)
        + " entrySubLng=" + ROUND(baseSub:LNG, 2)
        + " missKm=" + ROUND(baseDist / 1000, 1)
        + " peEtaMin=" + ROUND(peEta / 60, 1)).

    IF baseDist <= RETURN_TRIM_TOL_KM * 1000 {
        mLog("RETURN_TRIM: predicted entry already "
            + ROUND(baseDist / 1000, 1) + "km from target (within "
            + RETURN_TRIM_TOL_KM + "km) — AEROBRAKE will fine-tune. Skipping.").
        nextPhase(xferSeq). RETURN.
    }

    LOCAL attempt IS 0.
    UNTIL attempt >= RETURN_TRIM_MAX_RETRIES {
        SET attempt TO attempt + 1.
        LOCAL nd IS _rtSolve(tgt).
        LOCAL dv IS nd:DELTAV:MAG.
        LOCAL pe IS nd:ORBIT:PERIAPSIS.
        LOCAL solDist IS baseDist.
        LOCAL solTE IS _rtEntryTime().
        IF solTE >= 0 {
            LOCAL s IS _rtEntrySubGeo(solTE).
            SET solDist TO geoDistance(s:LAT, s:LNG, tgt:LAT, tgt:LNG).
        }
        mLogWarn("STATS return-trim result attempt=" + attempt
            + " missKm=" + ROUND(solDist / 1000, 1)
            + " dv=" + ROUND(dv, 1)
            + " peKm=" + ROUND(pe / 1000, 1)).

        // Only fly a trim that meaningfully improves the miss, stays under
        // the dV cap, and keeps Pe inside the safe reentry corridor.
        IF solDist < baseDist - RETURN_TRIM_TOL_KM * 500
                AND dv <= RETURN_TRIM_DV_CAP
                AND pe >= RETURN_TRIM_PE_MIN AND pe <= RETURN_TRIM_PE_MAX {
            mLog("RETURN_TRIM: trimming entry " + ROUND(baseDist / 1000, 1)
                + "km -> ~" + ROUND(solDist / 1000, 1) + "km (dV "
                + ROUND(dv, 1) + ", Pe " + ROUND(pe / 1000, 1) + "km).").
            IF executeManeuver() {
                nextPhase(xferSeq). RETURN.
            }
            mLog("RETURN_TRIM: trim burn missed — replanning.").
            WAIT 5.
        } ELSE {
            mLogWarn("RETURN_TRIM: attempt " + attempt + " found no safe "
                + "improvement — retrying.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
            WAIT 2.
        }
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.05. }
    mLogWarn("RETURN_TRIM: no safe high-leverage trim in "
        + RETURN_TRIM_MAX_RETRIES + " attempts — handing off to AEROBRAKE. "
        + "Return Pe is already safe; AEROBRAKE will nudge the impact.").
    nextPhase(xferSeq).
}
