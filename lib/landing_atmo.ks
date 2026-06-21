// ============================================================
// landing_atmo.ks  —  Drift-baselined in-atmosphere impact walk
// (0:/lib/landing_atmo.ks)
//
// ATMO_WALK phase. Closes the Trajectories-predicted impact onto the
// landing target DURING atmospheric entry, before chutes. Thrust-only,
// closed-loop. The trick (see docs/PLAN_duna_precision_landing.md):
// never model drag — coast thrust-free to MEASURE the impact's drag
// drift, then attribute only the excess-over-drift of a pulse to that
// pulse, so drag motion is not mis-credited to thrust. Hands to DESCENT
// (chutes) at a floor altitude.
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL ATMO_WALK_ENABLED IS 1.
GLOBAL ATMO_WALK_TOLERANCE IS 1500.       // m offset to accept and stop
GLOBAL ATMO_WALK_BASELINE_SEC IS 4.       // drag-drift measurement window
GLOBAL ATMO_WALK_PULSE_SEC IS 2.          // max length of one thrust pulse
GLOBAL ATMO_WALK_SETTLE_SEC IS 3.         // let TR update after a pulse
GLOBAL ATMO_WALK_PULSE_DV_MIN IS 3.       // m/s
GLOBAL ATMO_WALK_PULSE_DV_MAX IS 25.      // m/s
GLOBAL ATMO_WALK_GAIN0 IS 250.            // initial m-offset closed per m/s
GLOBAL ATMO_WALK_MAX_DV IS 400.           // total walk budget (reserve is
                                          // implicit: cap << craft spare dV)
GLOBAL ATMO_WALK_FLOOR_ALT IS 10000.      // hand to DESCENT at/below this
GLOBAL ATMO_WALK_ALIGN_DEG IS 15.         // alignment gate before a pulse
GLOBAL ATMO_WALK_ALIGN_TIMEOUT IS 12.

// Horizontal impact-to-target offset (m), perpendicular to local up.
// Positive vector points FROM the target TO the predicted impact.
LOCAL FUNCTION _atmoImpactOffset {
    PARAMETER tgtLat.
    PARAMETER tgtLng.
    IF NOT ADDONS:TR:HASIMPACT {
        RETURN LEXICON("FOUND", FALSE, "VEC", V(0,0,0), "DIST", 0).
    }
    LOCAL imp IS ADDONS:TR:IMPACTPOS.
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL offVec IS VXCL(upVec,
        LATLNG(imp:LAT, imp:LNG):POSITION - LATLNG(tgtLat, tgtLng):POSITION).
    RETURN LEXICON("FOUND", TRUE, "VEC", offVec, "DIST", offVec:MAG).
}

LOCAL FUNCTION _atmoShipAccel {
    RETURN SHIP:AVAILABLETHRUST / MAX(0.01, SHIP:MASS).
}

