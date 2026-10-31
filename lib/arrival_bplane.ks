// ============================================================
// arrival_bplane.ks  —  B-plane arrival targeting
// (0:/lib/arrival_bplane.ks)
//
// Mid-coast correction that steers the arrival hyperbola at the
// target body to a requested plane (INC, LAN) and periapsis (PE)
// using B-plane coordinates — the standard technique for real
// interplanetary navigation.
//
// Why B-plane instead of iterating on patch elements directly:
// patch INC/LAN/PE jump discontinuously as the encounter geometry
// shifts, which is what made the old 4-axis coordinate-descent
// solver stall. The B-vector (the aim point in the plane
// perpendicular to the incoming asymptote) is a SMOOTH, nearly
// LINEAR function of small correction burns. Solve its two residuals
// with a minimum-length step across all three maneuver axes.
//
// Geometry used (all derived per-iteration from the live patch):
//   v∞² = -mu/a                 (hyperbolic excess speed)
//   S   = incoming asymptote direction
//   B   = aim vector, |B| = b = h/v∞ (hyperbola semi-minor axis)
//   T   = unit(S x north), R = unit(S x T)   (B-plane axes)
// Target B is built from the requested plane normal n_t:
//   the final orbit plane must CONTAIN S, so n_t is projected
//   perpendicular to S first (logged when the requested plane is
//   infeasible for this arrival — fix it by departing on a
//   different window, or accept the closest achievable plane).
//   B_t = b_t * unit(n_t x S),  b_t from the requested PE.
//
// Robustness notes:
//   - State vectors come from the selected native patch at current UT,
//     checked against its energy, angular momentum and eccentricity.
//   - The eccentricity vector uses the cross-product-free form
//     e = ((v·v - mu/r) r - (r·v) v) / mu, immune to handedness.
//   - The B-plane handedness is calibrated against the measured
//     patch itself, not assumed from KSP coordinate conventions.
//
// Phase: BPLANE  (PHASE BPLANE = arrival_bplane)
//
// Global config keys:
//   CAPTURE_PE   — required: target periapsis altitude (m)
//   CAPTURE_INC  — optional: target inclination (deg)
//   CAPTURE_LAN  — optional: target LAN (deg)
//   BPLANE_TARGET  — optional body name (default: state "target")
//   BPLANE_DV_CAP  — max correction dV in m/s (default 150)
//   BPLANE_PE_TOL  — PE tolerance in m (default 2000)
//   BPLANE_EARLY_PE_TOL — coarse airless Pe tolerance before midcourse (10000 m)
//   BPLANE_ANG_TOL — plane tolerance in deg (default 0.5)
//   BPLANE_LEAD    — seconds from now to the burn (default 300)
//   BPLANE_EXISTING_NODE_MIN_ETA — min ETA to reuse a B-plane node
//   BPLANE_OFFPLANE_TOL — max feasible plane/asymptote tilt (default 10)
//   BPLANE_SAFE_HANDOFF_SOI_MULT — Pe/SOI accepted on no-correction handoff
//   REFINE_BPLANE_DV_CAP    — max dV per refinement burn (default 10)
//   REFINE_BPLANE_MAX_BURNS — max refinement burns per phase call (default 6)
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL CAPTURE_PE IS -1.
GLOBAL CAPTURE_INC IS -1.
GLOBAL CAPTURE_LAN IS -1.
GLOBAL CAPTURE_AOP IS -1.
GLOBAL CAPTURE_DIR IS "".
GLOBAL BPLANE_DV_CAP IS 150.
GLOBAL BPLANE_PE_TOL IS 2000.
// Coarse Pe allowance before a scheduled midcourse refinement. Fine Pe
// targeting still uses BPLANE_PE_TOL at REFINE_BPLANE. Zero disables deferral.
GLOBAL BPLANE_EARLY_PE_TOL IS 10000.
GLOBAL BPLANE_ANG_TOL IS 0.2.
GLOBAL BPLANE_EXISTING_NODE_MIN_ETA IS 30.
GLOBAL BPLANE_TARGET IS "".
GLOBAL BPLANE_OFFPLANE_TOL IS 10.
GLOBAL BPLANE_SAFE_HANDOFF_SOI_MULT IS 1.0.
GLOBAL REFINE_BPLANE_DV_CAP IS 10.
GLOBAL REFINE_BPLANE_MAX_BURNS IS 6.
// Optional-correction limits for an EXISTING encounter. A genuinely
// missing patch still uses the recovery cap. Negative = disabled.
GLOBAL BPLANE_TRIM_DV_CAP IS -1.
GLOBAL BPLANE_TRIM_TOTAL_DV_CAP IS -1.
GLOBAL BPLANE_TRIM_RESERVE_DV IS -1.
GLOBAL BPLANE_MAX_ARRIVAL_SHIFT IS -1.
GLOBAL BPLANE_MAX_CAPTURE_DV_INCREASE IS -1.
GLOBAL TARGET_AP IS -1.
// Opt-in capture recovery: solve only Pe, preserving fuel for capture.
GLOBAL BPLANE_PE_ONLY IS 0.
GLOBAL BPLANE_CAPTURE_MARGIN IS -1.
// Contract missions must not silently waive their requested plane.
GLOBAL BPLANE_REQUIRE_PLANE IS 0.
GLOBAL BPLANE_REVIEW_UNCONVERGED IS 0.
GLOBAL BPLANE_REVIEW_MIN_PE IS 10000.
// One final refinement after the normal midpoint, with time to align/burn.
GLOBAL BPLANE_FINAL_REFINE_LEAD IS 900.
// Optional no-burn Pe corridor for a converged sub-minimum correction.
// Profiles may use a coarser capture corridor than the solver's aim point;
// required plane and capture/return fuel constraints still apply.
GLOBAL BPLANE_MINIMUM_PE_TOL IS -1.


LOCAL DEFAULT_DV_CAP   IS 150.
LOCAL DEFAULT_PE_TOL   IS 2000.
LOCAL DEFAULT_ANG_TOL  IS 0.5.
LOCAL DEFAULT_LEAD     IS 300.
LOCAL MIN_EXEC_DV      IS 0.3.
LOCAL _bplaneMinimumSkip IS LEXICON("ACCEPTED",FALSE).
LOCAL MAX_NEWTON_ITER  IS 16.
LOCAL NEWTON_DAMP      IS 0.7.
LOCAL FD_STEP          IS 0.05.
LOCAL ACQUIRE_INITIAL_STEP IS 2.0.
LOCAL ACQUIRE_MIN_STEP     IS 0.05.
LOCAL ACQUIRE_STEP_GROWTH  IS 1.2.
LOCAL MAX_ACQUIRE_ITER     IS 150.
LOCAL MAX_BURNS        IS 2.

LOCAL FUNCTION _bplaneCorrectionAboveMinimum {
    PARAMETER nd.
    LOCAL correctionDv IS nd:DELTAV:MAG.
    IF correctionDv > MIN_EXEC_DV { RETURN TRUE. }
    mLog("STATS bplane decision=skip reason=below-execution-minimum dv="
        + ROUND(correctionDv, 4) + " minimumDv=" + MIN_EXEC_DV).
    RETURN FALSE.
}

