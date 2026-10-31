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

// Impact is a correction-required route, never a safe coast/capture result.
LOCAL FUNCTION _transferImpactHandoff {
    PARAMETER targetBody.
    IF ABORT OR phaseShouldYield OR WARP <> 0 OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR NOT transferCorrectionFollows(xferSeq) OR targetBody:BODY <> SHIP:BODY
            OR NOT SHIP:ORBIT:HASNEXTPATCH OR SHIP:ORBIT:NEXTPATCH:BODY <> targetBody
            OR targetBody:ATM:EXISTS OR NOT maneuverDepartureFlown()
            OR stateGet("mission_id","") = "" OR stateGetNum("burn_departure_time",-1) < 0
            OR stateGet("burn_departure_target","") <> targetBody:NAME
            OR NOT (SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
                AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0)
            OR NOT (TRANSFER_IMPACT_MIN_LEAD >= 600 AND TRANSFER_IMPACT_MIN_LEAD < 1e30) { RETURN FALSE. }
    LOCAL hit IS findArrivalPatch(0,targetBody).
    IF hit = 0 { RETURN FALSE. }
    LOCAL pe IS hit["patch"]:PERIAPSIS.
    IF NOT (pe <= 0 AND pe > -targetBody:RADIUS
            AND hit["entryUt"] < 1e30
            AND hit["entryUt"]-TIME:SECONDS > TRANSFER_IMPACT_MIN_LEAD) { RETURN FALSE. }
    LOCAL prior IS stateGet("xing_impact_handoff",LEXICON()).
    LOCAL stamped IS prior:HASKEY("MISSION") AND prior:HASKEY("LAUNCH")
        AND prior:HASKEY("TARGET") AND prior:HASKEY("DEPARTURE") AND prior:HASKEY("ORIGIN").
    IF stamped {
        SET stamped TO prior["MISSION"] = stateGet("mission_id","")
            AND prior["LAUNCH"] = stateGetNum("launch_time",0) AND prior["TARGET"] = targetBody:NAME
            AND prior["DEPARTURE"] = stateGetNum("burn_departure_time",-1)
            AND prior["ORIGIN"] = SHIP:BODY:NAME.
    }
    IF NOT stamped {
        LOCAL report IS stateGet("last_burn_report","").
        IF NOT (report:CONTAINS("phase=XING ") AND report:CONTAINS("body="+SHIP:BODY:NAME+" ")
                AND report:CONTAINS("shutdownAttempted=False") AND report:CONTAINS("thrustStopped=True")) { RETURN FALSE. }
        IF maneuverBurnInterrupted() {
            LOCAL residual IS stateGetNum("burn_abort_residual",-1).
            LOCAL planned IS stateGetNum("burn_dv",-1).
            IF stateGet("burn_abort_reason","") <> "residual-outside-tolerance"
                    OR stateGet("burn_body","") <> SHIP:BODY:NAME OR NOT HASNODE
                    OR ABS(NEXTNODE:TIME-stateGetNum("burn_node_time",-1)) >= 0.5
                    OR NOT (stateGetNum("burn_abort_time",-1) >= stateGetNum("burn_departure_time",-1)
                        AND stateGetNum("burn_abort_time",-1) <= TIME:SECONDS)
                    OR NOT (planned > 0 AND planned < 1e30
                        AND residual >= 0 AND residual <= MIN(0.3,planned*0.01))
                    OR NOT report:CONTAINS("cutoffFault=residual-outside-tolerance")
                    OR NOT (report:CONTAINS("reason=live-node-trim")
                        OR report:CONTAINS("reason=live-thrust-axis-trim")
                        OR report:CONTAINS("reason=live-vector-passed-target")) { RETURN FALSE. }
        } ELSE IF HASNODE OR NOT report:CONTAINS("cutoffFault= shutdownAttempted=False") { RETURN FALSE. }
        IF NOT thrustCutoffOk() { RETURN FALSE. }
        // Persist intent before clearing the interrupted-node markers. A
        // reboot between cleanup and phase advance cannot repeat departure.
        stateSet("xing_impact_handoff",LEXICON("MISSION",stateGet("mission_id",""),
            "LAUNCH",stateGetNum("launch_time",0),"TARGET",targetBody:NAME,
            "ORIGIN",SHIP:BODY:NAME,"DEPARTURE",stateGetNum("burn_departure_time",-1))).
    } ELSE IF HASNODE AND (NOT maneuverBurnInterrupted()
            OR ABS(NEXTNODE:TIME-stateGetNum("burn_node_time",-1)) >= 0.5) { RETURN FALSE. }
    _recordXingArrivalUt(targetBody).
    maneuverAcceptHandoff("arrival-correction-required").
    mLogSummary("STATS transfer handoff decision=correction-required target="+targetBody:NAME
        +" PeKm="+(pe/1000)+" entryUt="+hit["entryUt"]+" automaticStaging=False").
    RETURN TRUE.
}

