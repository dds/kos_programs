// ============================================================
// xfer_plan.ks  —  Transfer departure phases  (0:/lib/xfer_plan.ks)
//
// phaseTransfer   — plan + execute the transfer burn
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL CAPTURE_PE IS -1.
GLOBAL CAPTURE_INC IS -1.
GLOBAL CAPTURE_LAN IS -1.
GLOBAL CAPTURE_AOP IS -1.
GLOBAL CAPTURE_DIR IS "".
GLOBAL ESCAPE_PE IS -1.
GLOBAL ESCAPE_LAN IS -1.
GLOBAL ESCAPE_AOP IS -1.

LOCAL MAX_RETRIES IS 5.
GLOBAL TRANSFER_POST_BURN_HANDOFF_SOI_MULT IS 1.0.

LOCAL FUNCTION _recordXingArrivalUt {
    PARAMETER targetBody.

    IF NOT SHIP:ORBIT:HASNEXTPATCH { RETURN. }
    LOCAL p IS SHIP:ORBIT.
    UNTIL NOT p:HASNEXTPATCH {
        LOCAL transitionEta IS p:NEXTPATCHETA.
        SET p TO p:NEXTPATCH.
        IF p:BODY = targetBody {
            LOCAL arrivalUt IS TIME:SECONDS + transitionEta.
            stateSet("xing_arrival_ut", arrivalUt).
            stateSet("xing_arrival_target", targetBody:NAME).
            mLog("XING arrival checkpoint: T+"
                + ROUND(arrivalUt - TIME:SECONDS, 0) + "s.").
            RETURN.
        }
    }
}

LOCAL FUNCTION _handoffArrivalEstimate {
    PARAMETER targetBody.

    LOCAL arrivalUt IS stateGetNum("xing_arrival_ut", 0).
    LOCAL arrivalTarget IS stateGet("xing_arrival_target", "").
    IF arrivalUt > TIME:SECONDS AND arrivalTarget = targetBody:NAME {
        RETURN arrivalUt.
    }

    IF SHIP:BODY:HASBODY AND targetBody:HASBODY
            AND SHIP:BODY:BODY = targetBody:BODY {
        LOCAL rOrigin IS SHIP:BODY:ORBIT:SEMIMAJORAXIS.
        LOCAL rTarget IS targetBody:ORBIT:SEMIMAJORAXIS.
        LOCAL aTransfer IS (rOrigin + rTarget) / 2.
        LOCAL tof IS CONSTANT:PI * SQRT(aTransfer ^ 3 / targetBody:BODY:MU).
        RETURN TIME:SECONDS + tof.
    }
    RETURN TIME:SECONDS + MAX(3600, targetBody:ORBIT:PERIOD / 2).
}

LOCAL FUNCTION _postBurnTransferHandoffOk {
    PARAMETER targetBody.
    PARAMETER label IS "post-burn".

    LOCAL peMax IS targetBody:SOIRADIUS * TRANSFER_POST_BURN_HANDOFF_SOI_MULT.
    LOCAL patch IS _getTargetPatch(SHIP, targetBody).
    IF patch <> 0 AND patch:PERIAPSIS > 0 AND patch:PERIAPSIS <= peMax {
        _recordXingArrivalUt(targetBody).
        mLog("STATS transfer handoff label=" + label
            + " status=patch"
            + " target=" + targetBody:NAME
            + " PeKm=" + ROUND(patch:PERIAPSIS / 1000, 1)
            + " soiKm=" + ROUND(targetBody:SOIRADIUS / 1000, 1)
            + " body=" + SHIP:BODY:NAME
            + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 4)).
        RETURN TRUE.
    }

    IF SHIP:STATUS <> "ESCAPING" AND SHIP:ORBIT:ECCENTRICITY < 1 {
        RETURN FALSE.
    }

    LOCAL arriveUt IS _handoffArrivalEstimate(targetBody).
    LOCAL pad IS MAX(21600, (arriveUt - TIME:SECONDS) * 0.25).
    LOCAL ca IS _findClosestApproach(
        targetBody, arriveUt - pad, arriveUt + pad, 48).
    IF ca["distance"] <= peMax {
        stateSet("xing_arrival_ut", ca["time"]).
        stateSet("xing_arrival_target", targetBody:NAME).
        mLog("STATS transfer handoff label=" + label
            + " status=closest-approach"
            + " target=" + targetBody:NAME
            + " caKm=" + ROUND(ca["distance"] / 1000, 1)
            + " soiKm=" + ROUND(targetBody:SOIRADIUS / 1000, 1)
            + " arrivalT=" + ROUND(ca["time"] - TIME:SECONDS, 0)
            + " body=" + SHIP:BODY:NAME
            + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 4)).
        RETURN TRUE.
    }
    mLog("STATS transfer handoff label=" + label
        + " status=no-handoff"
        + " target=" + targetBody:NAME
        + " caKm=" + ROUND(ca["distance"] / 1000, 1)
        + " soiKm=" + ROUND(targetBody:SOIRADIUS / 1000, 1)).
    RETURN FALSE.
}