GLOBAL FUNCTION phaseAtmoWalk {
    mLogPhase("ATMO_WALK").

    IF ATMO_WALK_ENABLED <= 0 {
        mLog("ATMO_WALK disabled by config — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }
    IF NOT SHIP:BODY:ATM:EXISTS {
        mLog("ATMO_WALK on airless body — nothing to do.").
        nextPhase(xferSeq).
        RETURN.
    }
    IF NOT ADDONS:TR:AVAILABLE {
        mLogWarn("ATMO_WALK: Trajectories unavailable — skipping (chutes land untargeted).").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL tgt IS landingResolveTarget().
    IF NOT tgt["FOUND"] {
        mLogWarn("ATMO_WALK: no landing target resolved — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }
    LOCAL tgtLat IS tgt["LAT"].
    LOCAL tgtLng IS tgt["LNG"].
    ADDONS:TR:SETTARGET(LATLNG(tgtLat, tgtLng)).
    mLog("ATMO_WALK target: " + tgt["SOURCE"] + " "
        + ROUND(tgtLat, 3) + "," + ROUND(tgtLng, 3) + ".").

    // Wait until inside the atmosphere — the walk only has authority
    // over the predicted impact once drag is acting.
    LOCAL atmTop IS SHIP:BODY:ATM:HEIGHT.
    IF SHIP:ALTITUDE > atmTop {
        mLog("ATMO_WALK: waiting for atmosphere (" + ROUND(atmTop/1000,0) + "km)...").
        WAIT UNTIL SHIP:ALTITUDE <= atmTop OR SHIP:STATUS = "LANDED".
    }

    SAS OFF.
    LOCAL gain IS MAX(1, ATMO_WALK_GAIN0).
    LOCAL spentDv IS 0.
    LOCAL cycles IS 0.
    LOCAL stopReason IS "".

    UNTIL stopReason <> "" {
        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            SET stopReason TO "landed". BREAK.
        }
        IF SHIP:ALTITUDE <= ATMO_WALK_FLOOR_ALT { SET stopReason TO "floor-alt". BREAK. }
        IF spentDv >= ATMO_WALK_MAX_DV { SET stopReason TO "dv-cap". BREAK. }

        // --- Baseline: measure drag drift thrust-free ---
        LOCK THROTTLE TO 0.
        LOCK STEERING TO SRFRETROGRADE.
        LOCAL o0 IS _atmoImpactOffset(tgtLat, tgtLng).
        IF NOT o0["FOUND"] { SET stopReason TO "no-impact". BREAK. }
        LOCAL t0 IS TIME:SECONDS.
        WAIT ATMO_WALK_BASELINE_SEC.
        LOCAL o1 IS _atmoImpactOffset(tgtLat, tgtLng).
        IF NOT o1["FOUND"] { SET stopReason TO "no-impact". BREAK. }
        LOCAL offset IS o1["VEC"].
        LOCAL driftRate IS (o1["VEC"] - o0["VEC"]) / MAX(0.1, TIME:SECONDS - t0).

        IF offset:MAG <= ATMO_WALK_TOLERANCE { SET stopReason TO "within-tolerance". BREAK. }

        // --- Pulse toward the target (horizontal correction dir) ---
        LOCAL corrDir IS (-1 * offset):NORMALIZED.
        LOCAL pulseDv IS MAX(ATMO_WALK_PULSE_DV_MIN,
            MIN(ATMO_WALK_PULSE_DV_MAX, offset:MAG / gain)).

        LOCK STEERING TO corrDir.
        LOCAL alignEnd IS TIME:SECONDS + ATMO_WALK_ALIGN_TIMEOUT.
        WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, corrDir) <= ATMO_WALK_ALIGN_DEG
            OR TIME:SECONDS > alignEnd.

        LOCAL oA IS _atmoImpactOffset(tgtLat, tgtLng).
        LOCAL pStart IS TIME:SECONDS.
        LOCAL applied IS 0.
        LOCK THROTTLE TO 1.
        UNTIL applied >= pulseDv OR (TIME:SECONDS - pStart) >= ATMO_WALK_PULSE_SEC {
            LOCAL dt IS 0.1.
            WAIT dt.
            SET applied TO applied + _atmoShipAccel() * dt.
        }
        LOCK THROTTLE TO 0.
        SET spentDv TO spentDv + applied.

        // --- Settle, then attribute excess-over-drift to the pulse ---
        WAIT ATMO_WALK_SETTLE_SEC.
        LOCAL oB IS _atmoImpactOffset(tgtLat, tgtLng).
        LOCAL effAlong IS 0.
        IF oA["FOUND"] AND oB["FOUND"] {
            LOCAL windowSec IS TIME:SECONDS - pStart.
            LOCAL pulseEffect IS (oB["VEC"] - oA["VEC"]) - driftRate * windowSec.
            // Offset closed toward target = component of effect along corrDir.
            SET effAlong TO VDOT(pulseEffect, corrDir).
            IF applied > 0.5 AND effAlong > 0 {
                LOCAL newGain IS effAlong / applied.
                SET gain TO MAX(1, 0.5 * gain + 0.5 * newGain).
            }
        }

        SET cycles TO cycles + 1.
        mLogWarn("STATS atmo-walk cycle=" + cycles
            + " altKm=" + ROUND(SHIP:ALTITUDE/1000, 1)
            + " offsetM=" + ROUND(offset:MAG, 0)
            + " driftMps=" + ROUND(driftRate:MAG, 1)
            + " pulseDv=" + ROUND(pulseDv, 1)
            + " effAlongM=" + ROUND(effAlong, 0)
            + " gain=" + ROUND(gain, 1)
            + " spentDv=" + ROUND(spentDv, 1)).
        _atmoWalkHud(offset:MAG, driftRate:MAG, spentDv).
    }

    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    LOCAL finalOff IS _atmoImpactOffset(tgtLat, tgtLng).
    mLog("ATMO_WALK done (" + stopReason + ") cycles=" + cycles
        + " spentDv=" + ROUND(spentDv, 1)
        + " finalOffsetM=" + ROUND(finalOff["DIST"], 0) + ".").
    mLogWarn("STATS atmo-walk result reason=" + stopReason
        + " cycles=" + cycles
        + " spentDv=" + ROUND(spentDv, 1)
        + " finalOffsetM=" + ROUND(finalOff["DIST"], 0)
        + " altKm=" + ROUND(SHIP:ALTITUDE/1000, 1)).
    nextPhase(xferSeq).
}

LOCAL FUNCTION _atmoWalkHud {
    PARAMETER offM.
    PARAMETER driftMps.
    PARAMETER spentDv.
    HUDTEXT("ATMO_WALK off=" + ROUND(offM/1000, 1) + "km drift="
        + ROUND(driftMps, 1) + "m/s dv=" + ROUND(spentDv, 0),
        2, 2, 14, CYAN, FALSE).
}