LOCAL FUNCTION _advanceTransfer {
    PARAMETER targetBody.
    LOCAL patch IS _getTargetPatch(SHIP,targetBody).
    LOCAL impact IS patch <> 0 AND patch:PERIAPSIS <= 0.
    IF impact AND NOT _transferImpactHandoff(targetBody) {
        _holdInterruptedTransfer(). RETURN.
    }
    _recordXingArrivalUt(targetBody).
    IF impact {
        LOCAL entryUt IS stateGetNum("xing_arrival_ut",0).
        ensureSoiAlarm(targetBody,entryUt,"Impact encounter: BPLANE correction still required.").
        LOCAL alarm IS kacEnsureAlarm("Correct impact: "+targetBody:NAME,
            entryUt-TRANSFER_IMPACT_MIN_LEAD,"Manual stage review: REBOOT into BPLANE before this deadline.",1).
        stateSet("xing_impact_review_alarm",alarm).
    }
    nextPhase(xferSeq).
    IF impact {
        PRINT "IMPACT ENCOUNTER RETAINED. BPLANE correction is required before arrival.".
        PRINT "Optional: manually stage now with throttle off. No automatic separation.".
        PRINT "Then REBOOT. to plan from the current orbit and current propulsion.".
        PRINT "Do not resume or repeat the old XING node.".
        yieldToPrompt().
    }
}

LOCAL FUNCTION _holdInterruptedTransfer {
    IF NOT maneuverDepartureFlown() { RETURN FALSE. }
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    mLogError("Flown transfer needs recovery. Preserving any remaining node; no fresh departure plan.").
    PRINT "  TRANSFER HOLD: inspect staging and the remaining maneuver.".
    PRINT "  Burn reason: " + stateGet("burn_abort_reason", "departure interrupted or saved before phase handoff").
    PRINT "  Inspect the actual encounter before resuming. Do not re-burn an overshot node.".
    PRINT "  resumeburn.ks continues an unfinished burn; arrival correction repairs a flown departure.".
    yieldToPrompt().
    RETURN TRUE.
}

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
    IF patch <> 0 AND patch:PERIAPSIS <= 0 {
        IF _transferImpactHandoff(targetBody) { RETURN TRUE. }
        mLogSummary("STATS transfer handoff label="+label+" decision=hold status=impact-recovery-not-ready"
            +" target="+targetBody:NAME+" PeKm="+(patch:PERIAPSIS/1000)).
        RETURN FALSE.
    }
    IF patch <> 0 AND patch:PERIAPSIS > 0 AND patch:PERIAPSIS <= peMax {
        _recordXingArrivalUt(targetBody).
        maneuverAcceptHandoff().
        mLogSummary("STATS transfer handoff label=" + label
            + " decision=continue status=patch"
            + " target=" + targetBody:NAME
            + " PeKm=" + ROUND(patch:PERIAPSIS / 1000, 1)
            + " soiKm=" + ROUND(targetBody:SOIRADIUS / 1000, 1)
            + " body=" + SHIP:BODY:NAME
            + " ecc=" + ROUND(SHIP:ORBIT:ECCENTRICITY, 4)).
        RETURN TRUE.
    }

    IF SHIP:STATUS <> "ESCAPING" AND SHIP:ORBIT:ECCENTRICITY < 1 {
        mLogSummary("STATS transfer handoff label="+label+" decision=hold status=no-usable-target-patch"
            +" target="+targetBody:NAME+" hasPatch="+(patch <> 0)
            +" PeKm="+(SHIP:PERIAPSIS/1000)+" ApKm="+(SHIP:APOAPSIS/1000)).
        RETURN FALSE.
    }

    LOCAL arriveUt IS _handoffArrivalEstimate(targetBody).
    LOCAL pad IS MAX(21600, (arriveUt - TIME:SECONDS) * 0.25).
    LOCAL ca IS _findClosestApproach(
        targetBody, arriveUt - pad, arriveUt + pad, 48).
    IF ca["distance"] <= peMax {
        stateSet("xing_arrival_ut", ca["time"]).
        stateSet("xing_arrival_target", targetBody:NAME).
        maneuverAcceptHandoff().
        mLogSummary("STATS transfer handoff label=" + label
            + " decision=continue status=closest-approach"
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

    IF (NOT HASNODE OR maneuverDepartureFlown())
            AND _postBurnTransferHandoffOk(target, "phase-entry") {
        orbitSummary().
        _advanceTransfer(target).
        RETURN.
    }
    IF maneuverDepartureFlown() AND NOT BURN_RESUME_REQUESTED {
        _holdInterruptedTransfer().
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
        IF NOT maneuverBurnInterrupted() AND NOT maneuverDepartureFlown() {
            IF NOT transferDepartureReady(existing, target, CAPTURE_PE) {
                mLogError("Existing node is not a validated departure. It may be a parking/circularization remainder; inspect it, delete only if stale, then REBOOT to plan the transfer.").
                yieldToPrompt().
                RETURN.
            }
        }
        SET success TO executeManeuver().
        IF success {
            _recordXingArrivalUt(target).
            orbitSummary().
            _advanceTransfer(target).
            RETURN.
        }
        IF _postBurnTransferHandoffOk(target, "existing-node-failed") {
            orbitSummary().
            _advanceTransfer(target).
            RETURN.
        }
        IF _holdInterruptedTransfer() { RETURN. }
        mLogWarn("Existing transfer node was not usable; replanning.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    } ELSE IF stateGet("burn_pending", "false") = "true" {
        IF _postBurnTransferHandoffOk(target, "missing-node-pending") {
            orbitSummary().
            _advanceTransfer(target).
            RETURN.
        }
        IF _holdInterruptedTransfer() { RETURN. }
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
                    _advanceTransfer(target).
                    RETURN.
                }
                IF _holdInterruptedTransfer() { RETURN. }
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
    _advanceTransfer(target).
}

GLOBAL FUNCTION phaseXing {
    phaseTransfer().
}
