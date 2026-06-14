// ============================================================
// xfer_plan.ks  —  Transfer departure phases  (0:/lib/xfer_plan.ks)
//
// phaseTransfer   — plan + execute the transfer burn
// ============================================================

LOCAL MAX_RETRIES IS 5.

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
        IF CFG:HASKEY("CAPTURE_LAN") { SET xLan TO CFG["CAPTURE_LAN"]. }
        IF CFG:HASKEY("CAPTURE_AOP") { SET xAoP TO CFG["CAPTURE_AOP"]. }
        LOCAL transferNode IS planTransfer(target, CFG["CAPTURE_PE"], xLan, xAoP).
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
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseXing {
    phaseTransfer().
}

GLOBAL FUNCTION phaseEscape {
    LOCAL escapePe IS CFG["ESCAPE_PE"].
    LOCAL escapeLan IS -1.
    LOCAL escapeAop IS -1.

    IF CFG:HASKEY("ESCAPE_LAN") { SET escapeLan TO CFG["ESCAPE_LAN"]. }
    IF CFG:HASKEY("ESCAPE_AOP") { SET escapeAop TO CFG["ESCAPE_AOP"]. }

    // Target is always the parent body
    LOCAL target IS BODY:BODY.

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
            cfgSet("CAPTURE_PE", escapePe).
            IF CFG:HASKEY("ESCAPE_LAN") { cfgSet("CAPTURE_LAN", escapeLan). }
            ELSE IF CFG:HASKEY("CAPTURE_LAN") { CFG:REMOVE("CAPTURE_LAN"). }
            IF CFG:HASKEY("ESCAPE_AOP") { cfgSet("CAPTURE_AOP", escapeAop). }
            ELSE IF CFG:HASKEY("CAPTURE_AOP") { CFG:REMOVE("CAPTURE_AOP"). }

            // Clear outbound capture plane config
            IF CFG:HASKEY("CAPTURE_INC") { CFG:REMOVE("CAPTURE_INC"). }
            IF CFG:HASKEY("CAPTURE_DIR") { CFG:REMOVE("CAPTURE_DIR"). }

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