LOCAL FUNCTION _bplaneMinimumArrivalOk {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    IF ABORT OR maneuverBurnInterrupted() OR HASNODE { RETURN FALSE. }
    LOCAL hit IS _bplaneCoastEncounter(targetBody).
    IF hit = 0 { RETURN FALSE. }
    LOCAL patch IS hit["patch"].
    LOCAL pe IS patch:PERIAPSIS.
    LOCAL tolerance IS BPLANE_PE_TOL.
    IF BPLANE_MINIMUM_PE_TOL >= 0 { SET tolerance TO BPLANE_MINIMUM_PE_TOL. }
    IF NOT (pe > 0 AND ABS(pe-wantPe) <= tolerance
            AND pe < targetBody:SOIRADIUS-targetBody:RADIUS) { RETURN FALSE. }
    LOCAL planeErr IS _bplaneElementPlaneError(patch:INCLINATION,patch:LAN,wantInc,wantLan).
    IF NOT (planeErr >= 0 AND planeErr < 1e30) { RETURN FALSE. }
    IF BPLANE_REQUIRE_PLANE <> 0 AND planeErr > BPLANE_ANG_TOL { RETURN FALSE. }
    LOCAL reserve IS MAX(0,MAX(BPLANE_CAPTURE_MARGIN,BPLANE_TRIM_RESERVE_DV)).
    IF NOT arrivalGoalPolicyOk(hit,targetBody,wantPe) { RETURN FALSE. }
    LOCAL needed IS arrivalRequiredCaptureDv(patch,targetBody)+reserve.
    IF NOT (needed >= 0 AND needed <= SHIP:DELTAV:VACUUM) { RETURN FALSE. }
    mLog("STATS bplane minimum-handoff PeKm=" + ROUND(pe/1000,3)
        + " peTolerance=" + tolerance + " planeErr=" + ROUND(planeErr,3)
        + " neededDv=" + ROUND(needed,1) + " noBurn=True").
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneFinishMinimumSkip {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    IF NOT _bplaneMinimumSkip["ACCEPTED"] { RETURN FALSE. }
    SET _bplaneMinimumSkip["ACCEPTED"] TO FALSE.
    // Recheck the unburned native patch, never the removed node's patch.
    IF NOT _bplaneMinimumArrivalOk(targetBody,wantPe,wantInc,wantLan) {
        _bplaneHoldCorrection("minimum-skip-arrival-changed",TRUE). RETURN TRUE.
    }
    bplaneClearRetryWait().
    _bplaneEnsureSoiAlarm(targetBody).
    mLog("STATS bplane result status=below-minimum-safe-handoff").
    nextPhase(xferSeq).
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneDeferPeToMidcourse {
    PARAMETER targetBody.
    PARAMETER wantPe.
    IF BPLANE_PE_ONLY = 0 OR BPLANE_REQUIRE_PLANE <> 0
            OR BPLANE_EARLY_PE_TOL <= 0 OR ABORT { RETURN FALSE. }
    // Only an immediate, known coast/refinement pair can inherit this job.
    // Recovery profiles without that pair must solve now or hold normally.
    IF NOT _bplaneHasMidcourseRefinement() { RETURN FALSE. }
    IF targetBody:ATM:EXISTS { RETURN FALSE. }
    IF NOT SHIP:ORBIT:HASNEXTPATCH { RETURN FALSE. }
    IF SHIP:ORBIT:NEXTPATCH:BODY <> targetBody { RETURN FALSE. }
    LOCAL hit IS findArrivalPatch(0, targetBody).
    IF hit = 0 { RETURN FALSE. }
    LOCAL peNow IS hit["patch"]:PERIAPSIS.
    IF peNow <> peNow OR ABS(peNow) >= 1e30 { RETURN FALSE. }
    IF peNow < MAX(0, BPLANE_REVIEW_MIN_PE)
            OR peNow >= targetBody:SOIRADIUS - targetBody:RADIUS
            OR ABS(peNow - wantPe) > MAX(BPLANE_PE_TOL, BPLANE_EARLY_PE_TOL) {
        RETURN FALSE.
    }
    // Leave time for the guarded coast checkpoint, solving, alignment and
    // its future node. Never defer to/through the SOI transition itself.
    IF hit["entryUt"] - TIME:SECONDS <= 3 * MAX(1, BPLANE_LEAD) { RETURN FALSE. }
    LOCAL laterCap IS _bplaneTrimCap(targetBody, REFINE_BPLANE_DV_CAP).
    IF laterCap <= MIN_EXEC_DV { RETURN FALSE. }
    LOCAL needed IS arrivalRequiredCaptureDv(hit["patch"], targetBody)
        + MAX(0, BPLANE_CAPTURE_MARGIN) + laterCap.
    IF needed > SHIP:DELTAV:VACUUM { RETURN FALSE. }
    mLog("STATS bplane decision=defer-pe-to-midcourse PeKm=" + ROUND(peNow / 1000, 3)
        + " targetPeKm=" + (wantPe / 1000)
        + " earlyToleranceKm=" + (BPLANE_EARLY_PE_TOL / 1000)
        + " refineToleranceKm=" + (BPLANE_PE_TOL / 1000)
        + " soiEta=" + ROUND(hit["entryUt"] - TIME:SECONDS, 1)
        + " laterCap=" + ROUND(laterCap, 3) + " neededDv=" + ROUND(needed, 1)).
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneTrimSpent {
    PARAMETER targetBody.
    LOCAL id IS targetBody:NAME + ":" + stateGetNum("launch_time", 0).
    IF stateGet("bplane_budget_id", "") <> id {
        stateSet("bplane_budget_id", id).
        stateSet("bplane_budget_spent", 0).
    }
    LOCAL spent IS stateGetNum("bplane_budget_spent", 0).
    LOCAL reserved IS stateGet("bplane_budget_reservation",LEXICON()).
    IF reserved:HASKEY("ID") AND reserved["ID"] = id AND reserved["TOTAL"] > spent {
        // Complete a reservation whose second write was interrupted.
        SET spent TO reserved["TOTAL"].
        stateSet("bplane_budget_spent",spent).
    }
    RETURN spent.
}

LOCAL FUNCTION _bplaneTrimCap {
    PARAMETER targetBody, phaseCap.
    PARAMETER reservedCredit IS 0.
    IF findArrivalPatch(0, targetBody) = 0 { RETURN phaseCap. }
    LOCAL cap IS phaseCap.
    IF BPLANE_TRIM_DV_CAP >= 0 { SET cap TO MIN(cap, BPLANE_TRIM_DV_CAP). }
    IF BPLANE_TRIM_TOTAL_DV_CAP >= 0 {
        SET cap TO MIN(cap, BPLANE_TRIM_TOTAL_DV_CAP - _bplaneTrimSpent(targetBody) + MAX(0,reservedCredit)).
    }
    IF BPLANE_TRIM_RESERVE_DV >= 0 {
        // Stock vacuum dV is an estimate; zero leaves no optional budget.
        SET cap TO MIN(cap, SHIP:DELTAV:VACUUM - BPLANE_TRIM_RESERVE_DV).
    }
    RETURN MAX(0, cap).
}

LOCAL FUNCTION _bplaneHoldCorrection {
    PARAMETER reason.
    PARAMETER missionOwned IS FALSE.
    stateRemove("bplane_review").
    // A failed execution owns its retained node until explicit replan.
    IF NOT maneuverBurnInterrupted() {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    }
    mLogWarn("STATS bplane decision=hold reason=" + reason
        + " remainingVacDv=" + ROUND(SHIP:DELTAV:VACUUM, 1)
        + " reserveDv=" + BPLANE_TRIM_RESERVE_DV).
    IF missionOwned AND NOT maneuverBurnInterrupted() {
        _bplaneBlockedToPrompt(reason).
        RETURN.
    }
    IF maneuverBurnInterrupted() {
        mLogWarn("Correction execution stopped; achieved trajectory and interrupted node retained. "
            + "Review the actual encounter; use arrival replan to discard the residual deliberately.").
    } ELSE {
        mLogWarn("Arrival correction rejected; original trajectory retained. "
            + "Review the encounter and remaining mission before resuming.").
    }
    _bplaneScheduleHoldReview(reason).
    yieldToPrompt().
}

LOCAL FUNCTION _bplaneBlockedToPrompt {
    PARAMETER reason.
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    mLogError("STATS bplane blocked reason=" + reason
        + " automaticResume=False resident=False ut=" + TIME:SECONDS).
    PRINT "ARRIVAL BLOCKED: " + reason + "; returning to manual control at 1x.".
    yieldToPrompt().
}

LOCAL FUNCTION _bplaneHasMidcourseRefinement {
    LOCAL phaseIndex IS 0.
    UNTIL phaseIndex >= xferSeq:LENGTH {
        IF xferSeq[phaseIndex] = "BPLANE" { BREAK. }
        SET phaseIndex TO phaseIndex + 1.
    }
    IF phaseIndex + 2 >= xferSeq:LENGTH { RETURN FALSE. }
    RETURN xferSeq[phaseIndex + 1] = "COAST_1HALF"
        AND xferSeq[phaseIndex + 2] = "REFINE_BPLANE".
}

LOCAL FUNCTION _bplaneRetryEncounter {
    PARAMETER targetBody.
    IF ABORT OR maneuverBurnInterrupted() OR HASNODE
            OR stateGet("phase", "") <> "BPLANE"
            OR NOT _bplaneHasMidcourseRefinement() { RETURN 0. }
    LOCAL hit IS _bplaneCoastEncounter(targetBody).
    IF hit = 0 { RETURN 0. }
    IF hit["entryUt"]-TIME:SECONDS <= 3*MAX(1,BPLANE_LEAD) { RETURN 0. }
    RETURN hit.
}

LOCAL FUNCTION _bplaneCoastEncounter {
    PARAMETER targetBody.
    IF SHIP:BODY = targetBody { RETURN 0. }
    IF NOT SHIP:ORBIT:HASNEXTPATCH { RETURN 0. }
    IF SHIP:ORBIT:NEXTPATCH:BODY <> targetBody { RETURN 0. }
    LOCAL hit IS findArrivalPatch(0, targetBody).
    IF hit = 0 { RETURN 0. }
    LOCAL pe IS hit["patch"]:PERIAPSIS.
    // This coast ends BEFORE SOI entry, not at target periapsis. The review
    // Pe floor is a burn/arrival gate, not a reason to lose the timed retry.
    IF NOT (pe > -targetBody:RADIUS AND ABS(pe) < 1e30
            AND pe < targetBody:SOIRADIUS - targetBody:RADIUS
            AND hit["entryUt"] < 1e30
            AND hit["entryUt"] > TIME:SECONDS) { RETURN 0. }
    IF NOT _bplaneParentClearUntil(hit["entryUt"]) { RETURN 0. }
    IF NOT arrivalCoastPolicyOk(hit,targetBody,CAPTURE_PE) { RETURN 0. }
    RETURN hit.
}

LOCAL FUNCTION _bplaneParentClearUntil {
    PARAMETER entryUt.
    IF NOT (entryUt > TIME:SECONDS AND entryUt < 1e30) { RETURN FALSE. }
    LOCAL clearance IS 0.
    IF SHIP:BODY:ATM:EXISTS { SET clearance TO SHIP:BODY:ATM:HEIGHT. }
    LOCAL pe IS SHIP:PERIAPSIS.
    IF NOT (ABS(pe) < 1e30) { RETURN FALSE. }
    IF pe > clearance { RETURN TRUE. }
    // A future moon encounter can truncate an ellipse whose hypothetical
    // parent Pe is inside the atmosphere. Prove entry precedes that hazard.
    IF NOT SHIP:BODY:ATM:EXISTS { RETURN FALSE. }
    IF NOT (SHIP:ALTITUDE > clearance AND SHIP:ALTITUDE < 1e30) { RETURN FALSE. }
    LOCAL sma IS SHIP:ORBIT:SEMIMAJORAXIS.
    LOCAL ecc IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL peEta IS ETA:PERIAPSIS.
    IF NOT (sma > 0 AND sma < 1e30 AND ecc > 0 AND ecc < 1
            AND mu > 0 AND mu < 1e30 AND peEta > 0 AND peEta < 1e30) { RETURN FALSE. }
    LOCAL cosE IS (1-(SHIP:BODY:RADIUS+clearance)/sma)/ecc.
    IF NOT (cosE >= -1 AND cosE <= 1) { RETURN FALSE. }
    LOCAL eccentricAngle IS ARCCOS(cosE).
    LOCAL meanAngle IS eccentricAngle*CONSTANT:PI/180-ecc*SIN(eccentricAngle).
    LOCAL hazardEta IS peEta-meanAngle*SQRT(sma^3/mu).
    LOCAL encounterEta IS entryUt-TIME:SECONDS.
    LOCAL clear IS encounterEta+SOI_BUFFER_TIME < hazardEta.
    mLog("STATS bplane parent-coast PeKm=" + (pe/1000)
        + " encounterEta=" + encounterEta + " atmosphereEta=" + hazardEta
        + " buffer=" + SOI_BUFFER_TIME + " clear=" + clear).
    RETURN clear.
}

// Minimum-length Newton step for two B-plane residuals using all burn axes.
// J'*(J*J')^-1 uses prograde authority too; no axis sign/frame is assumed.
LOCAL FUNCTION _bplaneNewtonStep {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    PARAMETER qT.
    PARAMETER qR.
    LOCAL pro IS nd:PROGRADE.
    LOCAL rad IS nd:RADIALOUT.
    LOCAL normalDv IS nd:NORMAL.
    LOCAL rowT IS LIST().
    LOCAL rowR IS LIST().
    FOR axis IN LIST("PROGRADE","RADIALOUT","NORMAL") {
        LOCAL slopeT IS 0.
        LOCAL slopeR IS 0.
        FOR probe IN LIST(FD_STEP,-FD_STEP) {
            _bplaneNodeAxisSet(nd,axis,_bplaneNodeAxisGet(nd,axis)+probe).
            WAIT 0.02.
            LOCAL sample IS measureArrival(nd,targetBody).
            IF sample <> 0 {
                LOCAL desired IS targetBplaneVector(targetBody,sample,wantPe,wantInc,wantLan,TRUE).
                SET slopeT TO ((sample["bt"]-desired["bt"])-qT)/probe.
                SET slopeR TO ((sample["br"]-desired["br"])-qR)/probe.
            }
            SET nd:PROGRADE TO pro.
            SET nd:RADIALOUT TO rad.
            SET nd:NORMAL TO normalDv.
            WAIT 0.02.
            IF sample <> 0 { BREAK. }
        }
        rowT:ADD(slopeT).
        rowR:ADD(slopeR).
    }
    LOCAL gramTT IS rowT[0]^2+rowT[1]^2+rowT[2]^2.
    LOCAL gramRR IS rowR[0]^2+rowR[1]^2+rowR[2]^2.
    LOCAL gramTR IS rowT[0]*rowR[0]+rowT[1]*rowR[1]+rowT[2]*rowR[2].
    LOCAL det IS gramTT*gramRR-gramTR^2.
    IF NOT (det > 0.000000000001*gramTT*gramRR) { RETURN LIST(). }
    LOCAL dualT IS (-gramRR*qT+gramTR*qR)/det.
    LOCAL dualR IS (gramTR*qT-gramTT*qR)/det.
    RETURN LIST(NEWTON_DAMP*(rowT[0]*dualT+rowR[0]*dualR),
        NEWTON_DAMP*(rowT[1]*dualT+rowR[1]*dualR),
        NEWTON_DAMP*(rowT[2]*dualT+rowR[2]*dualR)).
}

LOCAL FUNCTION _bplaneQueueMidcourseRetry {
    PARAMETER reason.
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 { RETURN FALSE. }
    LOCAL hit IS _bplaneRetryEncounter(targetBody).
    IF hit = 0 { RETURN FALSE. }
    LOCAL wakeUt IS midcourseRefineUt(TIME:SECONDS, hit["entryUt"]).
    midcourseClearReviewAlarm().
    stateSet("bplane_midcourse_retry", LEX("mission",stateGet("mission_id",""),
        "launch",stateGetNum("launch_time",0),"target",targetBody:NAME,"wakeUt",wakeUt)).
    mLog("STATS bplane decision=defer reason=" + reason + " wakeUt=" + wakeUt
        + " eta=" + (wakeUt-TIME:SECONDS) + " automaticResume=True").
    mLog("Rejected correction removed; handing off to automatic midcourse refinement.").
    RETURN TRUE.
}

GLOBAL FUNCTION bplaneClearRetryWait {
    PARAMETER keepCheckpoint IS FALSE.
    LOCAL pending IS stateGet("bplane_retry_wait",LEXICON()).
    IF pending:LENGTH > 0 AND ADDONS:KAC:AVAILABLE {
        IF pending["alarm"] <> "" { DELETEALARM(pending["alarm"]). }
    }
    IF keepCheckpoint AND pending:LENGTH > 0 {
        // stateGet returns the cache object. Consume the checkpoint on disk
        // before a reboot can observe it as still waiting.
        SET pending TO pending:COPY.
        SET pending["waiting"] TO FALSE.
        SET pending["alarm"] TO "".
        stateSet("bplane_retry_wait",pending).
    } ELSE {
        stateRemove("bplane_retry_wait").
    }
}

LOCAL FUNCTION _bplaneRetryWaitPending {
    PARAMETER targetBody.
    PARAMETER waitingOnly IS TRUE.
    LOCAL pending IS stateGet("bplane_retry_wait",LEXICON()).
    IF pending:LENGTH = 0 { RETURN FALSE. }
    IF pending["mission"] = stateGet("mission_id","")
            AND pending["launch"] = stateGetNum("launch_time",0)
            AND pending["phase"] = stateGet("phase","")
            AND pending["target"] = targetBody:NAME {
        RETURN NOT waitingOnly OR pending["waiting"].
    }
    bplaneClearRetryWait().
    RETURN FALSE.
}

LOCAL FUNCTION _bplaneWaitBeforeSolverRetry {
    PARAMETER targetBody.
    PARAMETER retryReason IS "unconverged-optional-correction".
    PARAMETER solutionDv IS -1.
    PARAMETER retryCap IS -1.
    IF ABORT { RETURN FALSE. }
    _bplaneEnsureSoiAlarm(targetBody).
    LOCAL hit IS _bplaneCoastEncounter(targetBody).
    LOCAL latestUt IS 0.
    LOCAL wakeUt IS 0.
    LOCAL checkpoint IS "final".
    LOCAL finalOnly IS FALSE.
    IF _bplaneRetryWaitPending(targetBody,FALSE) {
        LOCAL previous IS stateGet("bplane_retry_wait",LEXICON()).
        IF previous:HASKEY("checkpoint") {
            IF previous["waiting"] {
                SET finalOnly TO previous["checkpoint"] = "final".
            } ELSE {
                SET finalOnly TO previous["checkpoint"] = "approach".
            }
        }
    }
    IF hit <> 0 {
        LOCAL phaseCap IS BPLANE_DV_CAP.
        IF stateGet("phase","") = "REFINE_BPLANE" { SET phaseCap TO REFINE_BPLANE_DV_CAP. }
        IF retryCap >= 0 { SET phaseCap TO retryCap. }
        LOCAL timing IS arrivalRetryTiming(hit,_bplaneTrimCap(targetBody,phaseCap),
            MIN_EXEC_DV,solutionDv,finalOnly).
        IF timing["OK"] {
            SET latestUt TO timing["LATEST"]. SET wakeUt TO timing["WAKE"].
            SET checkpoint TO timing["CHECKPOINT"].
            mLog("STATS bplane retry-timing checkpoint=" + checkpoint + " wakeUt=" + wakeUt
                + " latestUt=" + latestUt + " peUt=" + timing["PE_UT"]
                + " burnSeconds=" + timing["BURN_SECONDS"] + " solutionDv=" + solutionDv
                + " arrivalMode=" + BPLANE_ARRIVAL_MODE).
        }
    }
    IF _bplaneRetryWaitPending(targetBody,FALSE) AND hit <> 0 {
        // Resume the existing checkpoint, clipped to current native safety.
        LOCAL pending IS stateGet("bplane_retry_wait",LEXICON()).
        IF pending["waiting"] {
            SET wakeUt TO MIN(pending["wakeUt"],wakeUt).
            IF wakeUt <= TIME:SECONDS AND TIME:SECONDS <= latestUt {
                bplaneClearRetryWait(TRUE).
                mLog("STATS bplane retry-resume target=" + targetBody:NAME
                    + " wakeUt=" + wakeUt + " ut=" + TIME:SECONDS
                    + " latestUt=" + latestUt + " solvingNow=True").
                RETURN TRUE.
            }
        } ELSE IF NOT finalOnly {
            // Legacy records and final checkpoints remain single-use.
            SET wakeUt TO 0.
        }
    }
    IF wakeUt > TIME:SECONDS AND wakeUt < 1e30 {
        midcourseClearReviewAlarm().
        LOCAL alarmId IS kacEnsureAlarm("B-plane retry: " + targetBody:NAME,wakeUt,
            "Running mission retries arrival correction; no rejected burn is flown.").
        stateSet("bplane_retry_wait",LEX("mission",stateGet("mission_id",""),
            "launch",stateGetNum("launch_time",0),"phase",stateGet("phase",""),
            "target",targetBody:NAME,"wakeUt",wakeUt,"alarm",alarmId,"waiting",TRUE,
            "checkpoint",checkpoint)).
        mLogWarn("STATS bplane retry-wake target=" + targetBody:NAME
            + " wakeUt=" + wakeUt + " eta=" + (wakeUt-TIME:SECONDS)
            + " latestUt=" + latestUt + " checkpoint=" + checkpoint + " automaticResume=True"
            + " after=" + retryReason).
        PRINT "ARRIVAL RETRY: running coast until UT " + ROUND(wakeUt,1) + ".".
        LOCAL solarRef IS enterSolarCoast("BPLANE retry",TRUE,TRUE,wakeUt).
        waitUntilOrSOI(targetBody,wakeUt,10,alarmId,solarRef).
        bplaneClearRetryWait(TIME:SECONDS >= wakeUt AND NOT ABORT).
        SET WARP TO 0.
        WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
        IF ABORT { RETURN FALSE. }
        IF SHIP:BODY <> targetBody AND TIME:SECONDS <= latestUt {
            mLog("STATS bplane retry-resume target=" + targetBody:NAME
                + " wakeUt=" + wakeUt + " ut=" + TIME:SECONDS
                + " latestUt=" + latestUt + " solvingNow=True").
            RETURN TRUE.
        }
    }
    LOCAL reason IS "no-safe-retry-time".
    IF hit <> 0 AND latestUt >= TIME:SECONDS {
        SET reason TO "final-refinement-checkpoint-used".
    }
    bplaneClearRetryWait(TRUE).
    // No further automatic retry is allowed. Return to manual control at
    // 1x with the rejected node removed; keep the saved phase for review.
    mLogError("STATS bplane retry-blocked reason=" + reason + " target="
        + targetBody:NAME + " latestUt=" + latestUt + " after=" + retryReason
        + " ut=" + TIME:SECONDS + " automaticResume=False resident=False").
    IF reason = "final-refinement-checkpoint-used" {
        PRINT "Final arrival correction attempt rejected: " + retryReason + ". No further automatic retry.".
    }
    _bplaneBlockedToPrompt(reason).
    RETURN FALSE.
}

LOCAL FUNCTION _bplaneHandoffMidcourseRetry {
    PARAMETER targetBody.
    LOCAL pending IS stateGet("bplane_midcourse_retry", LEXICON()).
    IF pending:LENGTH = 0 { RETURN FALSE. }
    IF pending["mission"] <> stateGet("mission_id", "")
            OR pending["launch"] <> stateGetNum("launch_time",0)
            OR pending["target"] <> targetBody:NAME {
        stateRemove("bplane_midcourse_retry"). RETURN FALSE.
    }
    IF _bplaneRetryEncounter(targetBody) = 0 {
        stateRemove("bplane_midcourse_retry"). RETURN FALSE.
    }
    // The existing coast owns the live wait, solar maintenance and KAC wake.
    // REFINE_BPLANE must still meet every required plane/fuel/corridor gate.
    nextPhase(xferSeq).
    IF stateGet("phase", "") = "BPLANE" { RETURN FALSE. }
    stateRemove("bplane_midcourse_retry").
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneScheduleHoldReview {
    PARAMETER reason.
    // This alarm requests operator review; it never approves a correction
    // or resumes the phase machine. Keep the required-plane/fuel gates.
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 { RETURN. }
    LOCAL hit IS findArrivalPatch(0, targetBody).
    IF hit = 0 {
        mLogWarn("BPLANE HOLD: no encounter timing; review NOW. No automatic refinement is running.").
        RETURN.
    }
    LOCAL arrivalUt IS hit["entryUt"].
    IF NOT (arrivalUt > TIME:SECONDS AND arrivalUt < 1e30) {
        mLogWarn("BPLANE HOLD: arrival timing due/invalid; review NOW. No automatic refinement is running.").
        RETURN.
    }
    LOCAL reviewUt IS midcourseRefineUt(TIME:SECONDS, arrivalUt).
    // An overdue checkpoint needs attention now, not a new half-transfer wait.
    SET reviewUt TO MIN(arrivalUt, MAX(TIME:SECONDS+1, reviewUt)).
    LOCAL alarmId IS kacEnsureAlarm("Arrival review: " + targetBody:NAME, reviewUt,
        "Mission HELD in " + stateGet("phase", "") + ": " + reason
        + ". Operator review required; this alarm does not resume refinement.").
    stateSet("arrival_review_alarm", alarmId).
    mLogWarn("STATS bplane hold-wake reviewUt=" + reviewUt
        + " eta=" + (reviewUt-TIME:SECONDS) + " arrivalUt=" + arrivalUt
        + " alarm=" + alarmId + " automaticResume=False").
    PRINT "ARRIVAL HELD: automatic midcourse refinement is paused; review in "
        + ROUND(reviewUt-TIME:SECONDS,0) + "s (UT " + ROUND(reviewUt,1) + ").".
    IF alarmId = "" { PRINT "No KAC alarm available; the review time above is informational only.". }
}

GLOBAL FUNCTION bplaneArrivalStatus {
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 { PRINT "No arrival target body.". RETURN. }
    LOCAL hit IS findArrivalPatch(0, targetBody).
    LOCAL phaseCap IS BPLANE_DV_CAP.
    IF stateGet("phase", "") = "REFINE_BPLANE" { SET phaseCap TO REFINE_BPLANE_DV_CAP. }
    mLogWarn("STATS bplane status correctionCap=" + _bplaneTrimCap(targetBody, phaseCap)
        + " phaseCap=" + phaseCap + " trimCap=" + BPLANE_TRIM_DV_CAP
        + " totalCap=" + BPLANE_TRIM_TOTAL_DV_CAP
        + " minimumDv=" + MIN_EXEC_DV + " earlyPeToleranceKm=" + (BPLANE_EARLY_PE_TOL / 1000)).
    mLogWarn("STATS bplane status phase=" + stateGet("phase", "")
        + " body=" + SHIP:BODY:NAME
        + " target=" + targetBody:NAME + " patch=" + (hit <> 0)
        + " remainingDv=" + ROUND(SHIP:DELTAV:VACUUM, 2)
        + " spentDv=" + stateGetNum("bplane_budget_spent", 0)
        + " interrupted=" + maneuverBurnInterrupted()
        + " burnReason=" + stateGet("burn_abort_reason", "none")).
    IF hit <> 0 {
        LOCAL captureDv IS bplaneCaptureCost(hit["patch"], targetBody).
        mLogWarn("STATS bplane status PeKm=" + ROUND(hit["patch"]:PERIAPSIS / 1000, 3)
            + " targetPeKm=" + (CAPTURE_PE / 1000)
            + " toleranceKm=" + (BPLANE_PE_TOL / 1000)
            + " captureDv=" + ROUND(captureDv, 2)
            + " afterCaptureDv=" + ROUND(SHIP:DELTAV:VACUUM - captureDv, 2)
            + " requiredReserve=" + BPLANE_CAPTURE_MARGIN).
    }
    IF HASNODE {
        mLogWarn("STATS bplane status nodeDv=" + ROUND(NEXTNODE:DELTAV:MAG, 4)
            + " nodeEta=" + ROUND(NEXTNODE:ETA, 1)).
    }
}

// Explicit operator allowance for further correction, preserving already
// reserved/spent dV and all capture/return/plane constraints.
GLOBAL FUNCTION bplaneRecoveryBudgetValues {
    PARAMETER allowance.
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 { RETURN LEXICON(). }
    RETURN LEX("BPLANE_DV_CAP", allowance, "REFINE_BPLANE_DV_CAP", allowance,
        "BPLANE_TRIM_DV_CAP", allowance,
        "BPLANE_TRIM_TOTAL_DV_CAP", _bplaneTrimSpent(targetBody) + allowance).
}

GLOBAL FUNCTION bplanePreviewCorrection {
    IF ABORT OR maneuverBurnInterrupted() {
        PRINT "ABORT or interrupted burn present; inspect status before planning.". RETURN.
    }
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 OR SHIP:BODY = targetBody {
        PRINT "Preview requires an approach from outside the target SOI.". RETURN.
    }
    stateRemove("bplane_review").
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL phaseCap IS BPLANE_DV_CAP.
    IF stateGet("phase", "") = "REFINE_BPLANE" { SET phaseCap TO REFINE_BPLANE_DV_CAP. }
    LOCAL nd IS planBplaneCorrection(targetBody, CAPTURE_PE,
        _bplaneWantInc(), CAPTURE_LAN, phaseCap).
    IF phaseShouldYield { RETURN. }
    IF nd = 0 {
        bplaneArrivalStatus().
        PRINT "No correction node produced. Mission phase unchanged.". RETURN.
    }
    _bplaneOfferReview(nd, targetBody, phaseCap).
}

LOCAL FUNCTION _bplaneExecuteCorrection {
    IF NOT _bplaneCorrectionAboveMinimum(NEXTNODE) { RETURN FALSE. }
    // For admitted Pe corrections, aim for 1% rather than lose a large
    // fraction to the ordinary absolute cutoff. This is execution accuracy,
    // not permission to bypass the shared minimum correction size.
    LOCAL oldAbs IS BURN_TRIM_ABS_COMPLETE_DV.
    LOCAL oldMax IS BURN_TRIM_COMPLETE_MAX_DV.
    IF BPLANE_PE_ONLY <> 0 {
        LOCAL precision IS MAX(BURN_BV_MIN_MAG, NEXTNODE:DELTAV:MAG * 0.01).
        SET BURN_TRIM_ABS_COMPLETE_DV TO MIN(oldAbs, precision).
        SET BURN_TRIM_COMPLETE_MAX_DV TO MIN(oldMax, precision).
    }
    LOCAL success IS executeManeuver().
    SET BURN_TRIM_ABS_COMPLETE_DV TO oldAbs.
    SET BURN_TRIM_COMPLETE_MAX_DV TO oldMax.
    RETURN success.
}

LOCAL FUNCTION _bplaneLogBaseline {
    PARAMETER targetBody, phaseCap.
    LOCAL hit IS findArrivalPatch(0, targetBody).
    IF hit = 0 {
        mLog("STATS bplane baseline target=" + targetBody:NAME + " patch=False").
        RETURN.
    }
    LOCAL patch IS hit["patch"].
    mLog("STATS bplane baseline target=" + targetBody:NAME
        + " phase=" + stateGet("phase", "")
        + " patch=True PeKm=" + ROUND(patch:PERIAPSIS / 1000, 2)
        + " inc=" + ROUND(patch:INCLINATION, 2)
        + " entryUt=" + ROUND(hit["entryUt"], 1)
        + " remainingVacDv=" + ROUND(SHIP:DELTAV:VACUUM, 1)
        + " correctionCap=" + ROUND(_bplaneTrimCap(targetBody, phaseCap), 2)).
}

LOCAL FUNCTION _bplaneEnsureSoiAlarm {
    PARAMETER targetBody.
    IF SHIP:BODY = targetBody { RETURN. }
    LOCAL hit IS findArrivalPatch(0,targetBody).
    IF hit <> 0 { ensureSoiAlarm(targetBody,hit["entryUt"],"Native B-plane encounter; refreshed after corrections."). }
}

GLOBAL FUNCTION bplaneCaptureCost {
    PARAMETER patch, targetBody.
    PARAMETER captureAp IS -1.
    LOCAL rp IS targetBody:RADIUS + patch:PERIAPSIS.
    IF rp <= 0 { RETURN 1.0e9. }
    LOCAL apAlt IS MAX(35000, patch:PERIAPSIS).
    IF TARGET_AP >= 0 { SET apAlt TO MAX(TARGET_AP, patch:PERIAPSIS). }
    IF captureAp >= 0 { SET apAlt TO MAX(captureAp, patch:PERIAPSIS). }
    LOCAL ra IS targetBody:RADIUS + apAlt.
    LOCAL incoming IS SQRT(targetBody:MU * (1 + patch:ECCENTRICITY) / rp).
    LOCAL captured IS SQRT(targetBody:MU * (2 / rp - 2 / (rp + ra))).
    RETURN MAX(0, incoming - captured).
}

// Read raw patches: POSITIONAT would include the pending correction and
// contaminate the comparison against the unburned encounter.
GLOBAL FUNCTION bplaneCorrectionAllowed {
    PARAMETER nd, targetBody, phaseCap.
    PARAMETER checkCorridor IS TRUE.
    PARAMETER missionOwned IS FALSE.
    LOCAL cap IS _bplaneTrimCap(targetBody, phaseCap, _bplaneReservationCredit(nd,targetBody)).
    LOCAL original IS findArrivalPatch(0, targetBody).
    LOCAL planned IS findArrivalPatch(nd, targetBody).
    mLog("STATS bplane budget dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " cap=" + ROUND(cap, 2)
        + " remainingVacDv=" + ROUND(SHIP:DELTAV:VACUUM, 1)
        + " spent=" + ROUND(_bplaneTrimSpent(targetBody), 2)
        + " originalPatch=" + (original <> 0)
        + " plannedPatch=" + (planned <> 0)).
    IF planned = 0 {
        _bplaneHoldCorrection("planned-encounter-missing",missionOwned). RETURN FALSE.
    }
    IF NOT arrivalGoalPolicyOk(planned,targetBody,CAPTURE_PE) {
        _bplaneHoldCorrection("arrival-intent-or-native-event",missionOwned). RETURN FALSE.
    }
    LOCAL burnSeconds IS arrivalBurnSeconds(nd:DELTAV:MAG).
    // Recheck after solving: a trial burn can shift entry, and planning
    // itself consumes some of the remaining alignment time.
    mLog("STATS bplane timing nodeUt=" + nd:TIME
        + " lead=" + (nd:TIME-TIME:SECONDS)
        + " entryUt=" + planned["entryUt"]
        + " soiGap=" + (planned["entryUt"]-nd:TIME)
        + " minLead=" + BPLANE_EXISTING_NODE_MIN_ETA
        + " minSoiGap=" + SOI_BUFFER_TIME).
    IF NOT (burnSeconds >= 0 AND burnSeconds < 1e30
            AND nd:TIME-burnSeconds/2-TIME:SECONDS >= BPLANE_EXISTING_NODE_MIN_ETA
            AND planned["entryUt"]-nd:TIME-burnSeconds/2 > SOI_BUFFER_TIME) {
        _bplaneHoldCorrection("insufficient-pre-soi-burn-lead",missionOwned). RETURN FALSE.
    }
    IF BPLANE_REQUIRE_PLANE <> 0 AND checkCorridor {
        LOCAL patch IS planned["patch"].
        LOCAL planeErr IS _bplaneElementPlaneError(
            patch:INCLINATION, patch:LAN, _bplaneWantInc(), CAPTURE_LAN).
        mLog("STATS bplane required-corridor PeKm=" + ROUND(patch:PERIAPSIS / 1000, 3)
            + " inc=" + ROUND(patch:INCLINATION, 3)
            + " planeErr=" + ROUND(planeErr, 3)).
        IF ABS(patch:PERIAPSIS - CAPTURE_PE) > BPLANE_PE_TOL
                OR planeErr > BPLANE_ANG_TOL {
            _bplaneHoldCorrection("required-arrival-corridor",missionOwned). RETURN FALSE.
        }
    }
    LOCAL shift IS 0.
    LOCAL beforeCost IS 0.
    LOCAL afterCost IS 0.
    IF original <> 0 {
        SET shift TO ABS(planned["entryUt"] - original["entryUt"]).
        SET beforeCost TO arrivalRequiredCaptureDv(original["patch"], targetBody).
        SET afterCost TO arrivalRequiredCaptureDv(planned["patch"], targetBody).
        mLog("STATS bplane comparison originalPeKm=" + ROUND(original["patch"]:PERIAPSIS / 1000, 2)
            + " originalInc=" + ROUND(original["patch"]:INCLINATION, 2)
            + " originalEntryUt=" + ROUND(original["entryUt"], 1)
            + " plannedPeKm=" + ROUND(planned["patch"]:PERIAPSIS / 1000, 2)
            + " plannedInc=" + ROUND(planned["patch"]:INCLINATION, 2)
            + " plannedEntryUt=" + ROUND(planned["entryUt"], 1)
            + " shiftSeconds=" + ROUND(shift, 1)
            + " captureBeforeDv=" + ROUND(beforeCost, 2)
            + " captureAfterDv=" + ROUND(afterCost, 2)).
    }
    IF nd:DELTAV:MAG > cap + 0.001 {
        _bplaneHoldCorrection("correction-budget",missionOwned). RETURN FALSE.
    }
    IF BPLANE_CAPTURE_MARGIN >= 0 {
        LOCAL needed IS nd:DELTAV:MAG
            + arrivalRequiredCaptureDv(planned["patch"], targetBody) + BPLANE_CAPTURE_MARGIN.
        mLog("STATS bplane capture-budget neededDv=" + ROUND(needed, 2)
            + " marginDv=" + BPLANE_CAPTURE_MARGIN
            + " availableDv=" + ROUND(SHIP:DELTAV:VACUUM, 2)).
        IF needed > SHIP:DELTAV:VACUUM {
            _bplaneHoldCorrection("correction-plus-capture-budget",missionOwned). RETURN FALSE.
        }
    }
    IF original = 0 { RETURN TRUE. }
    IF BPLANE_MAX_ARRIVAL_SHIFT >= 0 AND shift > BPLANE_MAX_ARRIVAL_SHIFT {
        _bplaneHoldCorrection("arrival-time-shift",missionOwned). RETURN FALSE.
    }
    IF BPLANE_MAX_CAPTURE_DV_INCREASE >= 0
            AND afterCost - beforeCost > BPLANE_MAX_CAPTURE_DV_INCREASE {
        _bplaneHoldCorrection("capture-cost-increase",missionOwned). RETURN FALSE.
    }
    RETURN TRUE.
}

// Review intent is small and persistent: bind approval to this exact node,
// phase and mission. A changed or expired node needs a fresh plan/review.
GLOBAL FUNCTION bplaneReviewMatches {
    PARAMETER saved, nd.
    RETURN saved["mission"] = stateGet("mission_id", "")
        AND saved["phase"] = stateGet("phase", "")
        AND saved["body"] = SHIP:BODY:NAME
        AND saved["target"] = getTarget("")
        AND ABS(saved["ut"] - nd:TIME) < 0.01
        AND ABS(saved["pro"] - nd:PROGRADE) < 0.001
        AND ABS(saved["rad"] - nd:RADIALOUT) < 0.001
        AND ABS(saved["normal"] - nd:NORMAL) < 0.001.
}

LOCAL FUNCTION _bplaneShowReview {
    PARAMETER nd, targetBody.
    LOCAL hit IS findArrivalPatch(nd, targetBody).
    IF hit = 0 { PRINT "Reviewed node no longer has an encounter; replan.". RETURN. }
    LOCAL patch IS hit["patch"].
    LOCAL latitudeReach IS MIN(patch:INCLINATION, 180 - patch:INCLINATION).
    mLog("STATS bplane review dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " PeKm=" + ROUND(patch:PERIAPSIS / 1000, 2)
        + " inc=" + ROUND(patch:INCLINATION, 2)
        + " maxLatitude=" + ROUND(latitudeReach, 2)
        + " eta=" + ROUND(nd:ETA, 1)).
    LOCAL captureDv IS bplaneCaptureCost(patch, targetBody).
    LOCAL captureAp IS MAX(35000, patch:PERIAPSIS).
    IF TARGET_AP >= 0 { SET captureAp TO MAX(TARGET_AP, patch:PERIAPSIS). }
    mLog("STATS bplane review configuredCaptureApKm=" + (captureAp / 1000)
        + " captureDv=" + ROUND(captureDv, 2)
        + " remainingAfterDv=" + ROUND(SHIP:DELTAV:VACUUM - nd:DELTAV:MAG - captureDv, 2)
        + " requiredReserve=" + BPLANE_CAPTURE_MARGIN).
    FOR apAlt IN LIST(50000, 100000, 500000) {
        IF apAlt >= patch:PERIAPSIS AND apAlt < targetBody:SOIRADIUS - targetBody:RADIUS {
            LOCAL cost IS bplaneCaptureCost(patch, targetBody, apAlt).
            mLog("STATS bplane review captureApKm=" + (apAlt / 1000)
                + " captureDv=" + ROUND(cost, 2)
                + " remainingAfterDv=" + ROUND(SHIP:DELTAV:VACUUM - nd:DELTAV:MAG - cost, 2)).
        }
    }
    PRINT "Arrival candidate retained. No fuel spent and no targets changed.".
    PRINT "Review the map. Acceptance adopts this Pe/inclination for this mission leg.".
    PRINT "RUNPATH(" + CHAR(34) + "0:/cmd/arrival.ks" + CHAR(34)
        + ", " + CHAR(34) + "accept" + CHAR(34) + ").".
    PRINT "Optional third argument: capture apoapsis in km (default keeps current target).".
    PRINT "Use action replan to discard it. Game time continues; node ETA matters.".
}

GLOBAL FUNCTION bplanePauseForReview {
    LOCAL saved IS stateGet("bplane_review", LEXICON()).
    IF saved:LENGTH = 0 { RETURN FALSE. }
    IF saved["mission"] <> stateGet("mission_id", "")
            OR saved["phase"] <> stateGet("phase", "") {
        stateRemove("bplane_review"). RETURN FALSE.
    }
    IF HASNODE {
        IF bplaneReviewMatches(saved, NEXTNODE) {
            _bplaneShowReview(NEXTNODE, BODY(saved["target"])).
        } ELSE {
            PRINT "Reviewed node changed; use arrival action replan.".
        }
    } ELSE {
        PRINT "Reviewed node is missing; use arrival action replan.".
    }
    yieldToPrompt(). RETURN TRUE.
}

LOCAL FUNCTION _bplaneOfferReview {
    PARAMETER nd, targetBody, phaseCap.
    LOCAL hit IS findArrivalPatch(nd, targetBody).
    IF hit = 0 {
        _bplaneHoldCorrection("review-encounter-missing"). RETURN.
    }
    IF hit["patch"]:PERIAPSIS < BPLANE_REVIEW_MIN_PE
            OR hit["patch"]:PERIAPSIS >= targetBody:SOIRADIUS - targetBody:RADIUS {
        _bplaneHoldCorrection("review-periapsis-unsafe"). RETURN.
    }
    // Only the precision gate is waived for review. Existing fuel and
    // trajectory constraints still apply; presenting a node is not approval.
    IF NOT bplaneCorrectionAllowed(nd, targetBody, phaseCap, FALSE) { RETURN. }
    stateSet("bplane_review", LEX(
        "mission", stateGet("mission_id", ""), "phase", stateGet("phase", ""),
        "body", SHIP:BODY:NAME, "target", targetBody:NAME,
        "ut", nd:TIME, "pro", nd:PROGRADE, "rad", nd:RADIALOUT, "normal", nd:NORMAL)).
    _bplaneShowReview(nd, targetBody).
    yieldToPrompt().
}

LOCAL FUNCTION _bplaneReserveCorrection {
    PARAMETER nd, targetBody.
    IF findArrivalPatch(0, targetBody) = 0 { RETURN. }
    // Reserve planned cost before ignition; a power cut / partial burn
    // must not reset the allowance on the next boot.
    LOCAL spent IS _bplaneTrimSpent(targetBody).
    LOCAL id IS stateGet("bplane_budget_id","").
    LOCAL reserved IS stateGet("bplane_budget_reservation",LEXICON()).
    LOCAL cost IS nd:DELTAV:MAG.
    LOCAL additional IS cost.
    IF reserved:HASKEY("ID") AND reserved["ID"] = id
            AND ABS(reserved["UT"]-nd:TIME) < 0.01 {
        SET additional TO MAX(0,cost-reserved["COST"]).
    }
    // Persist the pending charge first. Re-entering after a partial write
    // completes it once; changed/new nodes still pay their full admission.
    LOCAL total IS spent+additional.
    IF reserved:HASKEY("ID") AND reserved["ID"] = id
            AND ABS(reserved["UT"]-nd:TIME) < 0.01 {
        SET total TO MAX(spent,reserved["TOTAL"]+additional).
        SET cost TO MAX(cost,reserved["COST"]).
    }
    stateSet("bplane_budget_reservation",LEXICON("ID",id,"UT",nd:TIME,"COST",cost,"TOTAL",total,
        "MISSION",stateGet("mission_id",""),"PHASE",stateGet("phase",""),"BODY",SHIP:BODY:NAME)).
    stateSet("bplane_budget_spent",total).
}

LOCAL FUNCTION _bplaneReservationCredit {
    PARAMETER nd, targetBody.
    LOCAL reserved IS stateGet("bplane_budget_reservation",LEXICON()).
    // _bplaneTrimSpent also completes a pending ledger write before reuse.
    LOCAL spent IS _bplaneTrimSpent(targetBody).
    IF reserved:HASKEY("ID") AND reserved["ID"] = stateGet("bplane_budget_id","")
            AND ABS(reserved["UT"]-nd:TIME) < 0.01 AND NOT maneuverBurnInterrupted() {
        RETURN MIN(spent,reserved["COST"]).
    }
    RETURN 0.
}

// A verified tiny trim tail can leave early arrival targeting assigned to
// its existing midpoint. This is a coast handoff, never capture admission
// or a successful executor report. Legacy/unbound burns require review.
LOCAL FUNCTION _bplaneRecoverStoppedTrim {
    IF ABORT OR WARP <> 0 OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR stateGet("phase","") <> "BPLANE" OR NOT _bplaneHasMidcourseRefinement()
            OR NOT maneuverBurnInterrupted() OR NOT HASNODE
            OR stateGet("burn_body","") <> SHIP:BODY:NAME
            OR stateGet("burn_abort_reason","") <> "residual-outside-tolerance"
            OR NOT (SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
                AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) { RETURN FALSE. }
    LOCAL residual IS stateGetNum("burn_abort_residual",-1).
    LOCAL planned IS stateGetNum("burn_dv",-1).
    IF NOT (planned > MIN_EXEC_DV AND planned < 1e30
            AND residual >= 0 AND residual <= MIN(MIN_EXEC_DV,planned*0.01)
            AND ABS(NEXTNODE:TIME-stateGetNum("burn_node_time",-1)) < 0.5
            AND NEXTNODE:DELTAV:MAG >= 0 AND NEXTNODE:DELTAV:MAG <= MIN(MIN_EXEC_DV,planned*0.01)) { RETURN FALSE. }
    LOCAL report IS stateGet("last_burn_report","").
    IF NOT (report:CONTAINS("cutoffFault=residual-outside-tolerance")
            AND report:CONTAINS("shutdownAttempted=False") AND report:CONTAINS("thrustStopped=True")
            AND (report:CONTAINS("reason=live-node-trim")
                OR report:CONTAINS("reason=live-thrust-axis-trim"))) { RETURN FALSE. }
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 { RETURN FALSE. }
    LOCAL intent IS stateGet("bplane_budget_reservation",LEXICON()).
    FOR key IN LIST("ID","UT","MISSION","PHASE","BODY") {
        IF NOT intent:HASKEY(key) { RETURN FALSE. }
    }
    IF intent["ID"] <> targetBody:NAME+":"+stateGetNum("launch_time",0)
            OR intent["MISSION"] <> stateGet("mission_id","") OR intent["PHASE"] <> "BPLANE"
            OR intent["BODY"] <> SHIP:BODY:NAME OR ABS(intent["UT"]-NEXTNODE:TIME) >= 0.01 { RETURN FALSE. }
    LOCAL hit IS _bplaneCoastEncounter(targetBody).
    IF hit = 0 OR hit["entryUt"]-TIME:SECONDS <= 3*MAX(1,BPLANE_LEAD) { RETURN FALSE. }
    IF NOT arrivalGoalPolicyOk(hit,targetBody,CAPTURE_PE)
            OR NOT (hit["patch"]:PERIAPSIS >= BPLANE_REVIEW_MIN_PE) { RETURN FALSE. }
    LOCAL laterCap IS _bplaneTrimCap(targetBody,REFINE_BPLANE_DV_CAP).
    LOCAL needed IS arrivalRequiredCaptureDv(hit["patch"],targetBody)
        + MAX(0,MAX(BPLANE_CAPTURE_MARGIN,BPLANE_TRIM_RESERVE_DV))+laterCap.
    IF NOT (laterCap > MIN_EXEC_DV AND needed >= 0 AND needed <= SHIP:DELTAV:VACUUM) { RETURN FALSE. }
    IF NOT thrustCutoffOk() { RETURN FALSE. }
    _bplaneEnsureSoiAlarm(targetBody).
    maneuverAcceptHandoff().
    mLogSummary("STATS bplane trim-recovery decision=midcourse residual=" + residual
        + " PeKm=" + (hit["patch"]:PERIAPSIS/1000) + " neededDv=" + needed
        + " finalCorridorAccepted=False").
    IF _bplaneQueueMidcourseRetry("stopped-trim-needs-refinement")
            AND _bplaneHandoffMidcourseRetry(targetBody) { RETURN TRUE. }
    _bplaneHoldCorrection("stopped-trim-recovery-context-changed",TRUE).
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneSafeEncounter {
    PARAMETER targetBody.
    PARAMETER meas.

    IF BPLANE_REQUIRE_PLANE <> 0 { RETURN FALSE. }
    IF meas = 0 { RETURN FALSE. }
    IF targetBody:ATM:EXISTS {
        RETURN _bplaneCurrentCorridorOk(targetBody,CAPTURE_PE,_bplaneWantInc(),CAPTURE_LAN).
    }
    RETURN meas["pe"] <= targetBody:SOIRADIUS * BPLANE_SAFE_HANDOFF_SOI_MULT.
}

LOCAL FUNCTION _bplaneNeedsDepartureSoiCoast {
    PARAMETER targetBody.

    IF SHIP:BODY = targetBody { RETURN FALSE. }
    IF NOT SHIP:BODY:HASBODY { RETURN FALSE. }
    IF NOT targetBody:HASBODY { RETURN FALSE. }
    RETURN SHIP:BODY:BODY = targetBody:BODY AND SHIP:BODY <> targetBody:BODY.
}

LOCAL FUNCTION _bplaneCoastOutOfDepartureSoi {
    PARAMETER targetBody.

    IF NOT _bplaneNeedsDepartureSoiCoast(targetBody) { RETURN TRUE. }
    LOCAL departureBody IS SHIP:BODY.
    LOCAL transferCenter IS departureBody:BODY.
    IF NOT SHIP:ORBIT:HASNEXTPATCH {
        mLogError("BPLANE: still inside " + departureBody:NAME
            + " SOI and no escape patch is available; holding before "
            + "arrival targeting.").
        WAIT 30.
        RETURN FALSE.
    }
    mLogWarn("BPLANE: still inside " + departureBody:NAME
        + " SOI; coasting to " + transferCenter:NAME
        + " before arrival B-plane correction.").
    waitForSOI(transferCenter, 10).
    orbitSummary().
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneCorridorError {
    PARAMETER targetBody, meas, wantPe, wantInc, wantLan.

    LOCAL tgt IS targetBplaneVector(targetBody, meas, wantPe, wantInc, wantLan).
    LOCAL planeErr IS _bplaneElementPlaneError(
        meas["inc"], meas["lan"], wantInc, wantLan).
    // Keep the closest-achievable-plane policy for a tilted asymptote,
    // but never reject elements that already satisfy the actual request.
    IF BPLANE_REQUIRE_PLANE = 0 AND wantInc >= 0 AND tgt["offPlane"] > BPLANE_ANG_TOL {
        SET planeErr TO MIN(planeErr, VANG(meas["hHat"], tgt["normal"])).
    }
    RETURN LEX("peErr", meas["pe"] - wantPe,
        "planeErr", planeErr,
        "target", tgt).
}

LOCAL FUNCTION _bplaneElementPlaneError {
    PARAMETER inc, lan, wantInc, wantLan.
    IF wantInc < 0 { RETURN 0. }
    IF wantLan < 0 { RETURN ABS(inc - wantInc). }
    // Compare requested elements, independently of the reconstructed
    // B-plane basis. LAN has no weight at an equatorial target.
    LOCAL cosPlane IS COS(inc) * COS(wantInc)
        + SIN(inc) * SIN(wantInc) * COS(lan - wantLan).
    RETURN ARCCOS(MAX(-1, MIN(1, cosPlane))).
}

LOCAL FUNCTION _bplaneCurrentCorridorOk {
    PARAMETER targetBody, wantPe, wantInc, wantLan.
    // Check the unburned patch before creating/reusing a node.
    // POSITIONAT(SHIP, ...) includes pending maneuvers, so it must
    // not supply the geometry for this no-burn acceptance decision.
    LOCAL hit IS findArrivalPatch(0, targetBody).
    IF hit = 0 { RETURN FALSE. }
    IF NOT arrivalGoalPolicyOk(hit,targetBody,wantPe) { RETURN FALSE. }
    LOCAL patch IS hit["patch"].
    LOCAL peErr IS ABS(patch:PERIAPSIS - wantPe).
    LOCAL planeErr IS _bplaneElementPlaneError(
        patch:INCLINATION, patch:LAN, wantInc, wantLan).
    IF peErr > BPLANE_PE_TOL { RETURN FALSE. }
    IF planeErr > BPLANE_ANG_TOL AND BPLANE_REQUIRE_PLANE = 0 AND wantInc >= 0 {
        // Optional-plane completion must use the same achievable normal as
        // planning. Native elements alone cannot prove a projected goal;
        // require a fresh, internally consistent unburned measurement.
        LOCAL meas IS measureArrival(0,targetBody).
        IF meas = 0 { RETURN FALSE. }
        LOCAL err IS _bplaneCorridorError(targetBody,meas,wantPe,wantInc,wantLan).
        SET planeErr TO err["planeErr"].
    }
    IF NOT (planeErr >= 0 AND planeErr <= BPLANE_ANG_TOL) { RETURN FALSE. }
    mLog("BPLANE: current trajectory already in corridor; no correction. "
        + "PeErrKm=" + ROUND(peErr / 1000, 2)
        + " planeErr=" + ROUND(planeErr, 3)).
    RETURN TRUE.
}

LOCAL FUNCTION _bplanePlaneFeasible {
    PARAMETER err.
    RETURN err["target"]["offPlane"] <= BPLANE_OFFPLANE_TOL.
}

LOCAL FUNCTION _bplaneCorridorOk {
    PARAMETER err.
    PARAMETER wantInc.
    PARAMETER peTol.
    PARAMETER angTol.

    IF ABS(err["peErr"]) > peTol { RETURN FALSE. }
    IF wantInc < 0 { RETURN TRUE. }
    IF BPLANE_REQUIRE_PLANE = 0 AND NOT _bplanePlaneFeasible(err) { RETURN TRUE. }
    RETURN err["planeErr"] <= angTol.
}

LOCAL FUNCTION _bplanePlanScore {
    PARAMETER err.
    PARAMETER targetBody.
    PARAMETER wantInc.

    // Error inside the corridor costs nothing. Otherwise the search
    // can prefer an exact Pe with a bad plane over an acceptable orbit.
    LOCAL score IS MAX(0, ABS(err["peErr"]) - BPLANE_PE_TOL).
    IF wantInc >= 0 AND (BPLANE_REQUIRE_PLANE <> 0 OR _bplanePlaneFeasible(err)) {
        SET score TO score + MAX(0, err["planeErr"] - BPLANE_ANG_TOL)
            * targetBody:SOIRADIUS / 90.
    }
    RETURN score.
}

LOCAL FUNCTION _bplaneNodeAxisGet {
    PARAMETER nd.
    PARAMETER axis.

    IF axis = "PROGRADE" { RETURN nd:PROGRADE. }
    IF axis = "RADIALOUT" { RETURN nd:RADIALOUT. }
    IF axis = "NORMAL" { RETURN nd:NORMAL. }
    RETURN 0.
}

LOCAL FUNCTION _bplaneNodeAxisSet {
    PARAMETER nd.
    PARAMETER axis.
    PARAMETER val.

    IF axis = "PROGRADE" { SET nd:PROGRADE TO val. }
    IF axis = "RADIALOUT" { SET nd:RADIALOUT TO val. }
    IF axis = "NORMAL" { SET nd:NORMAL TO val. }
}

LOCAL FUNCTION _bplaneFallbackSearch {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    PARAMETER dvCap.
    PARAMETER currentScore.
    PARAMETER iter.
    PARAMETER peOnly IS FALSE.

    LOCAL axes IS LIST("PROGRADE", "RADIALOUT", "NORMAL").
    IF peOnly { SET axes TO LIST("PROGRADE", "RADIALOUT"). }
    LOCAL signs IS LIST(1, -1).
    LOCAL steps IS LIST(10.0, 5.0, 2.0, 1.0, 0.5, 0.1, 0.05, 0.01).

    LOCAL p0 IS nd:PROGRADE.
    LOCAL r0 IS nd:RADIALOUT.
    LOCAL n0 IS nd:NORMAL.
    LOCAL bestAxis IS "".
    LOCAL bestVal IS 0.
    LOCAL bestScore IS currentScore.
    LOCAL bestMeas IS 0.
    LOCAL bestErr IS 0.

    FOR step IN steps {
        FOR axis IN axes {
            LOCAL oldVal IS _bplaneNodeAxisGet(nd, axis).
            FOR sgn IN signs {
                SET nd:PROGRADE TO p0.
                SET nd:RADIALOUT TO r0.
                SET nd:NORMAL TO n0.
                LOCAL trialVal IS oldVal + sgn * step.
                _bplaneNodeAxisSet(nd, axis, trialVal).
                WAIT 0.02.
                IF nd:DELTAV:MAG <= dvCap {
                    LOCAL trial IS measureArrival(nd, targetBody).
                    IF trial <> 0 {
                        LOCAL trialErr IS _bplaneCorridorError(
                            targetBody, trial, wantPe, wantInc, wantLan).
                        LOCAL trialScore IS _bplanePlanScore(
                            trialErr, targetBody, wantInc).
                        IF _bplaneCorridorOk(trialErr, wantInc,
                                BPLANE_PE_TOL, BPLANE_ANG_TOL) {
                            mLog("  BPLANE[" + iter
                                + "] fallback reached corridor; stopping search.").
                            RETURN TRUE.
                        }
                        IF trialScore < bestScore {
                            SET bestScore TO trialScore.
                            SET bestAxis TO axis.
                            SET bestVal TO trialVal.
                            SET bestMeas TO trial.
                            SET bestErr TO trialErr.
                        }
                    }
                }
            }
        }
    }

    SET nd:PROGRADE TO p0.
    SET nd:RADIALOUT TO r0.
    SET nd:NORMAL TO n0.
    WAIT 0.02.

    IF bestAxis = "" { RETURN FALSE. }

    _bplaneNodeAxisSet(nd, bestAxis, bestVal).
    WAIT 0.02.
    mLog("  BPLANE[" + iter + "] fallback "
        + bestAxis + "=" + ROUND(bestVal,2)
        + " PeKm=" + ROUND(bestMeas["pe"] / 1000,1)
        + " planeErr=" + ROUND(bestErr["planeErr"],2)
        + " scoreKm=" + ROUND(bestScore / 1000,1)
        + " dv=" + ROUND(nd:DELTAV:MAG,2)).
    RETURN TRUE.
}

LOCAL FUNCTION _bplaneAcquireAxis {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER axis.
    PARAMETER stepSize.
    PARAMETER searchStart.
    PARAMETER searchEnd.
    PARAMETER bestD.
    PARAMETER dvCap.

    LOCAL oldVal IS _bplaneNodeAxisGet(nd, axis).
    LOCAL bestVal IS oldVal.
    LOCAL bestCA IS 0.
    LOCAL trialBestD IS bestD.
    LOCAL improved IS FALSE.
    LOCAL budgetBlocked IS FALSE.

    FOR sgn IN LIST(1, -1) {
        _bplaneNodeAxisSet(nd, axis, oldVal + sgn * stepSize).
        WAIT 0.02.
        IF dvCap < 0 OR nd:DELTAV:MAG <= dvCap {
            LOCAL ca IS _findClosestApproach(targetBody, searchStart, searchEnd, 60).
            IF ca["distance"] < trialBestD {
                SET trialBestD TO ca["distance"].
                SET bestCA TO ca.
                SET bestVal TO oldVal + sgn * stepSize.
                SET improved TO TRUE.
            }
        } ELSE {
            SET budgetBlocked TO TRUE.
        }
    }

    _bplaneNodeAxisSet(nd, axis, oldVal).
    WAIT 0.02.
    RETURN LEXICON(
        "improved", improved,
        "budgetBlocked", budgetBlocked,
        "value", bestVal,
        "ca", bestCA,
        "distance", trialBestD).
}

// ============================================================
// _acquireEncounter — if the raw flight plan is just outside the
// target SOI, hill-climb a tiny MCC node until KSP generates the
// target patch. Precision still belongs to the Newton B-plane
// solver below; this phase only reacquires the encounter.
// ============================================================
LOCAL FUNCTION _acquireEncounter {
    PARAMETER nd.
    PARAMETER targetBody.
    PARAMETER dvCap.

    LOCAL searchStart IS nd:TIME.
    LOCAL searchEnd IS nd:TIME + targetBody:ORBIT:PERIOD.
    LOCAL bestCA IS _findClosestApproach(targetBody, searchStart, searchEnd, 60).
    LOCAL bestD IS bestCA["distance"].
    LOCAL stepSize IS ACQUIRE_INITIAL_STEP.
    LOCAL axes IS LIST("PROGRADE", "RADIALOUT", "NORMAL").

    mLogWarn("BPLANE: encounter lost; acquiring nearest "
        + targetBody:NAME + " approach at T+"
        + ROUND(bestCA["time"] - TIME:SECONDS, 0)
        + "s CA=" + ROUND(bestD / 1000, 1) + "km"
        + " cap=" + ROUND(dvCap, 1) + "m/s.").

    FROM { LOCAL iter IS 0. } UNTIL iter >= MAX_ACQUIRE_ITER STEP { SET iter TO iter + 1. } DO {
        IF measureArrival(nd, targetBody) <> 0 {
            mLog("BPLANE acquire: patch acquired in " + iter
                + " iter(s), dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " m/s.").
            RETURN TRUE.
        }
        IF dvCap >= 0 AND nd:DELTAV:MAG > dvCap {
            mLogWarn("BPLANE acquire: dV budget exceeded while searching (dv="
                + ROUND(nd:DELTAV:MAG, 2) + " cap="
                + ROUND(dvCap, 2) + " m/s); best CA="
                + ROUND(bestD / 1000, 1) + "km.").
            RETURN FALSE.
        }

        LOCAL improved IS FALSE.
        LOCAL budgetBlocked IS FALSE.
        LOCAL startD IS bestD.

        FOR axis IN axes {
            LOCAL trial IS _bplaneAcquireAxis(
                nd, targetBody, axis, stepSize, searchStart, searchEnd, bestD, dvCap).
            IF trial["budgetBlocked"] {
                SET budgetBlocked TO TRUE.
            }
            IF trial["improved"] {
                _bplaneNodeAxisSet(nd, axis, trial["value"]).
                WAIT 0.02.
                SET bestCA TO trial["ca"].
                SET bestD TO trial["distance"].
                SET improved TO TRUE.
            }
        }

        IF measureArrival(nd, targetBody) <> 0 {
            mLog("BPLANE acquire: patch acquired in " + (iter + 1)
                + " iter(s), dv=" + ROUND(nd:DELTAV:MAG, 2)
                + " m/s.").
            RETURN TRUE.
        }
        IF dvCap >= 0 AND nd:DELTAV:MAG > dvCap {
            mLogWarn("BPLANE acquire: dV budget exceeded after improvement (dv="
                + ROUND(nd:DELTAV:MAG, 2) + " cap="
                + ROUND(dvCap, 2) + " m/s); best CA="
                + ROUND(bestD / 1000, 1) + "km.").
            RETURN FALSE.
        }

        IF improved {
            SET stepSize TO stepSize * ACQUIRE_STEP_GROWTH.
            mLog("  BPLANE acquire[" + iter + "] CA "
                + ROUND(startD / 1000, 1) + "->"
                + ROUND(bestD / 1000, 1) + "km step="
                + ROUND(stepSize, 2) + " dv="
                + ROUND(nd:DELTAV:MAG, 2)).
        } ELSE {
            SET stepSize TO stepSize * 0.5.
            IF budgetBlocked {
                mLogWarn("  BPLANE acquire[" + iter
                    + "] no in-budget improvement; step="
                    + ROUND(stepSize, 2) + " best CA="
                    + ROUND(bestD / 1000, 1) + "km dv="
                    + ROUND(nd:DELTAV:MAG, 2) + " cap="
                    + ROUND(dvCap, 2) + "m/s.").
            } ELSE {
                mLogWarn("  BPLANE acquire[" + iter + "] no improvement; step="
                    + ROUND(stepSize, 2) + " best CA="
                    + ROUND(bestD / 1000, 1) + "km.").
            }
            IF stepSize < ACQUIRE_MIN_STEP {
                IF budgetBlocked {
                    mLogWarn("BPLANE acquire: no improving step fits the dV budget "
                        + "(cap=" + ROUND(dvCap, 2) + "m/s); best CA="
                        + ROUND(bestD / 1000, 1) + "km dv="
                        + ROUND(nd:DELTAV:MAG, 2) + " m/s.").
                } ELSE {
                    mLogWarn("BPLANE acquire: step fell below "
                        + ACQUIRE_MIN_STEP + " m/s; best CA="
                        + ROUND(bestD / 1000, 1) + "km dv="
                        + ROUND(nd:DELTAV:MAG, 2) + " m/s.").
                }
                RETURN FALSE.
            }
        }
    }

    mLogWarn("BPLANE acquire: hit iteration cap; best CA="
        + ROUND(bestD / 1000, 1) + "km dv="
        + ROUND(nd:DELTAV:MAG, 2) + " m/s.").
    RETURN measureArrival(nd, targetBody) <> 0.
}

// Both solver modes must put their correction in the pre-arrival frame.
LOCAL FUNCTION _bplaneCreateCorrectionNode {
    PARAMETER targetBody.
    PARAMETER missionOwned IS FALSE.
    PARAMETER correctionCap IS 0.
    IF ABORT { RETURN 0. }
    IF WARP > 0 {
        SET WARP TO 0.
        WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    }
    IF ABORT { RETURN 0. }
    IF SHIP:BODY = targetBody {
        _bplaneHoldCorrection("entered-target-before-correction-plan",missionOwned). RETURN 0.
    }
    LOCAL capSeconds IS arrivalBurnSeconds(correctionCap).
    LOCAL minimumSeconds IS arrivalBurnSeconds(MIN_EXEC_DV).
    IF NOT (capSeconds >= 0 AND minimumSeconds >= 0) {
        _bplaneHoldCorrection("burn-duration-unavailable",missionOwned). RETURN 0.
    }
    LOCAL nodeUt IS TIME:SECONDS+arrivalCorrectionLead(capSeconds).
    LOCAL hit IS findArrivalPatch(0,targetBody).
    IF hit <> 0 {
        IF NOT (hit["entryUt"] > TIME:SECONDS AND hit["entryUt"] < 1e30) {
            _bplaneHoldCorrection("invalid-arrival-time",missionOwned). RETURN 0.
        }
        // Keep the node in the current body's frame, including late boots.
        // Leave the existing SOI buffer plus a physics-update allowance.
        SET nodeUt TO MIN(nodeUt,hit["entryUt"]-SOI_BUFFER_TIME-MAX(2,minimumSeconds/2)-1).
    }
    LOCAL lead IS nodeUt-TIME:SECONDS.
    mLog("STATS bplane node-time ut=" + nodeUt + " lead=" + lead
        + " configuredLead=" + BPLANE_LEAD + " patch=" + (hit <> 0)).
    IF NOT (lead >= MAX(1,BPLANE_EXISTING_NODE_MIN_ETA) AND lead < 1e30) {
        _bplaneHoldCorrection("insufficient-pre-soi-burn-lead",missionOwned). RETURN 0.
    }
    LOCAL nd IS NODE(nodeUt,0,0,0).
    ADD nd.
    RETURN nd.
}

// A single Pe constraint needs a scalar solve, not the plane solver's
// two B-vector constraints. Differentiate KSP's actual patch elements;
// a minimum-length step may use any axis when no arrival plane is requested.
LOCAL FUNCTION _bplanePlanPeOnly {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER dvCap.
    PARAMETER missionOwned IS FALSE.
    IF findArrivalPatch(0, targetBody) = 0 {
        _bplaneHoldCorrection("pe-recovery-encounter-missing"). RETURN 0.
    }
    LOCAL nd IS _bplaneCreateCorrectionNode(targetBody,missionOwned,dvCap).
    IF nd = 0 { RETURN 0. }
    WAIT 0.1.
    LOCAL iteration IS 0.
    mLog("STATS bplane pe-only start targetPeKm=" + (wantPe / 1000)
        + " cap=" + dvCap + " toleranceKm=" + (BPLANE_PE_TOL / 1000)).
    // Plan inside the acceptance corridor, leaving room for execution error.
    LOCAL solveTol IS MIN(500, BPLANE_PE_TOL * 0.25).
    UNTIL iteration >= 16 {
        SET iteration TO iteration + 1.
        LOCAL hit IS findArrivalPatch(nd, targetBody).
        IF hit = 0 { BREAK. }
        LOCAL peNow IS hit["patch"]:PERIAPSIS.
        LOCAL peError IS wantPe - peNow.
        IF ABS(peError) <= solveTol {
            mLog("STATS bplane pe-only converged=True PeKm=" + ROUND(peNow / 1000, 3)
                + " dv=" + ROUND(nd:DELTAV:MAG, 3) + " iterations=" + iteration).
            // The common planner applies the execution minimum to this
            // candidate, just as it does for a plane-and-Pe solution.
            RETURN nd.
        }
        LOCAL basePro IS nd:PROGRADE.
        LOCAL baseRad IS nd:RADIALOUT.
        LOCAL baseNormal IS nd:NORMAL.
        LOCAL gradients IS LIST().
        FOR axis IN LIST("PROGRADE", "RADIALOUT", "NORMAL") {
            LOCAL slope IS 0.
            // Try both signs if the first probe loses the encounter.
            FOR probe IN LIST(FD_STEP, -FD_STEP) {
                _bplaneNodeAxisSet(nd, axis, _bplaneNodeAxisGet(nd, axis) + probe).
                WAIT 0.1.
                LOCAL sample IS findArrivalPatch(nd, targetBody).
                IF sample <> 0 {
                    SET slope TO (sample["patch"]:PERIAPSIS - peNow) / probe.
                }
                SET nd:PROGRADE TO basePro.
                SET nd:RADIALOUT TO baseRad.
                SET nd:NORMAL TO baseNormal.
                WAIT 0.1.
                IF sample <> 0 { BREAK. }
            }
            gradients:ADD(slope).
        }
        LOCAL grad2 IS gradients[0]^2 + gradients[1]^2 + gradients[2]^2.
        IF grad2 < 0.000001 { BREAK. }
        LOCAL stepPro IS peError * gradients[0] / grad2.
        LOCAL stepRad IS peError * gradients[1] / grad2.
        LOCAL stepNormal IS peError * gradients[2] / grad2.
        LOCAL stepSize IS SQRT(stepPro^2 + stepRad^2 + stepNormal^2).
        LOCAL scale IS MIN(1, dvCap / MAX(0.000001, stepSize)).
        LOCAL improved IS FALSE.
        FOR fraction IN LIST(1, 0.5, 0.25, 0.125, 0.0625, 0.03125) {
            SET nd:PROGRADE TO basePro + stepPro * scale * fraction.
            SET nd:RADIALOUT TO baseRad + stepRad * scale * fraction.
            SET nd:NORMAL TO baseNormal + stepNormal * scale * fraction.
            // Project the whole candidate into the budget ball. Scaling only
            // the increment stalls near its boundary, even with useful tangential steps.
            LOCAL candidateDv IS SQRT(nd:PROGRADE^2 + nd:RADIALOUT^2 + nd:NORMAL^2).
            IF candidateDv > dvCap {
                LOCAL budgetScale IS dvCap / candidateDv.
                SET nd:PROGRADE TO nd:PROGRADE * budgetScale.
                SET nd:RADIALOUT TO nd:RADIALOUT * budgetScale.
                SET nd:NORMAL TO nd:NORMAL * budgetScale.
            }
            WAIT 0.1.
            IF nd:DELTAV:MAG <= dvCap + 0.001 {
                LOCAL trial IS findArrivalPatch(nd, targetBody).
                IF trial <> 0 {
                    IF ABS(trial["patch"]:PERIAPSIS - wantPe) < ABS(peError) {
                        SET improved TO TRUE. BREAK.
                    }
                }
            }
        }
        IF NOT improved {
            // Rejected probes must not replace the best usable candidate.
            SET nd:PROGRADE TO basePro.
            SET nd:RADIALOUT TO baseRad.
            SET nd:NORMAL TO baseNormal.
            WAIT 0.1.
            BREAK.
        }
    }
    LOCAL finalHit IS findArrivalPatch(nd, targetBody).
    IF finalHit <> 0 {
        // Tight solve tolerance is an aim point, not a stricter flight contract.
        IF ABS(finalHit["patch"]:PERIAPSIS - wantPe) <= BPLANE_PE_TOL
                AND nd:DELTAV:MAG <= dvCap + 0.001 {
            mLog("STATS bplane pe-only converged=True result=inside-corridor PeKm="
                + ROUND(finalHit["patch"]:PERIAPSIS / 1000, 3)
                + " dv=" + ROUND(nd:DELTAV:MAG, 3) + " cap=" + dvCap).
            RETURN nd.
        }
        mLog("STATS bplane pe-only converged=False PeKm="
            + ROUND(finalHit["patch"]:PERIAPSIS / 1000, 3)
            + " dv=" + ROUND(nd:DELTAV:MAG, 3) + " cap=" + dvCap).
    }
    _bplaneHoldCorrection("pe-recovery-not-converged-within-budget").
    RETURN 0.
}

LOCAL FUNCTION _bplaneFinishPeRecovery {
    PARAMETER targetBody, wantPe.
    bplaneArrivalStatus().
    // Raw patch check also works when vector reconstruction cannot.
    IF _bplaneCurrentCorridorOk(targetBody, wantPe, -1, -1) {
        mLog("STATS bplane pe-only result=inside-corridor").
        nextPhase(xferSeq).
    } ELSE {
        _bplaneHoldCorrection("pe-recovery-outside-corridor").
    }
}

LOCAL FUNCTION _bplaneClearCoastTimes {
    midcourseClearReviewAlarm().
    stateSet("xing_arrival_ut", 0).
    stateSet("midcourse_refine_ut", 0).
    stateSet("midcourse_refine_arrival_ut", 0).
    bplaneClearRetryWait().
}

// ============================================================
// planBplaneCorrection — build and converge a correction node.
// Newton iteration: controls (prograde, radialout, normal) -> targets
// (B.T, B.R), Jacobian by finite differences against KSP's own
// patched-conic propagation. Returns the node (already converged
// and ready to execute), or 0 when no correction is needed or
// possible. The node is REMOVEd internally on failure.
// Mission handlers enable live retry; operator previews default to review.
// ============================================================
GLOBAL FUNCTION planBplaneCorrection {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc IS -1.
    PARAMETER wantLan IS -1.
    PARAMETER dvCapOverride IS -1.
    PARAMETER pristineLog IS "".
    PARAMETER allowMidcourseRetry IS FALSE.

    SET _bplaneMinimumSkip["ACCEPTED"] TO FALSE.
    IF allowMidcourseRetry AND _bplaneRetryWaitPending(targetBody) {
        IF NOT _bplaneWaitBeforeSolverRetry(targetBody) { RETURN 0. }
    }
    UNTIL ABORT {
        LOCAL dvCap IS BPLANE_DV_CAP.
        IF BPLANE_REQUIRE_PLANE <> 0 AND (BPLANE_PE_ONLY <> 0 OR wantInc < 0) {
            _bplaneHoldCorrection("required-plane-config-conflict",allowMidcourseRetry). RETURN 0.
        }
        IF dvCapOverride >= 0 { SET dvCap TO dvCapOverride. }
        IF _bplaneCurrentCorridorOk(targetBody, wantPe, wantInc, wantLan) {
            RETURN 0.
        }

        SET dvCap TO _bplaneTrimCap(targetBody, dvCap).
        IF dvCap <= MIN_EXEC_DV {
            _bplaneHoldCorrection("no-optional-budget",allowMidcourseRetry).
            RETURN 0.
        }

        LOCAL nd IS 0.
        IF BPLANE_PE_ONLY <> 0 {
            SET nd TO _bplanePlanPeOnly(targetBody, wantPe, dvCap,allowMidcourseRetry).
        } ELSE {
            SET nd TO _bplanePlanFullCorrection(targetBody, wantPe, wantInc, wantLan,
                dvCap, pristineLog, allowMidcourseRetry).
        }
        IF phaseShouldYield OR ABORT OR nd = 0 { RETURN 0. }
        IF NOT _bplaneCorrectionAboveMinimum(nd) {
            LOCAL solutionDv IS nd:DELTAV:MAG.
            REMOVE nd.
            IF NOT allowMidcourseRetry { RETURN 0. }
            WAIT 0.02.
            IF _bplaneMinimumArrivalOk(targetBody,wantPe,wantInc,wantLan) {
                SET _bplaneMinimumSkip["ACCEPTED"] TO TRUE.
                RETURN 0.
            }
            IF _bplaneQueueMidcourseRetry("below-execution-minimum") { RETURN 0. }
            IF NOT _bplaneWaitBeforeSolverRetry(targetBody,"below-execution-minimum",solutionDv,dvCap) { RETURN 0. }
        } ELSE {
            maneuverUiArchiveLog("bplane").
            RETURN nd.
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _bplanePlanFullCorrection {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    PARAMETER dvCap.
    PARAMETER pristineLog.
    PARAMETER allowMidcourseRetry IS FALSE.
    UNTIL ABORT {
        LOCAL nd IS _bplanePlanFullAttempt(targetBody,wantPe,wantInc,wantLan,
            _bplaneTrimCap(targetBody,dvCap),pristineLog,allowMidcourseRetry).
        IF nd <> -1 { RETURN nd. }
        IF NOT _bplaneWaitBeforeSolverRetry(targetBody,"unconverged-optional-correction",-1,dvCap) { RETURN 0. }
    }
    RETURN 0.
}

LOCAL FUNCTION _bplanePlanFullAttempt {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    PARAMETER dvCap.
    PARAMETER pristineLog.
    PARAMETER allowMidcourseRetry IS FALSE.
    LOCAL peTol IS BPLANE_PE_TOL.
    LOCAL angTol IS BPLANE_ANG_TOL.
    LOCAL nd IS _bplaneCreateCorrectionNode(targetBody,allowMidcourseRetry,dvCap).
    IF nd = 0 { RETURN 0. }
    bplaneResetWarnings().
    WAIT 0.02.

    LOCAL acquired IS FALSE.
    LOCAL meas0 IS measureArrival(nd, targetBody).
    IF meas0 = 0 {
        // A failed vector measurement is not a lost encounter. Do not
        // replace a real map patch with a different closest approach.
        IF findArrivalPatch(0, targetBody) <> 0 {
            _bplaneHoldCorrection("existing-patch-unmeasurable",allowMidcourseRetry).
            RETURN 0.
        }
        mLogWarn("BPLANE: no hyperbolic encounter with "
            + targetBody:NAME + " on the current correction node; "
            + "starting acquisition.").
        IF NOT _acquireEncounter(nd, targetBody, dvCap) {
            mLogError("BPLANE: acquisition failed for "
                + targetBody:NAME + " — removing correction node.").
            REMOVE nd.
            RETURN 0.
        }
        SET acquired TO TRUE.
        SET meas0 TO measureArrival(nd, targetBody).
        IF meas0 = 0 {
            mLogError("BPLANE: acquisition reported success but no "
                + targetBody:NAME + " patch is measurable.").
            REMOVE nd.
            RETURN 0.
        }
    }

    LOCAL err0 IS _bplaneCorridorError(targetBody, meas0, wantPe, wantInc, wantLan).
    LOCAL tgt0 IS err0["target"].
    LOCAL planeErr0 IS err0["planeErr"].
    LOCAL planeMode IS "target-plane".
    IF BPLANE_REQUIRE_PLANE = 0 AND wantInc >= 0 AND tgt0["offPlane"] > angTol {
        mLog("STATS bplane plane-policy required=False metric=closest-achievable"
            + " requestedInc=" + wantInc + " requestedLan=" + wantLan
            + " offPlane=" + tgt0["offPlane"] + " tolerance=" + angTol).
    }
    IF wantInc >= 0 AND NOT _bplanePlaneFeasible(err0) {
        IF BPLANE_REQUIRE_PLANE <> 0 {
            _bplaneHoldCorrection("required-plane-infeasible",allowMidcourseRetry). RETURN 0.
        }
        SET planeMode TO "pe-only".
        mLogWarn("BPLANE: requested capture plane is "
            + ROUND(tgt0["offPlane"], 1)
            + "deg off the arrival asymptote; switching to Pe-only targeting.").
    }

    // Already in the corridor?
    IF _bplaneCorridorOk(err0, wantInc, peTol, angTol) {
        // Acquisition changed the node: this arrival still requires
        // its burn. Removing it would discard the encounter just found.
        IF acquired {
            mLog("BPLANE: acquisition reached corridor; keeping correction node.").
            RETURN nd.
        }
        IF pristineLog <> "" {
            mLog(pristineLog).
        } ELSE {
            mLog("BPLANE: arrival already in corridor (PeErr="
                + ROUND((meas0["pe"] - wantPe) / 1000, 1) + "km planeErr="
                + ROUND(planeErr0, 2) + "deg).").
        }
        REMOVE nd.
        RETURN 0.
    }

    mLog("BPLANE: correcting arrival at " + targetBody:NAME
        + "  Pe " + ROUND(meas0["pe"] / 1000, 1) + "->"
        + ROUND(wantPe / 1000, 1) + "km  planeErr="
        + ROUND(planeErr0, 2) + "deg").

    LOCAL converged IS FALSE.
    LOCAL bestPro IS nd:PROGRADE.
    LOCAL bestRad IS nd:RADIALOUT.
    LOCAL bestNrm IS nd:NORMAL.
    LOCAL bestScore IS _bplanePlanScore(err0, targetBody, wantInc).
    LOCAL bestPe IS meas0["pe"].
    LOCAL bestPlaneErr IS planeErr0.
    LOCAL entryPeErr IS ABS(meas0["pe"] - wantPe).
    LOCAL entryPlaneErr IS planeErr0.

    FROM { LOCAL i IS 0. } UNTIL i >= MAX_NEWTON_ITER STEP { SET i TO i + 1. } DO {
        IF ABORT { REMOVE nd. RETURN 0. }
        LOCAL meas IS measureArrival(nd, targetBody).
        IF meas = 0 {
            mLogWarn("BPLANE[" + i + "]: lost the encounter — backing off.").
            SET nd:PROGRADE TO nd:PROGRADE * 0.5.
            SET nd:RADIALOUT TO nd:RADIALOUT * 0.5.
            SET nd:NORMAL TO nd:NORMAL * 0.5.
            WAIT 0.02.
        } ELSE {
            LOCAL tgt IS targetBplaneVector(targetBody, meas, wantPe, wantInc, wantLan).
            LOCAL errT IS tgt["bt"] - meas["bt"].
            LOCAL errR IS tgt["br"] - meas["br"].
            LOCAL qT IS meas["bt"] - tgt["bt"].
            LOCAL qR IS meas["br"] - tgt["br"].
            LOCAL corrErr IS _bplaneCorridorError(
                targetBody, meas, wantPe, wantInc, wantLan).
            LOCAL planeErr IS corrErr["planeErr"].
            LOCAL score IS _bplanePlanScore(corrErr, targetBody, wantInc).
            IF score < bestScore {
                SET bestScore TO score.
                SET bestPe TO meas["pe"].
                SET bestPlaneErr TO planeErr.
                SET bestPro TO nd:PROGRADE.
                SET bestRad TO nd:RADIALOUT.
                SET bestNrm TO nd:NORMAL.
            }
            mLog("  BPLANE[" + i + "] dBT=" + ROUND(errT / 1000, 1)
                + "km dBR=" + ROUND(errR / 1000, 1)
                + "km Pe=" + ROUND(meas["pe"] / 1000, 1)
                + "km planeErr=" + ROUND(planeErr, 2)
                + " scoreKm=" + ROUND(score / 1000, 1)
                + " mode=" + planeMode
                + " dv=" + ROUND(nd:DELTAV:MAG, 2)).
            IF i = 0 {
                mLog("STATS bplane-bvec target=" + targetBody:NAME
                    + " measBtKm=" + ROUND(meas["bt"] / 1000,1)
                    + " tgtBtKm=" + ROUND(tgt["bt"] / 1000,1)
                    + " measBrKm=" + ROUND(meas["br"] / 1000,1)
                    + " tgtBrKm=" + ROUND(tgt["br"] / 1000,1)
                    + " measBMagKm=" + ROUND(meas["bMag"] / 1000,1)
                    + " tgtBMagKm=" + ROUND(tgt["bMag"] / 1000,1)
                    + " measDotBT=" + ROUND(meas["dotBT"],6)
                    + " tgtDotBT=" + ROUND(tgt["dotBT"],6)
                    + " measDotBR=" + ROUND(meas["dotBR"],6)
                    + " tgtDotBR=" + ROUND(tgt["dotBR"],6)
                    + " tgtVsMeasBAng=" + ROUND(tgt["bHatAngle"],2)
                    + " tgtSDotB=" + ROUND(tgt["sDotBH"],6)
                    + " tgtHDotB=" + ROUND(tgt["hDotBH"],6)
                    + " measBHatMag=" + ROUND(meas["bHatMag"],5)
                    + " tgtBHatMag=" + ROUND(tgt["bHatMag"],5)
                    + " tHatMag=" + ROUND(meas["tHatMag"],5)
                    + " rHatMag=" + ROUND(meas["rHatMag"],5)).
            }

            IF _bplaneCorridorOk(corrErr, wantInc, peTol, angTol) {
                SET converged TO TRUE.
                BREAK.
            }

            LOCAL p0 IS nd:PROGRADE.
            LOCAL r0 IS nd:RADIALOUT.
            LOCAL n0 IS nd:NORMAL.

            IF planeMode = "pe-only" {
                IF NOT _bplaneFallbackSearch(nd, targetBody,
                        wantPe, wantInc, wantLan, dvCap, score, i, TRUE) {
                    mLogWarn("BPLANE[" + i
                        + "]: no Pe-only fallback step improved arrival; stopping.").
                    BREAK.
                }
                LOCAL poMeas IS measureArrival(nd, targetBody).
                IF poMeas <> 0 {
                    LOCAL poErr IS _bplaneCorridorError(
                        targetBody, poMeas, wantPe, wantInc, wantLan).
                    LOCAL poScore IS _bplanePlanScore(
                        poErr, targetBody, wantInc).
                    IF poScore < bestScore {
                        SET bestScore TO poScore.
                        SET bestPe TO poMeas["pe"].
                        SET bestPlaneErr TO poErr["planeErr"].
                        SET bestPro TO nd:PROGRADE.
                        SET bestRad TO nd:RADIALOUT.
                        SET bestNrm TO nd:NORMAL.
                    }
                    IF _bplaneCorridorOk(poErr, wantInc, peTol, angTol) {
                        SET converged TO TRUE.
                        BREAK.
                    }
                }
            } ELSE {

            LOCAL step IS _bplaneNewtonStep(nd,targetBody,wantPe,wantInc,wantLan,qT,qR).
            IF step:LENGTH = 0 {
                mLogWarn("BPLANE: singular three-axis response; stopping."). BREAK.
            }
            LOCAL dPro IS step[0].
            LOCAL dRad IS step[1].
            LOCAL dNrm IS step[2].

            // Per-step and total caps keep a bad Jacobian from
            // flinging the node into a different patch topology.
            LOCAL stepMag IS SQRT(dPro ^ 2 + dRad ^ 2 + dNrm ^ 2).
            mLog("STATS bplane step minimumNormDv=" + stepMag + " cap=" + dvCap + " axes=3").
            LOCAL stepCap IS MAX(1, dvCap * 0.5).
            IF stepMag > stepCap {
                SET dPro TO dPro * stepCap / stepMag.
                SET dRad TO dRad * stepCap / stepMag.
                SET dNrm TO dNrm * stepCap / stepMag.
            }
            LOCAL accepted IS FALSE.
            LOCAL bestTrialScore IS score.
            FOR frac IN LIST(1.0, 0.5, 0.25, 0.125) {
                SET nd:PROGRADE TO p0 + dPro * frac.
                SET nd:RADIALOUT TO r0 + dRad * frac.
                SET nd:NORMAL TO n0 + dNrm * frac.
                WAIT 0.02.

                IF nd:DELTAV:MAG > dvCap {
                    LOCAL scale IS dvCap / nd:DELTAV:MAG.
                    SET nd:PROGRADE TO nd:PROGRADE * scale.
                    SET nd:RADIALOUT TO nd:RADIALOUT * scale.
                    SET nd:NORMAL TO nd:NORMAL * scale.
                    WAIT 0.02.
                }

                LOCAL trial IS measureArrival(nd, targetBody).
                IF trial <> 0 {
                    LOCAL trialErr IS _bplaneCorridorError(
                        targetBody, trial, wantPe, wantInc, wantLan).
                    LOCAL trialScore IS _bplanePlanScore(trialErr, targetBody, wantInc).
                    IF trialScore < bestTrialScore {
                        SET accepted TO TRUE.
                        SET bestTrialScore TO trialScore.
                        IF trialScore < bestScore {
                            SET bestScore TO trialScore.
                            SET bestPe TO trial["pe"].
                            SET bestPlaneErr TO trialErr["planeErr"].
                            SET bestPro TO nd:PROGRADE.
                            SET bestRad TO nd:RADIALOUT.
                            SET bestNrm TO nd:NORMAL.
                        }
                        mLog("  BPLANE[" + i + "] accepted frac="
                            + ROUND(frac,3)
                            + " PeKm=" + ROUND(trial["pe"] / 1000,1)
                            + " planeErr=" + ROUND(trialErr["planeErr"],2)
                            + " scoreKm=" + ROUND(trialScore / 1000,1)
                            + " dv=" + ROUND(nd:DELTAV:MAG,2)).
                        BREAK.
                    }
                }
            }

            IF NOT accepted {
                SET nd:PROGRADE TO p0.
                SET nd:RADIALOUT TO r0.
                SET nd:NORMAL TO n0.
                WAIT 0.02.
                IF NOT _bplaneFallbackSearch(nd, targetBody,
                        wantPe, wantInc, wantLan, dvCap, score, i, FALSE) {
                    mLogWarn("BPLANE[" + i
                        + "]: no damped B-plane or fallback step improved Pe/plane score; stopping.").
                    BREAK.
                } ELSE {
                    LOCAL fbMeas IS measureArrival(nd, targetBody).
                    IF fbMeas <> 0 {
                        LOCAL fbErr IS _bplaneCorridorError(
                            targetBody, fbMeas, wantPe, wantInc, wantLan).
                        LOCAL fbScore IS _bplanePlanScore(
                            fbErr, targetBody, wantInc).
                        IF fbScore < bestScore {
                            SET bestScore TO fbScore.
                            SET bestPe TO fbMeas["pe"].
                            SET bestPlaneErr TO fbErr["planeErr"].
                            SET bestPro TO nd:PROGRADE.
                            SET bestRad TO nd:RADIALOUT.
                            SET bestNrm TO nd:NORMAL.
                        }
                        IF _bplaneCorridorOk(fbErr, wantInc, peTol, angTol) {
                            SET converged TO TRUE.
                            BREAK.
                        }
                    }
                }
            }
            }
        }
    }

    SET nd:PROGRADE TO bestPro.
    SET nd:RADIALOUT TO bestRad.
    SET nd:NORMAL TO bestNrm.
    WAIT 0.02.

    LOCAL measF IS measureArrival(nd, targetBody).
    LOCAL finalPe IS -1.
    LOCAL finalPlaneErr IS -1.
    LOCAL finalOffPlane IS -1.
    IF measF <> 0 {
        SET finalPe TO measF["pe"].
        LOCAL errF IS _bplaneCorridorError(
            targetBody, measF, wantPe, wantInc, wantLan).
        SET finalPlaneErr TO errF["planeErr"].
        SET finalOffPlane TO errF["target"]["offPlane"].
        IF _bplaneCorridorOk(errF, wantInc, peTol, angTol) {
            SET converged TO TRUE.
        }
    }

    IF measF <> 0 AND wantInc >= 0
            AND ABS(finalPe - wantPe) > entryPeErr
            AND finalPlaneErr > entryPlaneErr {
        mLogWarn("BPLANE: planned correction worsened both Pe and plane "
            + "relative to entry; removing node.").
        REMOVE nd.
        RETURN 0.
    }

    mLog("STATS bplane plan target=" + targetBody:NAME
        + " mode=" + planeMode
        + " converged=" + converged
        + " dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " PeKm=" + ROUND(finalPe / 1000, 1)
        + " planeErr=" + ROUND(finalPlaneErr, 2)
        + " offPlane=" + ROUND(finalOffPlane, 2)
        + " bestPeKm=" + ROUND(bestPe / 1000, 1)
        + " bestPlaneErr=" + ROUND(bestPlaneErr, 2)
        + " wantPeKm=" + ROUND(wantPe / 1000, 1)).

    IF NOT converged AND NOT acquired {
        IF BPLANE_REVIEW_UNCONVERGED <> 0 {
            _bplaneOfferReview(nd, targetBody, dvCap).
            RETURN 0.
        }
        IF allowMidcourseRetry {
            // Early failures use the normal midpoint pair. Later failures
            // signal the resident wrapper to wait and solve again.
            REMOVE nd.
            WAIT 0.02.
            IF _bplaneQueueMidcourseRetry("unconverged-optional-correction") { RETURN 0. }
            RETURN -1.
        }
        _bplaneHoldCorrection("unconverged-optional-correction").
        RETURN 0.
    }

    IF NOT converged AND measF = 0 {
        mLogWarn("BPLANE: solver failed and encounter lost — removing node.").
        REMOVE nd.
        RETURN 0.
    }
    RETURN nd.
}

LOCAL FUNCTION _bplaneTargetBody {
    LOCAL targetName IS "".
    IF BPLANE_TARGET <> "" { SET targetName TO BPLANE_TARGET. }
    IF targetName = "" { SET targetName TO getTarget(""). }

    LOCAL targetBody IS 0.
    LOCAL allBodies IS LIST().
    LIST BODIES IN allBodies.
    FOR bod IN allBodies {
        IF bod:NAME = targetName { SET targetBody TO bod. }
    }
    RETURN targetBody.
}

LOCAL FUNCTION _bplaneWantInc {
    IF BPLANE_PE_ONLY <> 0 AND BPLANE_REQUIRE_PLANE = 0 { RETURN -1. }
    LOCAL wantInc IS -1.
    IF CAPTURE_DIR <> "" {
        LOCAL dir IS CAPTURE_DIR.
        IF dir = "PROGRADE"   { SET wantInc TO 0. }
        IF dir = "POLAR"      { SET wantInc TO 90. }
        IF dir = "RETROPOLAR" { SET wantInc TO 90. }
        IF dir = "RETROGRADE" { SET wantInc TO 180. }
    }
    IF CAPTURE_INC >= 0 { SET wantInc TO CAPTURE_INC. }
    RETURN wantInc.
}

LOCAL FUNCTION _bplaneExistingNodeAcceptable {
    PARAMETER targetBody.
    PARAMETER wantPe.
    PARAMETER wantInc.
    PARAMETER wantLan.
    PARAMETER phaseCap.
    PARAMETER missionOwned IS FALSE.

    IF NOT HASNODE { RETURN FALSE. }

    IF BPLANE_PE_ONLY <> 0 {
        // Replan a saved node under the new Pe-only recovery objective.
        RETURN FALSE.
    }

    LOCAL nd IS NEXTNODE.
    mLog("STATS bplane resume existing-node dv="
        + ROUND(nd:DELTAV:MAG, 2)
        + " eta=" + ROUND(nd:ETA, 1)
        + " body=" + SHIP:BODY:NAME).

    IF nd:ETA < BPLANE_EXISTING_NODE_MIN_ETA {
        mLogWarn("BPLANE: existing node is too close for automatic reuse (ETA="
            + ROUND(nd:ETA, 1) + "s; min="
            + ROUND(BPLANE_EXISTING_NODE_MIN_ETA, 1) + "s).").
        RETURN FALSE.
    }

    IF NOT _bplaneCorrectionAboveMinimum(nd) { RETURN FALSE. }

    IF NOT bplaneCorrectionAllowed(nd, targetBody, phaseCap,TRUE,missionOwned) { RETURN FALSE. }

    bplaneResetWarnings().
    LOCAL meas IS measureArrival(nd, targetBody).
    IF meas = 0 {
        mLogWarn("BPLANE: existing node does not produce a measurable "
            + targetBody:NAME + " arrival; replanning.").
        RETURN FALSE.
    }

    LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
    mLog("STATS bplane existing-node target=" + targetBody:NAME
        + " dv=" + ROUND(nd:DELTAV:MAG, 2)
        + " eta=" + ROUND(nd:ETA, 1)
        + " PeKm=" + ROUND(meas["pe"] / 1000, 1)
        + " planeErr=" + ROUND(err["planeErr"], 2)
        + " wantPeKm=" + ROUND(wantPe / 1000, 1)).

    IF _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
        mLog("BPLANE: reusing existing correction node; arrival is already "
            + "inside corridor.").
        RETURN TRUE.
    }

    mLogWarn("BPLANE: existing correction node misses requested corridor; replanning.").
    RETURN FALSE.
}

// ============================================================
// phaseBplane — phase handler. Resolves the arrival body and
// requested capture elements from globals/state, then runs up to
// MAX_BURNS correction burns. It holds the phase if the arrival
// is still outside the corridor; CAPTURE cannot fix a bad Pe/plane.
// ============================================================
GLOBAL FUNCTION phaseBplane {
    IF maneuverBurnInterrupted() {
        IF _bplaneRecoverStoppedTrim() { RETURN. }
        _bplaneHoldCorrection("interrupted-correction-use-arrival-replan"). RETURN.
    }
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 {
        mLogWarn("BPLANE: target '" + getTarget("")
            + "' is not a body — nothing to do.").
        nextPhase(xferSeq).
        RETURN.
    }

    // Resume safety: a reboot can land us here after the SOI
    // transition already happened. Nothing left to correct.
    _bplaneEnsureSoiAlarm(targetBody).
    IF bplanePauseForReview() { RETURN. }
    IF _bplaneHandoffMidcourseRetry(targetBody) { RETURN. }
    IF SHIP:BODY = targetBody {
        mLog("BPLANE: already inside " + targetBody:NAME + " SOI — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }
    IF NOT _bplaneCoastOutOfDepartureSoi(targetBody) { RETURN. }
    IF SHIP:BODY = targetBody {
        mLog("BPLANE: entered " + targetBody:NAME
            + " SOI during departure coast — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL wantPe IS CAPTURE_PE.
    IF wantPe < 0 {
        mLogWarn("BPLANE: CAPTURE_PE not set — skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }
    LOCAL wantInc IS _bplaneWantInc().

    LOCAL wantLan IS CAPTURE_LAN.
    IF BPLANE_PE_ONLY <> 0 { SET wantLan TO -1. }
    bplaneResetWarnings().
    _bplaneLogBaseline(targetBody, BPLANE_DV_CAP).

    IF _bplaneDeferPeToMidcourse(targetBody, wantPe) {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        _bplaneClearCoastTimes().
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL burns IS 0.
    UNTIL burns >= MAX_BURNS {
        IF _bplaneCurrentCorridorOk(targetBody, wantPe, wantInc, wantLan) {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            mLog("STATS bplane result status=already-in-corridor burns=" + burns).
            nextPhase(xferSeq).
            RETURN.
        }
        IF burns = 0 AND NOT HASNODE {
            LOCAL wakeMeas IS measureArrival(0, targetBody).
            IF wakeMeas <> 0 {
                LOCAL wakeErr IS _bplaneCorridorError(targetBody, wakeMeas, wantPe, wantInc, wantLan).
                mLog("STATS bplane wake initialPeKm="
                    + ROUND(wakeMeas["pe"] / 1000, 1)
                    + "km planeErr=" + ROUND(wakeErr["planeErr"], 2)
                    + "deg inc=" + ROUND(wakeMeas["inc"], 2)
                    + " lan=" + ROUND(wakeMeas["lan"], 2) + ".").
            } ELSE {
                mLog("BPLANE wake: no measurable arrival patch yet; planner will acquire if possible.").
            }
        }
        LOCAL nd IS 0.
        IF _bplaneExistingNodeAcceptable(targetBody, wantPe, wantInc, wantLan, BPLANE_DV_CAP,TRUE) {
            SET nd TO NEXTNODE.
        } ELSE {
            IF phaseShouldYield OR ABORT { RETURN. }
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            SET nd TO planBplaneCorrection(targetBody, wantPe, wantInc, wantLan,-1,"",TRUE).
        }
        IF phaseShouldYield OR ABORT { RETURN. }
        IF _bplaneHandoffMidcourseRetry(targetBody) { RETURN. }
        IF nd = 0 AND _bplaneFinishMinimumSkip(targetBody,wantPe,wantInc,wantLan) { RETURN. }
        IF nd = 0 { BREAK. }
        IF NOT bplaneCorrectionAllowed(nd, targetBody, BPLANE_DV_CAP,TRUE,TRUE) { RETURN. }
        _bplaneReserveCorrection(nd, targetBody).
        _bplaneClearCoastTimes().
        SET burns TO burns + 1.
        LOCAL executed IS _bplaneExecuteCorrection().
        _bplaneEnsureSoiAlarm(targetBody).
        IF NOT executed {
            IF _bplaneRecoverStoppedTrim() { RETURN. }
            bplaneArrivalStatus().
            _bplaneHoldCorrection("correction-execution-failed"). RETURN.
        }
        WAIT 2.
    }

    IF BPLANE_PE_ONLY <> 0 {
        _bplaneFinishPeRecovery(targetBody, wantPe). RETURN.
    }
    LOCAL meas IS measureArrival(0, targetBody).
    IF meas = 0 {
        mLogError("BPLANE: finished with NO encounter — operator attention needed.").
        _bplaneHoldCorrection("finished-without-encounter",TRUE).
        RETURN.
    }
    LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
    IF NOT _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
        IF _bplaneSafeEncounter(targetBody, meas) {
            mLogWarn("BPLANE: arrival outside requested corridor but inside "
                + targetBody:NAME + " SOI; handing off to refinement/capture. "
                + "Pe=" + ROUND(meas["pe"] / 1000, 1)
                + "km planeErr=" + ROUND(err["planeErr"], 2) + "deg.").
            mLog("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
                + " inc=" + ROUND(meas["inc"], 2)
                + " lan=" + ROUND(meas["lan"], 2)
                + " planeErr=" + ROUND(err["planeErr"], 2)
                + " burns=" + burns
                + " status=safe-handoff").
            nextPhase(xferSeq).
            RETURN.
        }
        mLogError("BPLANE: failed to reach arrival corridor; holding phase. "
            + "Pe=" + ROUND(meas["pe"] / 1000, 1)
            + "km want=" + ROUND(wantPe / 1000, 1)
            + "km planeErr=" + ROUND(err["planeErr"], 2)
            + "deg. Replan XING or raise BPLANE_DV_CAP.").
        mLog("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
            + " inc=" + ROUND(meas["inc"], 2)
            + " lan=" + ROUND(meas["lan"], 2)
            + " planeErr=" + ROUND(err["planeErr"], 2)
            + " burns=" + burns
            + " status=failed-corridor").
        _bplaneHoldCorrection("finished-outside-required-corridor",TRUE).
        RETURN.
    }
    mLog("BPLANE done: Pe=" + ROUND(meas["pe"] / 1000, 1)
        + "km inc=" + ROUND(meas["inc"], 2)
        + " lan=" + ROUND(meas["lan"], 2)
        + " after " + burns + " burn(s).").
    mLog("STATS bplane result PeKm=" + ROUND(meas["pe"] / 1000, 1)
        + " inc=" + ROUND(meas["inc"], 2)
        + " lan=" + ROUND(meas["lan"], 2)
        + " burns=" + burns).
    nextPhase(xferSeq).
}

// Optional provider is loaded only by the enabled interplanetary band.
LOCAL FUNCTION _bplanePreviewMidcourse {
    PARAMETER targetBody.
    PARAMETER nd.
    PARAMETER checkOnly IS FALSE.
    IF DEFINED ASSIST_HAS_MIDCOURSE_PREVIEW {
        RETURN previewMidcourseAssist(targetBody,nd,checkOnly).
    }
    RETURN TRUE.
}

GLOBAL FUNCTION phaseRefineBplane {
    IF maneuverBurnInterrupted() {
        _bplaneHoldCorrection("interrupted-correction-use-arrival-replan"). RETURN.
    }
    LOCAL targetBody IS _bplaneTargetBody().
    IF targetBody = 0 {
        mLogWarn("REFINE_BPLANE: target '" + getTarget("")
            + "' is not a body — nothing to do.").
        nextPhase(xferSeq).
        RETURN.
    }

    IF NOT _bplanePreviewMidcourse(targetBody,0,TRUE) { RETURN. }
    _bplaneEnsureSoiAlarm(targetBody).
    IF bplanePauseForReview() { RETURN. }
    IF SHIP:BODY = targetBody {
        mLog("REFINE_BPLANE: already inside " + targetBody:NAME + " SOI; skipping.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL wantPe IS CAPTURE_PE.
    IF wantPe < 0 {
        mLogWarn("REFINE_BPLANE: CAPTURE_PE not set — skipping phase.").
        nextPhase(xferSeq).
        RETURN.
    }
    LOCAL wantInc IS _bplaneWantInc().
    LOCAL wantLan IS CAPTURE_LAN.
    IF BPLANE_PE_ONLY <> 0 { SET wantLan TO -1. }

    LOCAL dvCap IS MAX(MIN_EXEC_DV, REFINE_BPLANE_DV_CAP).
    _bplaneLogBaseline(targetBody, dvCap).
    LOCAL maxBurns IS MAX(1, REFINE_BPLANE_MAX_BURNS).
    LOCAL burns IS 0.
    UNTIL burns >= maxBurns {
        IF _bplaneCurrentCorridorOk(targetBody, wantPe, wantInc, wantLan) {
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            IF NOT _bplanePreviewMidcourse(targetBody,0) { RETURN. }
            // Search/report I/O yields; never advance on the old measurement.
            IF _bplaneCurrentCorridorOk(targetBody, wantPe, wantInc, wantLan) {
                mLog("STATS refine-bplane result status=already-in-corridor burns=" + burns).
                nextPhase(xferSeq).
                RETURN.
            }
        }
        IF NOT HASNODE AND BPLANE_PE_ONLY = 0 {
            LOCAL measLoop IS measureArrival(0, targetBody).
            IF measLoop = 0 { BREAK. }
            LOCAL errLoop IS _bplaneCorridorError(targetBody, measLoop, wantPe, wantInc, wantLan).
            IF _bplaneCorridorOk(errLoop, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
                IF NOT _bplanePreviewMidcourse(targetBody,0) { RETURN. }
                BREAK.
            }
        }

        LOCAL nd IS 0.
        IF _bplaneExistingNodeAcceptable(targetBody, wantPe, wantInc, wantLan, dvCap,TRUE) {
            SET nd TO NEXTNODE.
        } ELSE {
            IF phaseShouldYield OR ABORT { RETURN. }
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            mLog("REFINE_BPLANE: refining arrival with dV cap "
                + dvCap + " m/s.").
            SET nd TO planBplaneCorrection(
                targetBody,
                wantPe,
                wantInc,
                wantLan,
                dvCap,
                "Trajectory pristine, skipping refinement burn.",TRUE).
        }

        IF phaseShouldYield OR ABORT { RETURN. }
        IF nd = 0 {
            IF _bplaneMinimumSkip["ACCEPTED"] {
                IF NOT _bplanePreviewMidcourse(targetBody,0) { RETURN. }
            }
            IF _bplaneFinishMinimumSkip(targetBody,wantPe,wantInc,wantLan) { RETURN. }
        }
        IF nd = 0 { BREAK. }
        IF NOT _bplanePreviewMidcourse(targetBody,nd) { RETURN. }
        IF NOT bplaneCorrectionAllowed(nd, targetBody, dvCap,TRUE,TRUE) { RETURN. }
        _bplaneReserveCorrection(nd, targetBody).
        _bplaneClearCoastTimes().
        SET burns TO burns + 1.
        LOCAL executed IS _bplaneExecuteCorrection().
        _bplaneEnsureSoiAlarm(targetBody).
        IF NOT executed {
            bplaneArrivalStatus().
            _bplaneHoldCorrection("correction-execution-failed"). RETURN.
        }
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        WAIT 2.
    }

    IF BPLANE_PE_ONLY <> 0 {
        _bplaneFinishPeRecovery(targetBody, wantPe). RETURN.
    }
    LOCAL meas IS measureArrival(0, targetBody).
    IF meas <> 0 {
        LOCAL err IS _bplaneCorridorError(targetBody, meas, wantPe, wantInc, wantLan).
        IF NOT _bplaneCorridorOk(err, wantInc, BPLANE_PE_TOL, BPLANE_ANG_TOL) {
            IF _bplaneSafeEncounter(targetBody, meas) {
                mLogWarn("REFINE_BPLANE: arrival outside requested corridor "
                    + "but inside " + targetBody:NAME
                    + " SOI; handing off. Pe="
                    + ROUND(meas["pe"] / 1000, 1)
                    + "km planeErr=" + ROUND(err["planeErr"], 2)
                    + "deg burns=" + burns + "/" + maxBurns + ".").
                mLog("STATS refine-bplane result PeKm="
                    + ROUND(meas["pe"] / 1000, 1)
                    + " inc=" + ROUND(meas["inc"], 2)
                    + " lan=" + ROUND(meas["lan"], 2)
                    + " planeErr=" + ROUND(err["planeErr"], 2)
                    + " burns=" + burns
                    + " status=safe-handoff").
                nextPhase(xferSeq).
                RETURN.
            }
            mLogError("REFINE_BPLANE: arrival still outside corridor; holding before capture. "
                + "Pe=" + ROUND(meas["pe"] / 1000, 1)
                + "km want=" + ROUND(wantPe / 1000, 1)
                + "km planeErr=" + ROUND(err["planeErr"], 2)
                + "deg burns=" + burns + "/" + maxBurns + ".").
            _bplaneHoldCorrection("finished-outside-required-corridor",TRUE).
            RETURN.
        }
        mLog("REFINE_BPLANE done: Pe=" + ROUND(meas["pe"] / 1000, 1)
            + "km inc=" + ROUND(meas["inc"], 2)
            + " lan=" + ROUND(meas["lan"], 2)
            + " after " + burns + " burn(s).").
    } ELSE {
        mLogWarn("REFINE_BPLANE: no encounter measurement after refinement.").
        _bplaneHoldCorrection("finished-without-encounter",TRUE).
        RETURN.
    }
    nextPhase(xferSeq).
}