GLOBAL FUNCTION phaseTransfer {
    LOCAL target IS missionTargetBody().
    orbitSummary().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    IF NOT HASNODE AND _postBurnTransferHandoffOk(target, "phase-entry") {
        orbitSummary().
        nextPhase(xferSeq).
        RETURN.
    }

    IF HASNODE {
        LOCAL existing IS NEXTNODE.
        LOCAL pending IS stateGet("burn_pending", "false").
        mLog("STATS transfer resume existing-node pending=" + pending
            + " burnPhase=" + stateGet("burn_phase", "")
            + " dv="
            + ROUND(existing:DELTAV:MAG,1)
            + " eta=" + ROUND(existing:ETA,1)
            + " body=" + SHIP:BODY:NAME).
        SET success TO executeManeuver().
        IF success {
            _recordXingArrivalUt(target).
            orbitSummary().
            nextPhase(xferSeq).
            RETURN.
        }
        IF _postBurnTransferHandoffOk(target, "existing-node-failed") {
            orbitSummary().
            nextPhase(xferSeq).
            RETURN.
        }
        mLogWarn("Existing transfer node was not usable; replanning.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    } ELSE IF stateGet("burn_pending", "false") = "true" {
        IF _postBurnTransferHandoffOk(target, "missing-node-pending") {
            orbitSummary().
            nextPhase(xferSeq).
            RETURN.
        }
        mLog("STATS transfer resume missing-node pending=true burnPhase="
            + stateGet("burn_phase", "")
            + " burnDv=" + ROUND(stateGetNum("burn_dv", 0),1)
            + " — replanning.").
    }

    UNTIL success {
        LOCAL xLan IS -1.
        LOCAL xAoP IS -1.
        SET xLan TO CAPTURE_LAN.
        SET xAoP TO CAPTURE_AOP.
        LOCAL transferNode IS planTransfer(target, CAPTURE_PE, xLan, xAoP).
        IF transferNode = 0 OR NOT transferNode:ISTYPE("Node") {
            SET retries TO retries + 1.
            mLogError("Transfer planning failed; yielding for manual control.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            PRINT " ".
            PRINT "  TRANSFER PLANNING FAILED".
            PRINT "  No maneuver was executed. Manual control is available.".
            yieldToPrompt().
            RETURN.
        } ELSE {
            mLog("Transfer planned.").
            SET success TO executeManeuver().
            IF NOT success {
                IF _postBurnTransferHandoffOk(target, "planned-node-failed") {
                    orbitSummary().
                    nextPhase(xferSeq).
                    RETURN.
                }
                SET retries TO retries + 1.
                mLog("Transfer missed (attempt " + retries + ") — waiting 10s and replanning.").
                UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
                IF retries >= MAX_RETRIES {
                    mLogError("Transfer failed after " + retries + " attempts — halting.").
                    RETURN.
                }
                WAIT 10.
            }
        }
    }
    _recordXingArrivalUt(target).
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseXing {
    phaseTransfer().
}

GLOBAL FUNCTION phaseEscape {
    LOCAL escapePe IS ESCAPE_PE.
    LOCAL escapeLan IS -1.
    LOCAL escapeAop IS -1.

    SET escapeLan TO ESCAPE_LAN.
    SET escapeAop TO ESCAPE_AOP.

    // Target is always the parent body
    LOCAL target IS BODY:BODY.
    LOCAL targetKerbin IS target:NAME:TOUPPER = "KERBIN".

    // Cache and mask the global capture inclination so the raw departure
    // planner performs a purely efficient "dumb" prograde escape.
    LOCAL cachedIncTarget IS CAPTURE_INC.
    SET CAPTURE_INC TO -1.

    orbitSummary().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL transferNode IS planTransfer(target, escapePe, escapeLan, escapeAop).
        IF transferNode = 0 OR NOT transferNode:ISTYPE("Node") {
            SET retries TO retries + 1.
            mLogError("Escape planning failed; yielding for manual control.").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            PRINT " ".
            PRINT "  ESCAPE PLANNING FAILED".
            PRINT "  No maneuver was executed. Manual control is available.".
            yieldToPrompt().
            RETURN.
        } ELSE {
            // Overwrite CAPTURE_* for downstream correction reuse
            SET CAPTURE_PE TO escapePe.
            IF ESCAPE_LAN >= 0 { SET CAPTURE_LAN TO escapeLan. }
            ELSE { SET CAPTURE_LAN TO -1. }
            IF ESCAPE_AOP >= 0 { SET CAPTURE_AOP TO escapeAop. }
            ELSE { SET CAPTURE_AOP TO -1. }

            // Restore the target for downstream phases. If this is a Kerbin return,
            // explicitly set the target to equatorial so REFINE_BPLANE picks it up.
            IF targetKerbin {
                SET CAPTURE_INC TO 0.
                mLog("Escape planned. Handoff to REFINE_BPLANE: targeting 0 deg arrival inc.").
            } ELSE {
                SET CAPTURE_INC TO cachedIncTarget.
            }
            SET CAPTURE_DIR TO "".

            mLog("Escape planned.").
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                mLog("Escape burn missed (attempt " + retries + ") — waiting 10s and replanning.").
                UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
                IF retries >= MAX_RETRIES {
                    mLogError("Escape failed after " + retries + " attempts — halting.").
                    RETURN.
                }
                WAIT 10.
            }
        }
    }
    nextPhase(xferSeq).
}
