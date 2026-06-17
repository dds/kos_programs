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

GLOBAL FUNCTION phaseTransfer {
    LOCAL target IS missionTargetBody().
    orbitSummary().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    IF HASNODE {
        LOCAL existing IS NEXTNODE.
        LOCAL pending IS stateGet("burn_pending", "false").
        mLogWarn("STATS transfer resume existing-node pending=" + pending
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
        mLogWarn("Existing transfer node was not usable; replanning.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    } ELSE IF stateGet("burn_pending", "false") = "true" {
        mLogWarn("STATS transfer resume missing-node pending=true burnPhase="
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
    IF targetKerbin AND CAPTURE_INC < 0 AND CAPTURE_DIR = "" {
        SET CAPTURE_INC TO 0.
        mLog("Kerbin return: targeting 0 deg arrival inclination for KSC approach.").
    }

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
            // Overwrite CAPTURE_* for downstream MCC reuse
            SET CAPTURE_PE TO escapePe.
            IF ESCAPE_LAN >= 0 { SET CAPTURE_LAN TO escapeLan. }
            ELSE { SET CAPTURE_LAN TO -1. }
            IF ESCAPE_AOP >= 0 { SET CAPTURE_AOP TO escapeAop. }
            ELSE { SET CAPTURE_AOP TO -1. }

            // Clear outbound capture plane config unless this is a Kerbin
            // return, where REFINE_BPLANE should keep the equatorial target.
            IF targetKerbin { SET CAPTURE_INC TO 0. }
            ELSE { SET CAPTURE_INC TO -1. }
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
