// ============================================================
// xfer_plan.ks  —  Transfer departure phases  (0:/lib/xfer_plan.ks)
//
// phaseTransfer   — plan + execute the transfer burn
// phaseRendezvous — rendezvous with a target vessel/asteroid
// ============================================================

LOCAL MAX_RETRIES IS 5.

GLOBAL FUNCTION phaseRendezvous {
    LOCAL targetName IS "".
    IF CFG:HASKEY("RENDEZVOUS_TARGET") { SET targetName TO CFG["RENDEZVOUS_TARGET"]. }
    IF CFG:HASKEY("ASTEROID_TARGET")   { SET targetName TO CFG["ASTEROID_TARGET"]. }

    IF targetName = "" {
        mLogWarn("RDV phase requested but no RENDEZVOUS_TARGET or ASTEROID_TARGET configured.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL targetVessel IS VESSEL(targetName).
    LOCAL opts IS _rendezvousOptions().
    LOCAL success IS FALSE.
    LOCAL retries IS 0.

    orbitSummary().
    UNTIL success {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS planRendezvous(targetVessel, opts).
        IF nd = 0 {
            mLogError("Rendezvous planner failed for " + targetName + ".").
            RETURN.
        }
        mLog("Rendezvous planned with " + targetName + ".").
        SET success TO executeManeuver().
        IF NOT success {
            SET retries TO retries + 1.
            mLog("Rendezvous burn missed (attempt " + retries + ") — waiting 10s.").
            IF retries >= MAX_RETRIES {
                mLogError("Rendezvous failed after " + retries + " attempts.").
                RETURN.
            }
            WAIT 10.
        }
    }

    orbitSummary().
    nextPhase(xferSeq).
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

LOCAL FUNCTION _rendezvousOptions {
    LOCAL opts IS LEXICON().
    IF CFG:HASKEY("ASTEROID_MAX_DEPART_ORBITS") {
        opts:ADD("MAX_DEPART_ORBITS", CFG["ASTEROID_MAX_DEPART_ORBITS"]).
    }
    IF CFG:HASKEY("ASTEROID_DEPART_SAMPLES") {
        opts:ADD("DEPART_SAMPLES", CFG["ASTEROID_DEPART_SAMPLES"]).
    }
    IF CFG:HASKEY("ASTEROID_TOF_SAMPLES") {
        opts:ADD("TOF_SAMPLES", CFG["ASTEROID_TOF_SAMPLES"]).
    }
    IF CFG:HASKEY("ASTEROID_MIN_TOF") {
        opts:ADD("MIN_TOF", CFG["ASTEROID_MIN_TOF"]).
    }
    IF CFG:HASKEY("ASTEROID_MAX_TOF") {
        opts:ADD("MAX_TOF", CFG["ASTEROID_MAX_TOF"]).
    }
    IF CFG:HASKEY("ASTEROID_ARRIVAL_WEIGHT") {
        opts:ADD("ARRIVAL_WEIGHT", CFG["ASTEROID_ARRIVAL_WEIGHT"]).
    }
    IF CFG:HASKEY("ASTEROID_REFINE_ITERS") {
        opts:ADD("REFINE_ITERS", CFG["ASTEROID_REFINE_ITERS"]).
    }
    RETURN opts.
}
