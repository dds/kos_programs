// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL BURN_BRIEF IS 1.
GLOBAL BURN_ART IS 1.
GLOBAL BURN_ALIGN_GUARD_DEG IS 20.
GLOBAL BURN_ALIGN_REACQUIRE_DEG IS 5.
GLOBAL BURN_ALIGN_DEBOUNCE IS 0.5.
GLOBAL BURN_ALIGN_REACQUIRE_TIMEOUT IS 10.
GLOBAL BURN_BV_SLEW_MAX_DEG_PER_S IS 60.
GLOBAL BURN_BV_SLEW_MIN_DV IS 20.
GLOBAL BURN_BV_MIN_MAG IS 0.001.
GLOBAL BURN_TUMBLE_AV_MIN IS 0.5.
GLOBAL BURN_TRIM_COMPLETE_FRAC IS 0.98.
GLOBAL BURN_TRIM_COMPLETE_MAX_DV IS 0.05.
GLOBAL BURN_TRIM_ABS_COMPLETE_DV IS 0.05.
GLOBAL BURN_FIXED_NODE_MAX_DV IS 50.
GLOBAL BURN_FIXED_NODE_MIN_ECC IS 0.9.
GLOBAL BURN_NODE_REBOUND_EPS IS 0.5.
GLOBAL BURN_NODE_FLIP_DEG IS 90.
GLOBAL BURN_NODE_FLIP_REMAINING_DV IS 20.
GLOBAL BURN_TICK_LOG_INTERVAL IS 1.0.
GLOBAL BURN_MIN_FULL_THRUST_SECONDS IS 2.
GLOBAL BURN_STAGE_TIMEOUT IS 10.
GLOBAL BURN_STAGE_SETTLE IS 0.5.
GLOBAL BURN_STAGE_MAX_EVENTS IS 4.
GLOBAL BURN_STAGE_LIMIT IS 0.
GLOBAL BURN_STAGE_MANUAL_WAIT IS 120.
GLOBAL BURN_RESUME_REQUESTED IS FALSE.
// Independent limits: do not trust a maneuver residual as the sole cutoff.
GLOBAL BURN_IMPULSE_MARGIN_FRAC IS 0.01.
GLOBAL BURN_IMPULSE_MARGIN_DV IS 0.05.
GLOBAL BURN_COMMAND_TIMEOUT IS 1.
GLOBAL BURN_CUTOFF_VERIFY_TIME IS 0.25.
// Cooked-control callbacks have priority over the main loop. At kOS's
// default 150 IPU, this governor can consume the available instruction
// budget even with command=0, starving the code that publishes ignition.
GLOBAL BURN_MIN_IPU IS 2000.


LOCAL ATOL      IS 2.0.
LOCAL CRT IS 300.
LOCAL CRL  IS 180.

LOCAL FUNCTION _burnCoastSolar {
    PARAMETER deadlineUt.
    IF NOT PHASES_HAS_SOLAR OR ABORT
            OR NOT (deadlineUt > TIME:SECONDS AND deadlineUt < 1e30)
            OR NOT (SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
                AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
        RETURN FALSE.
    }
    LOCAL parkedDeparture IS FALSE.
    IF stateGet("phase","") = "XING" AND SHIP:STATUS = "ORBITING" {
        LOCAL floorAlt IS 0.
        IF SHIP:BODY:ATM:EXISTS { SET floorAlt TO SHIP:BODY:ATM:HEIGHT. }
        SET parkedDeparture TO SHIP:PERIAPSIS > floorAlt
            AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
            AND NOT SHIP:ORBIT:HASNEXTPATCH.
    }
    // A verified parking orbit needs no launch-age delay. Reuse the panel
    // axis first; the deadline preserves the maneuver's realignment window.
    LOCAL aimed IS orientForSolar(FALSE,TRUE,parkedDeparture,deadlineUt).
    mLog("STATS burn solar phase=" + stateGet("phase","") + " aimed=" + aimed
        + " parkedDeparture=" + parkedDeparture + " deadlineUt=" + deadlineUt).
    RETURN aimed.
}

GLOBAL FUNCTION executeManeuver {
    LOCAL resumeRequested IS BURN_RESUME_REQUESTED.
    SET BURN_RESUME_REQUESTED TO FALSE.
    // A throttle lock does not clear the pilot setting it overrides.
    // Clear both before any wait, including missed-window/abort exits.
    LOCK THROTTLE TO 0.0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    WAIT 0.1.
    IF NOT HASNODE {
        mLogError("executeManeuver: no node on flight plan.").
        HUDTEXT("ERROR: No maneuver node!", 5, 2, 18, RED, FALSE).
        RETURN FALSE.
    }

    LOCAL nd    IS NEXTNODE.
    LOCAL ntm IS nd:TIME.
    LOCAL bdv  IS nd:DELTAV:MAG.
    LOCAL resuming IS maneuverBurnInterrupted().
    IF ABORT { RETURN FALSE. }
    IF resuming {
        IF NOT resumeRequested {
            mLogError("Interrupted burn retained; use cmd/resumeburn.ks after inspecting the remaining node.").
            RETURN FALSE.
        }
        IF ABS(ntm - stateGetNum("burn_node_time", -1)) >= 0.5
                OR stateGet("burn_body", SHIP:BODY:NAME) <> SHIP:BODY:NAME
                OR NOT _nf(bdv) OR NOT _bvo(nd:BURNVECTOR) {
            mLogError("Cannot resume: remaining node/body does not match the interrupted burn, or its vector is invalid.").
            RETURN FALSE.
        }
    }
    IF bdv <= BURN_TRIM_ABS_COMPLETE_DV {
        _ren(ntm).
        _cpb("already-complete").
        mLog("Maneuver already below absolute dV tolerance; skipping burn.").
        RETURN TRUE.
    }
    LOCAL thrustScale IS _burnLimitThrust(bdv).
    // Estimate the centered start with the thrust limits actually used.
    WAIT 0.1.
    LOCAL st IS TIME:SECONDS.
    IF NOT resuming {
        SET st TO _cst(nd).
        _mpb(nd, bdv, st).
    }

    IF NOT resuming AND st < TIME:SECONDS {
        mLogWarn("Burn window already passed by " + ROUND(TIME:SECONDS - st, 0) + "s — removing node.").
        HUDTEXT("Burn window missed — replanning", 5, 2, 15, YELLOW, FALSE).
        REMOVE nd.
        _stl(1.0).
        _cpb("missed-window").
        RETURN FALSE.
    }

    IF NOT resuming { _rmb(nd). }

    mLog("Maneuver: dV=" + ROUND(bdv,3) + " m/s  ETA=" + ROUND(st - TIME:SECONDS,1) + "s").
    mLog("STATS burn setup dv=" + ROUND(bdv,4)
        + " eta=" + ROUND(st - TIME:SECONDS,1)
        + " nodeEta=" + ROUND(nd:ETA,1)
        + " body=" + SHIP:BODY:NAME
        + " thrustScale=" + ROUND(thrustScale,6)
        + " maxAcc=" + ROUND(_sma(),2)).
    IF _sma() <= 0 {
        mLog("STATS burn thrust status=no-thrust maxThrust="
            + ROUND(SHIP:MAXTHRUST,1)
            + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).
    }

    LOCAL aid IS "".
    IF resuming {
        // Explicit operator continuation uses the LIVE residual now, not
        // the original (already passed) centered ignition time.
        SET WARP TO 0.
        SET SAS TO FALSE.
        LOCK STEERING TO nd:BURNVECTOR.
        mLogWarn("Resuming retained maneuver now: remaining=" + ROUND(bdv, 2) + "m/s.").
        LOCAL resumeDeadline IS TIME:SECONDS + BURN_ALIGN_REACQUIRE_TIMEOUT.
        WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ATOL
            OR TIME:SECONDS >= resumeDeadline OR ABORT.
        IF ABORT { RETURN FALSE. }
    } ELSE {
        SET aid TO maneuverEnsureBurnAlarm(st, bdv, "Burn").

        // Imminent burn: clear any player warp first. If the burn is
        // still far enough from the T-60 KAC alarm, the guarded approach
        // auto-warp below can restart at an appropriate low rate.
        IF st - TIME:SECONDS < CRT {
            SET WARP TO 0.
        }

        SET SAS TO FALSE.
        WAIT 0.1.
        LOCK STEERING TO nd:BURNVECTOR.
        mLog("Aligning to burn vector...").

        LOCAL rt IS st - CRL.
        IF TIME:SECONDS < rt - CRT {
            // Spend the long coast sun-pointed for power; the checkpoint
            // re-locks below reacquire the burn vector before ignition.
            // XING brings solar; other bands can still shed that library.
            _burnCoastSolar(rt).
            mLog("Long coast wait (" + ROUND(rt - TIME:SECONDS, 0) + "s).").
            HUDTEXT("Coasting. Burn in " + ROUND(st - TIME:SECONDS, 0) + "s", 5, 2, 13, CYAN, FALSE).
            coastAutoWarp(rt, "Burn coast", aid).
            LOCAL sr IS -1.
            UNTIL TIME:SECONDS >= rt {
                SET sr TO trySolarHoldTick(sr,rt).
                WAIT MIN(10, MAX(0.5, rt - TIME:SECONDS)).
            }
            SET WARP TO 0.
            SET SAS TO FALSE.
            WAIT 0.1.
            LOCK STEERING TO nd:BURNVECTOR.
            mLog("Re-aligning — " + ROUND(st - TIME:SECONDS, 0) + "s to burn.").
            HUDTEXT("Re-aligning. Burn in " + ROUND(st - TIME:SECONDS, 0) + "s", 5, 2, 13, GREEN, FALSE).
        }

        LOCAL apt IS st - 60.
        IF TIME:SECONDS < apt {
            coastAutoWarp(apt, "Burn approach", aid).
        }
        WAIT UNTIL TIME:SECONDS >= apt.
        mLog("Burn in T-60").
        LOCK STEERING TO nd:BURNVECTOR.
        mLog("STATS burn relock checkpoint=T-60 angle="
            + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR), 1)
            + " timeToBurn=" + ROUND(st - TIME:SECONDS, 1)).

        LOCAL adl IS st - 5.
        LOCAL t10 IS st - 10.
        UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ATOL
                OR TIME:SECONDS >= t10 {
            LOCK STEERING TO nd:BURNVECTOR.
            WAIT 0.1.
        }
        IF TIME:SECONDS < t10 { WAIT UNTIL TIME:SECONDS >= t10. }
        LOCK STEERING TO nd:BURNVECTOR.
        mLog("STATS burn relock checkpoint=T-10 angle="
            + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR), 1)
            + " timeToBurn=" + ROUND(st - TIME:SECONDS, 1)).

        UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < ATOL
                OR TIME:SECONDS >= adl {
            LOCK STEERING TO nd:BURNVECTOR.
            WAIT 0.1.
        }

        LOCAL ae IS VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR).
        mLog("STATS burn align angle=" + ROUND(ae,1)
            + " tol=" + ATOL
            + " timeToBurn=" + ROUND(st - TIME:SECONDS,1)).
        IF ae >= ATOL {
            mLogWarn("Burn starting with " + ROUND(ae,1) + "° misalignment.").
        } ELSE {
            mLog("Aligned. Waiting for burn window...").
        }

        WAIT UNTIL TIME:SECONDS >= adl.
        HUDTEXT("Burn in T-4", 3, 2, 15, WHITE, FALSE).
        countdown(4).

        WAIT UNTIL TIME:SECONDS >= st.
        LOCK STEERING TO nd:BURNVECTOR.
        mLog("STATS burn relock checkpoint=T-0 angle="
            + ROUND(VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR), 1)
            + " timeToBurn=" + ROUND(st - TIME:SECONDS, 1)
            + " remainingDv=" + ROUND(nd:DELTAV:MAG, 4)
            + " setupDv=" + ROUND(bdv, 4)
            + " angularRate=" + ROUND(SHIP:ANGULARVEL:MAG, 4)).
    }
    LOCAL ie IS VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR).
    IF ie > 15 {
        mLogError("Refusing burn: " + ROUND(ie, 1)
            + " deg off the burn vector at ignition.").
        LOCK THROTTLE TO 0.
        SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        _stl(1.0).
        SET SAS TO FALSE.
        RETURN FALSE.
    }
    mLog("Burn start. dV=" + ROUND(bdv,3) + " m/s remaining=" + ROUND(nd:DELTAV:MAG,4)).
    stateSet("burn_status", "burning").
    // Persist before ignition so a reboot cannot turn a partially flown
    // departure into a fresh parking-orbit transfer plan.
    stateSet("burn_started", "true").
    // Survive a save after cutoff/cleanup but before XING advances phase.
    // Ordinary burn cleanup must not erase the fact that departure flew.
    IF stateGet("phase", "") = "XING" {
        stateSet("burn_departure_target", getTarget("")).
        stateSet("burn_departure_time", TIME:SECONDS).
    }
    LOCAL bsc IS TIME:SECONDS.

    LOCAL steerVec IS nd:BURNVECTOR.
    LOCAL ignitionVec IS steerVec.
    LOCAL prevBV IS steerVec.
    LOCAL prevBVTime IS TIME:SECONDS.
    LOCAL fixedBurnVector IS bdv <= BURN_FIXED_NODE_MAX_DV
            AND SHIP:ORBIT:ECCENTRICITY >= BURN_FIXED_NODE_MIN_ECC.
    IF fixedBurnVector {
        mLogWarn("Burn using fixed ignition vector: dv=" + ROUND(bdv,2)
            + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4) + ".").
    }
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000, BURN_MIN_IPU) {
        // Persist before changing the game setting. bootPreamble restores
        // it after a power loss/error, before a retry can clear burn_*.
        stateSet("burn_prior_ipu", priorIpu).
        SET CONFIG:IPU TO MIN(2000, BURN_MIN_IPU).
    }
    mLog("STATS burn cpu previousIpu=" + priorIpu + " burnIpu=" + CONFIG:IPU).
    LOCAL throttleCmd IS 0.0.
    LOCAL liveCutoff IS LEX("reason", "", "rem", -1, "time", 0,
        "lastTick", TIME:SECONDS, "tickDt", 0.02, "output", 0,
        "bestRem", -1, "fixed", fixedBurnVector,
        "heartbeat", TIME:SECONDS, "impulseTime", TIME:SECONDS,
        "impulse", 0, "lastAcc", SHIP:THRUST / MAX(0.01, SHIP:MASS),
        "impulseCap", bdv + MAX(BURN_IMPULSE_MARGIN_DV, bdv * BURN_IMPULSE_MARGIN_FRAC)).
    LOCAL burnTrace IS LIST().
    LOCK STEERING TO steerVec.
    // Both modes get independent impulse, stale-command and ABORT limits.
    LOCK THROTTLE TO _burnNodeThrottle(nd, ignitionVec, throttleCmd, liveCutoff).
    LOCAL db2 IS FALSE.
    LOCAL dra IS FALSE.
    LOCAL burnAbort IS "".
    LOCAL burnAbortDetail IS "".
    LOCAL alignOverStart IS -1.
    LOCAL nextTickLog IS TIME:SECONDS.
    LOCAL pauseCount IS 0.
    LOCAL totalPaused IS 0.
    LOCAL burnDone IS FALSE.
    LOCAL burnCompleteReason IS "normal".
    LOCAL appliedDv IS 0.
    LOCAL lastDvTime IS TIME:SECONDS.
    LOCAL prevVel IS SHIP:VELOCITY:ORBIT.
    LOCAL prevGravity IS _gacc().
    LOCAL lastNodeRem IS nd:DELTAV:MAG.
    LOCAL nodeUnstableLogged IS FALSE.

    UNTIL burnDone OR burnAbort <> "" {
        IF ABORT {
            SET throttleCmd TO 0.0.
            SET burnAbort TO "operator-abort".
            SET burnAbortDetail TO "Operator aborted the maneuver.".
            BREAK.
        }
        LOCAL now IS TIME:SECONDS.
        LOCAL dt IS MAX(0, now - lastDvTime).
        LOCAL curVel IS SHIP:VELOCITY:ORBIT.
        LOCAL curGravity IS _gacc().
        IF throttleCmd > 0 AND dt > 0 {
            LOCAL thrustDvVec IS curVel - prevVel
                - ((prevGravity + curGravity) * (0.5 * dt)).
            LOCAL stepDv IS VDOT(thrustDvVec, steerVec:NORMALIZED).
            SET appliedDv TO MAX(0, appliedDv + stepDv).
        }
        SET lastDvTime TO now.
        SET prevVel TO curVel.
        SET prevGravity TO curGravity.
        LOCAL remNow IS nd:DELTAV:MAG.
        LOCAL intRem IS MAX(0, bdv - appliedDv).
        LOCAL avNow IS SHIP:ANGULARVEL:MAG.
        IF liveCutoff["reason"] <> "" {
            SET throttleCmd TO 0.0.
            SET burnCompleteReason TO liveCutoff["reason"].
            SET burnDone TO TRUE.
            BREAK.
        }
        IF remNow <= BURN_TRIM_ABS_COMPLETE_DV {
            SET throttleCmd TO 0.0.
            SET burnCompleteReason TO "node-absolute-trim".
            mLogWarn("Burn node absolute trim complete: remaining="
                + ROUND(remNow, 2)
                + " m/s applied=" + ROUND(appliedDv, 2)
                + " of " + ROUND(bdv, 1) + " m/s.").
            SET burnDone TO TRUE.
            BREAK.
        }

        IF fixedBurnVector AND appliedDv >= bdv {
            SET throttleCmd TO 0.0.
            SET burnCompleteReason TO "integrated-target".
            mLogWarn("Burn integrated target reached: applied="
                + ROUND(appliedDv, 2)
                + " of " + ROUND(bdv, 1) + " m/s.").
            SET burnDone TO TRUE.
            BREAK.
        }
        IF fixedBurnVector AND _tc(intRem, bdv) {
            SET throttleCmd TO 0.0.
            SET burnCompleteReason TO "integrated-trim-low-residual".
            mLogWarn("Burn integrated trim complete: remaining="
                + ROUND(intRem, 2)
                + " m/s applied=" + ROUND(appliedDv, 2)
                + " of " + ROUND(bdv, 1) + " m/s.").
            SET burnDone TO TRUE.
            BREAK.
        }
        IF NOT fixedBurnVector AND _tc(remNow, bdv) {
            SET throttleCmd TO 0.0.
            SET burnCompleteReason TO "node-trim-low-residual".
            mLogWarn("Burn node trim complete: remaining="
                + ROUND(remNow, 2)
                + " m/s applied=" + ROUND(appliedDv, 2)
                + " of " + ROUND(bdv, 1) + " m/s.").
            SET burnDone TO TRUE.
            BREAK.
        }
        IF NOT fixedBurnVector AND _ic(nd, ignitionVec) {
            SET throttleCmd TO 0.0.
            SET burnCompleteReason TO "completion-check".
            SET burnDone TO TRUE.
            BREAK.
        }

        LOCAL curBV IS nd:BURNVECTOR.
        LOCAL bvOk IS _bvo(curBV).
        LOCAL bvSlew IS 0.
        LOCAL bvStep IS 0.
        IF bvOk AND _bvo(prevBV) {
            SET bvStep TO VANG(prevBV, curBV).
            SET bvSlew TO bvStep / MAX(0.001, now - prevBVTime).
        }
        LOCAL nodeRebounded IS throttleCmd > 0
                AND remNow > lastNodeRem + BURN_NODE_REBOUND_EPS.
        LOCAL nodeFlipped IS throttleCmd > 0
                AND bvStep > BURN_NODE_FLIP_DEG
                AND (intRem <= BURN_NODE_FLIP_REMAINING_DV
                    OR remNow <= BURN_NODE_FLIP_REMAINING_DV
                    OR bdv <= BURN_FIXED_NODE_MAX_DV).
        IF nodeRebounded OR nodeFlipped {
            IF NOT fixedBurnVector { SET throttleCmd TO 0.0. }
            IF NOT nodeUnstableLogged {
                SET nodeUnstableLogged TO TRUE.
                _burnTraceAdd(burnTrace, "Burn node vector unstable: rem=" + ROUND(remNow,2)
                    + " prevRem=" + ROUND(lastNodeRem,2)
                    + " applied=" + ROUND(appliedDv,2)
                    + " intRem=" + ROUND(intRem,2)
                    + " bvStep=" + ROUND(bvStep,1)
                    + " fixed="
                    + (CHOOSE "true" IF fixedBurnVector ELSE "false") + ".").
            }
            IF NOT fixedBurnVector {
                SET throttleCmd TO 0.0.
                SET burnCompleteReason TO "node-vector-unstable".
                SET burnDone TO TRUE.
                BREAK.
            }
        }
        SET prevBV TO curBV.
        SET prevBVTime TO now.
        SET lastNodeRem TO remNow.

        LOCAL pauseReason IS "".
        LOCAL slewGuardActive IS remNow >= BURN_BV_SLEW_MIN_DV.
        LOCAL curAe IS VANG(SHIP:FACING:FOREVECTOR, steerVec).
        IF bvOk AND NOT fixedBurnVector {
            SET curAe TO VANG(SHIP:FACING:FOREVECTOR, curBV).
        }
        LOCAL realTumble IS slewGuardActive
                AND curAe > BURN_ALIGN_GUARD_DEG
                AND avNow >= BURN_TUMBLE_AV_MIN.
        IF slewGuardActive AND NOT fixedBurnVector AND NOT bvOk {
            SET pauseReason TO "burnvector-invalid".
        } ELSE IF NOT fixedBurnVector
                AND realTumble
                AND bvSlew > BURN_BV_SLEW_MAX_DEG_PER_S {
            SET pauseReason TO "burnvector-slew".
        } ELSE IF bvOk AND NOT fixedBurnVector {
            SET steerVec TO curBV.
        }
        LOCK STEERING TO steerVec.

        LOCAL ae IS VANG(SHIP:FACING:FOREVECTOR, steerVec).
        IF pauseReason = "" {
            IF realTumble AND ae > BURN_ALIGN_GUARD_DEG {
                IF alignOverStart < 0 {
                    SET alignOverStart TO now.
                } ELSE IF now - alignOverStart > BURN_ALIGN_DEBOUNCE {
                    SET pauseReason TO "attitude-divergence".
                }
            } ELSE {
                SET alignOverStart TO -1.
            }
        }

        IF now >= nextTickLog {
            SET nextTickLog TO now + BURN_TICK_LOG_INTERVAL.
            _burnTraceAdd(burnTrace, "BURN tick status="
                + (CHOOSE "paused-recovering" IF pauseReason <> "" ELSE "burning")
                + " ut=" + ROUND(now,3)
                + " rem=" + ROUND(nd:DELTAV:MAG,2)
                + " applied=" + ROUND(appliedDv,2)
                + " intRem=" + ROUND(intRem,2)
                + " ae=" + ROUND(ae,1)
                + " av=" + ROUND(avNow,3)
                + " bvSlew=" + ROUND(bvSlew,1)
                + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4)
                + " thr=" + ROUND(throttleCmd,4)
                + " liveThr=" + ROUND(
                    (CHOOSE throttleCmd IF fixedBurnVector ELSE liveCutoff["output"]),4)
                + " loopDt=" + ROUND(dt,3)
                + " tickDt=" + ROUND(liveCutoff["tickDt"],3)).
        }

        IF pauseReason <> "" {
            SET throttleCmd TO 0.0.
            SET pauseCount TO pauseCount + 1.
            LOCAL pauseStart IS TIME:SECONDS.
            stateSet("burn_status", "paused-recovering").
            stateSet("burn_pause_reason", pauseReason).
            mLogWarn("Burn paused: " + pauseReason
                + " rem=" + ROUND(remNow,2)
                + " ae=" + ROUND(ae,1)
                + " av=" + ROUND(avNow,3)
                + " bvSlew=" + ROUND(bvSlew,1)
                + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4) + ".").
            HUDTEXT("Burn paused: reacquiring attitude", 3, 2, 15, YELLOW, FALSE).

            LOCAL reacquired IS FALSE.
            UNTIL reacquired OR burnAbort <> "" {
                SET now TO TIME:SECONDS.
                IF liveCutoff["reason"] <> "" {
                    SET burnCompleteReason TO liveCutoff["reason"].
                    SET burnDone TO TRUE.
                    BREAK.
                }
                SET remNow TO nd:DELTAV:MAG.
                SET intRem TO MAX(0, bdv - appliedDv).
                SET avNow TO SHIP:ANGULARVEL:MAG.
                IF remNow <= BURN_TRIM_ABS_COMPLETE_DV {
                    SET throttleCmd TO 0.0.
                    SET burnCompleteReason TO "node-absolute-trim".
                    mLogWarn("Burn node absolute trim complete while paused: remaining="
                        + ROUND(remNow, 2)
                        + " m/s applied=" + ROUND(appliedDv, 2)
                        + " of " + ROUND(bdv, 1) + " m/s.").
                    SET burnDone TO TRUE.
                    SET reacquired TO TRUE.
                    BREAK.
                }

                IF remNow > bdv + BURN_NODE_REBOUND_EPS {
                    SET burnAbort TO "node-corrupt-after-pause".
                    SET burnAbortDetail TO "rem=" + ROUND(remNow,2)
                        + " target=" + ROUND(bdv,2)
                        + " applied=" + ROUND(appliedDv,2)
                        + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4).
                    SET throttleCmd TO 0.0.
                    stateSet("burn_status", "aborted-node-corrupt").
                    stateSet("burn_abort_reason", burnAbort).
                    stateSet("burn_abort_detail", burnAbortDetail).
                    mLogError("Burn abort: node corrupt after pause ("
                        + burnAbortDetail + ").").
                    BREAK.
                }
                IF fixedBurnVector AND appliedDv >= bdv {
                    SET throttleCmd TO 0.0.
                    SET burnCompleteReason TO "integrated-target".
                    mLogWarn("Burn integrated target reached while paused: applied="
                        + ROUND(appliedDv, 2)
                        + " of " + ROUND(bdv, 1) + " m/s.").
                    SET burnDone TO TRUE.
                    SET reacquired TO TRUE.
                    BREAK.
                }
                IF fixedBurnVector AND _tc(intRem, bdv) {
                    SET throttleCmd TO 0.0.
                    SET burnCompleteReason TO "integrated-trim-low-residual".
                    mLogWarn("Burn integrated trim complete while paused: remaining="
                        + ROUND(intRem, 2)
                        + " m/s applied=" + ROUND(appliedDv, 2)
                        + " of " + ROUND(bdv, 1) + " m/s.").
                    SET burnDone TO TRUE.
                    SET reacquired TO TRUE.
                    BREAK.
                }
                IF NOT fixedBurnVector AND _tc(remNow, bdv) {
                    SET throttleCmd TO 0.0.
                    SET burnCompleteReason TO "node-trim-low-residual".
                    mLogWarn("Burn node trim complete while paused: remaining="
                        + ROUND(remNow, 2)
                        + " m/s applied=" + ROUND(appliedDv, 2)
                        + " of " + ROUND(bdv, 1) + " m/s.").
                    SET burnDone TO TRUE.
                    SET reacquired TO TRUE.
                    BREAK.
                }
                IF NOT fixedBurnVector AND _ic(nd, ignitionVec) {
                    SET throttleCmd TO 0.0.
                    SET burnCompleteReason TO "completion-check".
                    SET burnDone TO TRUE.
                    SET reacquired TO TRUE.
                    BREAK.
                }
                SET slewGuardActive TO remNow >= BURN_BV_SLEW_MIN_DV.
                IF NOT slewGuardActive {
                    SET reacquired TO TRUE.
                    BREAK.
                }
                IF fixedBurnVector {
                    LOCK STEERING TO steerVec.
                    SET ae TO VANG(SHIP:FACING:FOREVECTOR, steerVec).
                    IF ae <= BURN_ALIGN_REACQUIRE_DEG {
                        SET reacquired TO TRUE.
                    } ELSE IF now - pauseStart > BURN_ALIGN_REACQUIRE_TIMEOUT {
                        IF ae > BURN_ALIGN_GUARD_DEG
                                AND avNow >= BURN_TUMBLE_AV_MIN {
                            SET burnAbort TO pauseReason + "-timeout".
                            SET burnAbortDetail TO "ae=" + ROUND(ae,1)
                                + " av=" + ROUND(avNow,3)
                                + " rem=" + ROUND(remNow,2)
                                + " applied=" + ROUND(appliedDv,2)
                                + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4).
                            SET throttleCmd TO 0.0.
                            stateSet("burn_status", "aborted-tumbling").
                            stateSet("burn_abort_reason", burnAbort).
                            stateSet("burn_abort_detail", burnAbortDetail).
                            mLogError("Burn abort: could not reacquire fixed vector after "
                                + ROUND(now - pauseStart,1) + "s ("
                                + burnAbortDetail + ").").
                            HUDTEXT("BURN ABORT: attitude not recovered", 8, 2, 18, RED, FALSE).
                        } ELSE {
                            SET reacquired TO TRUE.
                        }
                    }
                } ELSE {
                    SET curBV TO nd:BURNVECTOR.
                    SET bvOk TO _bvo(curBV).
                    SET bvSlew TO 0.
                    IF bvOk AND _bvo(prevBV) {
                        SET bvSlew TO VANG(prevBV, curBV) / MAX(0.001, now - prevBVTime).
                    }
                    SET prevBV TO curBV.
                    SET prevBVTime TO now.
                    IF bvOk AND bvSlew <= BURN_BV_SLEW_MAX_DEG_PER_S {
                        SET steerVec TO curBV.
                    }
                    LOCK STEERING TO steerVec.
                    SET ae TO VANG(SHIP:FACING:FOREVECTOR, steerVec).

                    IF now >= nextTickLog {
                        SET nextTickLog TO now + BURN_TICK_LOG_INTERVAL.
                        mLogWarn("BURN tick status=paused-recovering"
                            + " reason=" + pauseReason
                            + " rem=" + ROUND(nd:DELTAV:MAG,2)
                            + " applied=" + ROUND(appliedDv,2)
                            + " intRem=" + ROUND(intRem,2)
                            + " ae=" + ROUND(ae,1)
                            + " av=" + ROUND(avNow,3)
                            + " bvSlew=" + ROUND(bvSlew,1)
                            + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4)
                            + " pausedFor=" + ROUND(now - pauseStart,1)
                            + " thr=" + ROUND(throttleCmd,2)).
                    }

                    IF bvOk AND bvSlew <= BURN_BV_SLEW_MAX_DEG_PER_S
                            AND ae <= BURN_ALIGN_REACQUIRE_DEG {
                        SET reacquired TO TRUE.
                    } ELSE IF now - pauseStart > BURN_ALIGN_REACQUIRE_TIMEOUT {
                        IF pauseReason = "burnvector-invalid"
                                OR (ae > BURN_ALIGN_GUARD_DEG
                                    AND avNow >= BURN_TUMBLE_AV_MIN) {
                            SET burnAbort TO pauseReason + "-timeout".
                            SET burnAbortDetail TO "ae=" + ROUND(ae,1)
                                + " av=" + ROUND(avNow,3)
                                + " bvSlew=" + ROUND(bvSlew,1)
                                + " rem=" + ROUND(remNow,2)
                                + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4).
                            SET throttleCmd TO 0.0.
                            stateSet("burn_status", "aborted-tumbling").
                            stateSet("burn_abort_reason", burnAbort).
                            stateSet("burn_abort_detail", burnAbortDetail).
                            mLogError("Burn abort: could not reacquire after "
                                + ROUND(now - pauseStart,1) + "s (" + burnAbortDetail + ").").
                            HUDTEXT("BURN ABORT: attitude not recovered", 8, 2, 18, RED, FALSE).
                        } ELSE {
                            SET reacquired TO TRUE.
                            mLogWarn("Burn recovery resumed: angular velocity low"
                                + " ae=" + ROUND(ae,1)
                                + " av=" + ROUND(avNow,3)
                                + " bvSlew=" + ROUND(bvSlew,1)
                                + " rem=" + ROUND(remNow,2) + ".").
                        }
                    }
                }
                WAIT 0.05.
            }

            SET totalPaused TO totalPaused + (TIME:SECONDS - pauseStart).
            SET lastDvTime TO TIME:SECONDS.
            SET prevVel TO SHIP:VELOCITY:ORBIT.
            SET prevGravity TO _gacc().
            SET alignOverStart TO -1.
            IF burnDone {
                stateRemove("burn_pause_reason").
            } ELSE IF burnAbort = "" {
                stateSet("burn_status", "burning").
                stateRemove("burn_pause_reason").
                mLog("STATS burn pause result status=reacquired"
                    + " reason=" + pauseReason
                    + " pauseCount=" + pauseCount
                    + " pausedFor=" + ROUND(TIME:SECONDS - pauseStart,1)
                    + " totalPaused=" + ROUND(totalPaused,1)
                    + " ae=" + ROUND(VANG(SHIP:FACING:FOREVECTOR, steerVec),1)
                    + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4)).
            }
        }

        IF burnAbort <> "" { BREAK. }
        IF burnDone { BREAK. }

        LOCAL ma IS _sma().
        IF ma <= 0 {
            SET throttleCmd TO 0.0.
            WAIT 0.01.
            // Keep the same node, ignition vector, and applied-dV total.
            // Separation and ignition may occupy different staging slots.
            IF NOT _burnRecoverThrust(nd, burnTrace) {
                SET burnAbort TO "stage-recovery-failed".
                SET burnAbortDetail TO "Stage recovery/manual wait ended; node retained.".
                IF ABORT { SET burnAbort TO "operator-abort". }
                BREAK.
            }
            IF NOT fixedBurnVector {
                IF NOT _bvo(nd:BURNVECTOR) {
                    SET burnAbort TO "stage-vector-invalid".
                    SET burnAbortDetail TO "Invalid node vector after staging.".
                    BREAK.
                }
                SET steerVec TO nd:BURNVECTOR.
            }
            LOCAL alignDeadline IS TIME:SECONDS + BURN_ALIGN_REACQUIRE_TIMEOUT.
            WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, steerVec) <= BURN_ALIGN_REACQUIRE_DEG
                OR TIME:SECONDS >= alignDeadline OR ABORT.
            IF ABORT OR VANG(SHIP:FACING:FOREVECTOR, steerVec) > BURN_ALIGN_REACQUIRE_DEG {
                SET burnAbort TO "stage-alignment-failed".
                SET burnAbortDetail TO "Could not reacquire burn direction after staging.".
                BREAK.
            }
            SET lastDvTime TO TIME:SECONDS.
            SET prevVel TO SHIP:VELOCITY:ORBIT.
            SET prevGravity TO _gacc().
            SET remNow TO nd:DELTAV:MAG.
            SET lastNodeRem TO remNow.
            SET prevBV TO nd:BURNVECTOR.
            SET prevBVTime TO TIME:SECONDS.
            SET dt TO 0.
            SET ma TO _sma().
        }

        LOCAL rem IS remNow.
        IF fixedBurnVector {
            SET rem TO MAX(0, bdv - appliedDv).
        }
        LOCAL dc IS 1.
        IF NOT fixedBurnVector {
            SET dc TO VDOT(ignitionVec, nd:DELTAV).
        }
        IF rem < 2 {
            SET db2 TO TRUE.
        } ELSE IF db2 AND rem > 2 {
            SET throttleCmd TO 0.0.
            SET dra TO TRUE.
            mLogError("Burn dV rebounded after trim phase: remaining="
                + ROUND(rem, 2) + " m/s — stopping maneuver.").
            SET throttleCmd TO 0.0.
            BREAK.
        }

        IF NOT fixedBurnVector AND dc < 0 { SET throttleCmd TO 0.0. BREAK. }

        IF ma <= 0 {
            // Thrust can disappear between physics ticks, including just
            // after recovery. Stay in this executor and stage next pass.
            SET throttleCmd TO 0.0.
        } ELSE IF rem > BURN_TRIM_ABS_COMPLETE_DV {
            // Taper by time-to-go even above 10 m/s. A fixed dV gate
            // and minimum throttle can overshoot on high-acceleration
            // craft or when the script takes several physics ticks.
            LOCAL horizon IS MAX(1.0, 2 * dt).
            LOCAL nextThrottle IS MIN(1.0, rem / (ma * horizon)).
            // Cooked control may run between any two statements. Publish
            // freshness BEFORE positive throttle, including after a long
            // zero-throttle setup/recovery, or the guard sees a stale command.
            SET liveCutoff["heartbeat"] TO TIME:SECONDS.
            SET throttleCmd TO nextThrottle.
        } ELSE {
            SET throttleCmd TO 0.0.
            BREAK.
        }
        WAIT 0.01.
    }

    SET throttleCmd TO 0.0.
    LOCK THROTTLE TO 0.0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    // Verify physical thrust, not just the command. Keep the zero lock while
    // checking and shut down throttleable engines if thrust persists.
    LOCAL cutoffCheck IS _burnVerifyCutoff().
    IF cutoffCheck["forced"] OR NOT cutoffCheck["stopped"] {
        SET burnAbort TO "thrust-after-cutoff".
        SET burnAbortDetail TO "forced=" + cutoffCheck["forced"]
            + " stopped=" + cutoffCheck["stopped"]
            + " thrust=" + ROUND(SHIP:THRUST,3).
    }
    LOCAL res IS nd:DELTAV:MAG.
    IF liveCutoff["reason"] <> "" {
        SET burnCompleteReason TO liveCutoff["reason"].
        IF burnAbort = "" AND (liveCutoff["reason"] = "live-impulse-limit"
                OR liveCutoff["reason"] = "live-command-stale"
                OR liveCutoff["reason"] = "live-operator-abort"
                OR liveCutoff["reason"] = "live-thrust-invalid") {
            SET burnAbort TO liveCutoff["reason"].
            SET burnAbortDetail TO "Independent burn watchdog stopped thrust; inspect retained node.".
        }
    }
    IF NOT _nf(res) OR liveCutoff["reason"] = "live-node-invalid" {
        SET burnAbort TO "invalid-node-residual".
        SET burnAbortDetail TO "Invalid residual at live cutoff or final sample.".
        IF NOT _nf(res) { SET res TO -1. }
    }
    UNLOCK STEERING.
    UNLOCK THROTTLE.
    SET CONFIG:IPU TO priorIpu.
    stateRemove("burn_prior_ipu").
    LOCAL finalResidualLimit IS _burnFinalResidualLimit(liveCutoff).
    IF burnAbort = "" AND NOT fixedBurnVector AND res > finalResidualLimit {
        SET burnAbort TO "residual-outside-tolerance".
        SET burnAbortDetail TO "remaining=" + _fs(res,9)
            + " limit=" + _fs(finalResidualLimit,9) + " stop=" + burnCompleteReason.
        stateSet("burn_status", "aborted-residual").
    }
    IF dra AND burnAbort = "" {
        SET burnAbort TO "dv-rebound".
        SET burnAbortDetail TO "Residual increased after trim; node retained.".
    }
    // Compact evidence survives log-space exhaustion and phase/boot changes.
    // Never perform this state I/O while commanded thrust is nonzero.
    LOCAL burnReport IS "STATS last-burn phase=" + stateGet("phase", "")
        + " body=" + SHIP:BODY:NAME + " ut=" + ROUND(TIME:SECONDS,2)
        + " plannedDv=" + ROUND(bdv,6) + " thrustDv=" + _fs(liveCutoff["impulse"],6)
        + " impulseCap=" + ROUND(liveCutoff["impulseCap"],3)
        + " residual=" + _fs(res,9) + " residualLimit=" + _fs(finalResidualLimit,9)
        + " reason=" + burnCompleteReason
        + " cutoffFault=" + burnAbort
        + " shutdownAttempted=" + cutoffCheck["forced"]
        + " thrustStopped=" + cutoffCheck["stopped"].
    stateRemove("last_burn_handoff").
    stateSet("last_burn_report", burnReport).
    mLogWarn(burnReport).
    // Flush only after the zero command has reached physics. mLog can
    // copy the entire log to the archive, so it is not burn-loop work.
    FOR traceLine IN burnTrace { mLogWarn(traceLine). }
    mLogWarn("STATS burn cutoff reason=" + burnCompleteReason
        + " cutoffRem=" + _fs(liveCutoff["rem"],9)
        + " cutoffUt=" + ROUND(liveCutoff["time"],3)
        + " sampledResidual=" + _fs(res,9)
        + " trimTolerance=" + _fs(BURN_TRIM_ABS_COMPLETE_DV,9)
        + " residualLimit=" + _fs(finalResidualLimit,9)
        + " fixed=" + fixedBurnVector).
    IF burnAbort <> "" {
        _stl(1.0).
        stateSet("burn_status", "interrupted").
        stateSet("burn_abort_reason", burnAbort).
        stateSet("burn_abort_detail", burnAbortDetail).
        stateSet("burn_abort_time", TIME:SECONDS).
        stateSet("burn_abort_residual", res).
        stateSet("burn_abort_paused", totalPaused).
        mLog("STATS burn abort reason=" + burnAbort
            + " detail=" + burnAbortDetail
            + " dv=" + ROUND(bdv,6)
            + " residual=" + _fs(res,9)
            + " applied=" + ROUND(appliedDv,6)
            + " intResidual=" + ROUND(MAX(0, bdv - appliedDv),2)
            + " duration=" + ROUND(TIME:SECONDS - bsc,1)
            + " paused=" + ROUND(totalPaused,1)
            + " pauseCount=" + pauseCount
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
            + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4)
            + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
        IF aid <> "" {
            DELETEALARM(aid).
        }
        RETURN FALSE.
    }
    _ren(ntm).
    _stl(1.0).
    _cpb("complete").

    // Clean up the KAC alarm now that the burn is done.
    IF aid <> "" {
        DELETEALARM(aid).
    }

    mLogWarn("Burn complete. Residual dV ~" + ROUND(res, 6) + " m/s.").
    mLogWarn("STATS burn result dv=" + ROUND(bdv,6)
        + " residual=" + _fs(res,9)
        + " applied=" + ROUND(appliedDv,6)
        + " intResidual=" + ROUND(MAX(0, bdv - appliedDv),2)
        + " completeReason=" + burnCompleteReason
        + " duration=" + ROUND(TIME:SECONDS - bsc,1)
        + " paused=" + ROUND(totalPaused,1)
        + " pauseCount=" + pauseCount
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
    HUDTEXT("Burn complete", 3, 2, 15, GREEN, FALSE).
    RETURN TRUE.
}

// The governor's full-vector trim sample precedes physical cutoff verification.
// Coast/engine settling can move the node slightly after that valid sample.
// Bound that allowance to half a tolerance AND at most0.001m/s; never use it
// for axis-only trims, reversals, rebound, missing/bad evidence or watchdogs.
// This changes final acceptance only, never the throttle cutoff target.
LOCAL FUNCTION _burnFinalResidualLimit {
    PARAMETER cutoff.
    LOCAL tolerance IS BURN_TRIM_ABS_COMPLETE_DV.
    IF tolerance > 0 AND cutoff["reason"] = "live-node-trim"
            AND _nf(cutoff["rem"]) AND cutoff["rem"] >= 0
            AND cutoff["rem"] <= tolerance {
        RETURN tolerance + MIN(0.001, tolerance * 0.5).
    }
    RETURN tolerance.
}

// No logging, file access, waits, steering, or staging in this function:
// cooked-control locks run it as a high-priority physics-tick trigger.
LOCAL FUNCTION _burnNodeThrottle {
    PARAMETER nd.
    PARAMETER ignitionVec.
    PARAMETER command.
    PARAMETER cutoff.
    LOCAL tickNow IS TIME:SECONDS.
    LOCAL tickDt IS MAX(0.02, tickNow - cutoff["lastTick"]).
    SET cutoff["lastTick"] TO tickNow.
    SET cutoff["tickDt"] TO tickDt.
    SET cutoff["output"] TO 0.
    IF cutoff["reason"] <> "" { RETURN 0. }
    LOCAL independentLimit IS _burnImpulseThrottle(command, cutoff).
    IF cutoff["reason"] <> "" { RETURN 0. }
    IF cutoff["fixed"] {
        SET cutoff["output"] TO independentLimit.
        RETURN cutoff["output"].
    }
    IF command <= 0 {
        // Coasting/staging can change node error without any engine impulse.
        SET cutoff["bestRem"] TO -1.
        RETURN 0.
    }
    LOCAL acc IS _sma().
    IF acc <= 0 {
        SET cutoff["bestRem"] TO -1.
        RETURN 0.
    }

    LOCAL residual IS nd:DELTAV.
    LOCAL rem IS residual:MAG.
    LOCAL reason IS "".
    IF NOT _nf(rem) { SET reason TO "live-node-invalid". }
    ELSE IF rem <= BURN_TRIM_ABS_COMPLETE_DV {
        SET reason TO "live-node-trim".
    } ELSE IF VDOT(ignitionVec, residual) < 0 {
        SET reason TO "live-vector-passed-target".
    }
    LOCAL forwardRem IS 0.
    IF reason = "" { SET forwardRem TO VDOT(SHIP:FACING:FOREVECTOR, residual). }
    IF reason = "" AND rem <= BURN_NODE_FLIP_REMAINING_DV
            AND forwardRem <= BURN_TRIM_ABS_COMPLETE_DV {
        SET reason TO "live-thrust-axis-trim".
    }
    IF reason = "" AND cutoff["bestRem"] >= 0
            AND rem > cutoff["bestRem"] + BURN_NODE_REBOUND_EPS {
        SET reason TO "live-residual-rebound".
    }
    IF reason <> "" {
        SET cutoff["reason"] TO reason.
        SET cutoff["rem"] TO rem.
        SET cutoff["time"] TO tickNow.
        RETURN 0.
    }

    IF cutoff["bestRem"] < 0 OR rem < cutoff["bestRem"] {
        SET cutoff["bestRem"] TO rem.
    }
    // A finite burn can leave transverse node error. Near cutoff, taper
    // the component the CURRENT thrust direction can actually remove;
    // do not accelerate through it trying to zero the vector's magnitude.
    IF rem <= BURN_NODE_FLIP_REMAINING_DV {
        SET rem TO MIN(rem, MAX(0, forwardRem)).
    }
    // Reserve several physics steps for control latency; this limit
    // reads the current node and acceleration, never the loop's sample.
    LOCAL horizon IS MAX(1.0, 4 * tickDt).
    SET cutoff["output"] TO MIN(independentLimit, MIN(command, rem / (acc * horizon))).
    RETURN cutoff["output"].
}

// Actual thrust/mass integration is independent of the node and orbit frame.
// Called from the live lock even during intentional zero-throttle pauses.
LOCAL FUNCTION _burnImpulseThrottle {
    PARAMETER command.
    PARAMETER cutoff.
    LOCAL nowT IS TIME:SECONDS.
    LOCAL elapsed IS MAX(0, nowT - cutoff["impulseTime"]).
    LOCAL actualAcc IS SHIP:THRUST / MAX(0.01, SHIP:MASS).
    LOCAL reason IS "".
    IF ABORT { SET reason TO "live-operator-abort". }
    IF NOT _nf(actualAcc) OR actualAcc < 0 { SET reason TO "live-thrust-invalid". }
    IF reason = "" {
        SET cutoff["impulse"] TO cutoff["impulse"]
            + (cutoff["lastAcc"] + actualAcc) * elapsed / 2.
        SET cutoff["lastAcc"] TO actualAcc.
        SET cutoff["impulseTime"] TO nowT.
        IF cutoff["impulse"] >= cutoff["impulseCap"] - 0.001 {
            SET reason TO "live-impulse-limit".
        } ELSE IF command > 0 AND nowT - cutoff["heartbeat"] > MAX(0.1, BURN_COMMAND_TIMEOUT) {
            SET reason TO "live-command-stale".
        }
    }
    IF reason <> "" {
        SET cutoff["reason"] TO reason.
        SET cutoff["time"] TO nowT.
        RETURN 0.
    }
    IF command <= 0 { RETURN 0. }
    LOCAL availableAcc IS _sma().
    IF availableAcc <= 0 { RETURN 0. }
    LOCAL remaining IS MAX(0, cutoff["impulseCap"] - cutoff["impulse"]).
    RETURN MIN(command, remaining / (availableAcc * MAX(1, 4 * elapsed))).
}

LOCAL FUNCTION _burnVerifyCutoff {
    RETURN thrustCutoff(TRUE, BURN_CUTOFF_VERIFY_TIME).
}

LOCAL FUNCTION _burnTraceAdd {
    PARAMETER trace, message.
    // Bound memory use on long burns and preserve the cutoff approach.
    IF trace:LENGTH >= 20 { trace:REMOVE(0). }
    trace:ADD(message).
    PRINT message.
}

LOCAL FUNCTION _rmb {
    PARAMETER nd.
    LOCAL wb IS TRUE.
    IF BURN_BRIEF = 0 {
        SET wb TO FALSE.
    }

    IF wb AND HOMECONNECTION:ISCONNECTED {
        IF EXISTS("0:/lib/maneuver_ui.ks") {
            RUNPATH("0:/lib/maneuver_ui.ks", nd).
        }
    }
}

GLOBAL FUNCTION maneuverUiArchiveLog {
    PARAMETER label IS "maneuver".
    IF HOMECONNECTION:ISCONNECTED {
        IF EXISTS("0:/lib/maneuver_ui.ks") {
            RUNPATH("0:/lib/maneuver_ui.ks", 0, label).
        }
    }
}

// Read-only archive diagnostics can inspect the private governor without
// installing a throttle lock or carrying the diagnostic code in flight.
GLOBAL FUNCTION maneuverThrottleCheck {
    IF HOMECONNECTION:ISCONNECTED AND EXISTS("0:/lib/burn_check.ks") {
        RUNPATH("0:/lib/burn_check.ks", _sma@, _burnNodeThrottle@).
    }
}

LOCAL FUNCTION _stl {
    PARAMETER pct.
    FOR eng IN SHIP:ENGINES {
        SET eng:THRUSTLIMIT TO pct * 100.
    }
}

LOCAL FUNCTION _burnLimitThrust {
    PARAMETER dv.
    LOCAL acc IS _sma().
    LOCAL fraction IS 1.
    IF _nf(dv) AND dv > 0 AND _nf(acc) AND acc > 0 {
        // Lengthen genuinely short burns, not every burn below a fixed dV.
        // Scale the existing limits: _sma already includes those settings.
        SET fraction TO MIN(1, dv / (acc * MAX(1, BURN_MIN_FULL_THRUST_SECONDS))).
        IF fraction < 1 {
            FOR eng IN SHIP:ENGINES {
                SET eng:THRUSTLIMIT TO eng:THRUSTLIMIT * fraction.
            }
        }
    }
    RETURN fraction.
}

// Single-burn node planners (planCircularize / planCapture /
// planRaisePeNow / planLowerPe / planAoPChange) and their vis-viva
// helper now live in maneuver_plan.ks so burn-only bands (BPLANE,
// SHAPE) can import the executor without the planner weight.

// Estimated total burn duration. NODE:BURNTIME does not exist in
// this kOS build (flight-found) — use KerbalEngineer when present,
// else constant-mass dv/acc.
LOCAL FUNCTION _bte {
    PARAMETER nd.
    IF ADDONS:KE:AVAILABLE {
        RETURN ADDONS:KE:NODEHALFBURNTIME * 2.
    }
    LOCAL acc IS _sma().
    IF acc <= 0 { RETURN 0. }
    RETURN nd:DELTAV:MAG / acc.
}

LOCAL FUNCTION _cst {
    PARAMETER nd.
    LOCAL hb IS _bte(nd) / 2.
    LOCAL lead IS MIN(2.0, hb * 0.02).
    RETURN nd:TIME - hb - lead.
}

LOCAL FUNCTION _sma {
    IF SHIP:MASS <= 0 { RETURN 0. }
    LOCAL available IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT {
            SET available TO available + eng:AVAILABLETHRUST.
        }
    }
    RETURN available / SHIP:MASS.
}

LOCAL FUNCTION _gacc {
    // kOS positions are ship-centered; gravity needs body-relative r.
    LOCAL rVec IS SHIP:POSITION - SHIP:BODY:POSITION.
    LOCAL rMag IS rVec:MAG.
    IF rMag <= 0 { RETURN V(0, 0, 0). }
    RETURN -rVec:NORMALIZED * (SHIP:BODY:MU / (rMag * rMag)).
}

LOCAL FUNCTION _nf {
    PARAMETER val.
    RETURN (val = val) AND ABS(val) < 1e30.
}

LOCAL FUNCTION _fs {
    PARAMETER val.
    PARAMETER places IS 1.
    IF _nf(val) { RETURN ROUND(val, places). }
    RETURN "bad".
}

LOCAL FUNCTION _bvo {
    PARAMETER vec.
    LOCAL mag IS vec:MAG.
    IF NOT _nf(mag) { RETURN FALSE. }
    IF mag < BURN_BV_MIN_MAG { RETURN FALSE. }
    IF NOT _nf(vec:X) { RETURN FALSE. }
    IF NOT _nf(vec:Y) { RETURN FALSE. }
    IF NOT _nf(vec:Z) { RETURN FALSE. }
    RETURN TRUE.
}

LOCAL FUNCTION _ic {
    PARAMETER nd, ignitionVec.
    LOCAL rem IS nd:DELTAV:MAG.
    IF rem <= BURN_TRIM_ABS_COMPLETE_DV { RETURN TRUE. }
    // Stop a reversed residual, but let final validation report failure
    // when it is still outside tolerance. Neither a percentage of the
    // original burn nor a small vector deflection means it is complete.
    RETURN VDOT(ignitionVec, nd:DELTAV) < 0.
}

LOCAL FUNCTION _tc {
    PARAMETER rem, origDV.
    IF origDV <= 0 { RETURN FALSE. }
    IF rem > BURN_TRIM_COMPLETE_MAX_DV { RETURN FALSE. }
    RETURN (MAX(0, origDV - rem) / origDV) >= BURN_TRIM_COMPLETE_FRAC.
}

LOCAL FUNCTION _burnRecoverThrust {
    PARAMETER nd, trace.
    IF _sma() > 0 { RETURN TRUE. }
    // Include an engine whose slot has already fired but needs activation.
    // Never advance beyond the selected engine into payload/chute slots.
    LOCAL engineStage IS -1.
    FOR eng IN SHIP:ENGINES {
        _burnTraceAdd(trace, "STATS burn staging engine=" + eng:NAME
            + " stage=" + eng:STAGE + " decoupledIn=" + eng:DECOUPLEDIN
            + " ignition=" + eng:IGNITION + " flameout=" + eng:FLAMEOUT
            + " available=" + ROUND(eng:AVAILABLETHRUST, 3)).
        IF NOT eng:IGNITION AND eng:STAGE <= STAGE:NUMBER
                AND eng:STAGE >= MAX(0, BURN_STAGE_LIMIT)
                AND eng:DECOUPLEDIN < eng:STAGE {
            SET engineStage TO MAX(engineStage, eng:STAGE).
        }
    }
    LOCAL deadline IS TIME:SECONDS + MAX(1, BURN_STAGE_TIMEOUT).
    LOCAL manualDeadline IS 0.
    LOCAL manualWait IS FALSE.
    LOCAL events IS 0.
    LOCAL activated IS LIST().
    _burnTraceAdd(trace, "STATS burn staging begin stage=" + STAGE:NUMBER
        + " engineStage=" + engineStage + " rem=" + ROUND(nd:DELTAV:MAG, 3)).
    UNTIL _sma() > 0 OR ABORT {
        IF NOT manualWait AND (engineStage < 0 OR TIME:SECONDS >= deadline
                OR (events >= BURN_STAGE_MAX_EVENTS AND STAGE:NUMBER > engineStage)) {
            SET manualWait TO TRUE.
            SET manualDeadline TO TIME:SECONDS + MAX(0, BURN_STAGE_MANUAL_WAIT).
            stateSet("burn_status", "waiting-for-thrust").
            _burnTraceAdd(trace, "STATS burn staging manual-wait stage=" + STAGE:NUMBER
                + " engineStage=" + engineStage + " ready=" + STAGE:READY
                + " events=" + events).
            PRINT "BURN WAIT: stage/activate the transfer engine; auto-resume when ready. ABORT to stop.".
        }
        IF manualWait AND TIME:SECONDS >= manualDeadline { RETURN FALSE. }
        IF NOT manualWait AND STAGE:NUMBER > engineStage AND STAGE:READY {
            LOCAL beforeStage IS STAGE:NUMBER.
            STAGE.
            SET events TO events + 1.
            WAIT MAX(0.02, BURN_STAGE_SETTLE).
            _burnTraceAdd(trace, "STATS burn staging event from=" + beforeStage
                + " to=" + STAGE:NUMBER + " rem=" + ROUND(nd:DELTAV:MAG, 3)).
            // A rejected staging command must not spin indefinitely.
        } ELSE IF NOT manualWait AND STAGE:NUMBER = engineStage {
            // A separate decoupler slot may have fired without ignition,
            // or activation may have been suppressed by an engine module.
            FOR eng IN SHIP:ENGINES {
                IF eng:STAGE = engineStage AND NOT eng:IGNITION
                        AND eng:DECOUPLEDIN < eng:STAGE
                        AND NOT activated:CONTAINS(eng:UID) {
                    activated:ADD(eng:UID).
                    eng:ACTIVATE.
                    _burnTraceAdd(trace, "STATS burn staging activate engine=" + eng:NAME).
                }
            }
        }
        WAIT 0.05.
    }
    // If thrust vanishes again, the caller loops back into recovery.
    // Do not turn a second asynchronous thrust sample into an abort.
    IF ABORT { RETURN FALSE. }
    _burnTraceAdd(trace, "STATS burn staging resumed stage=" + STAGE:NUMBER
        + " rem=" + ROUND(nd:DELTAV:MAG, 3) + " acc=" + ROUND(_sma(), 3)
        + " estRemainingSeconds=" + ROUND(nd:DELTAV:MAG / MAX(0.0001, _sma()), 1)
        + " secondsPastNode=" + ROUND(TIME:SECONDS - nd:TIME, 1)).
    stateSet("burn_status", "burning").
    RETURN TRUE.
}

GLOBAL FUNCTION maneuverBurnInterrupted {
    RETURN stateGet("burn_pending", "false") = "true"
        AND stateGet("burn_started", "false") = "true"
        AND stateGet("burn_phase", "") = stateGet("phase", "").
}

GLOBAL FUNCTION maneuverDepartureFlown {
    IF stateGet("phase", "") <> "XING" { RETURN FALSE. }
    RETURN maneuverBurnInterrupted()
        OR (stateGetNum("burn_departure_time", -1) >= 0
            AND stateGet("burn_departure_target", "") = getTarget("")).
}

GLOBAL FUNCTION maneuverAcceptHandoff {
    PARAMETER decision IS "accept-live-trajectory".
    SET BURN_RESUME_REQUESTED TO FALSE.
    IF stateGet("burn_phase", "") <> stateGet("phase", "") { RETURN. }
    LOCAL priorAbort IS stateGet("burn_abort_reason", "").
    LOCAL priorResidual IS stateGetNum("burn_abort_residual", -1).
    _ren(stateGetNum("burn_node_time", -1)).
    _cpb("arrival-handoff").
    // Keep strict executor evidence intact. The caller has independently
    // accepted the trajectory or assigned immediate arrival correction;
    // record that later mission decision without reclassifying the cutoff.
    LOCAL outcome IS "STATS burn handoff decision=" + decision + " phase=" + stateGet("phase", "")
        + " ut=" + _fs(TIME:SECONDS,2) + " priorAbort=" + priorAbort
        + " priorResidual=" + _fs(priorResidual,9)
        + " burnPending=" + stateGet("burn_pending","false")
        + " burnStarted=" + stateGet("burn_started","false").
    stateSet("last_burn_handoff",outcome).
    mLogSummary(outcome).
}

LOCAL FUNCTION _ren {
    PARAMETER ntm.
    IF NOT HASNODE { RETURN. }

    LOCAL nt IS NEXTNODE:TIME.
    IF ABS(nt - ntm) < 0.5 {
        REMOVE NEXTNODE.
        WAIT 0.1.
    } ELSE {
        mLog("Preserving remaining maneuver node at T+"
            + ROUND(nt - TIME:SECONDS, 1) + "s.").
    }
}

LOCAL FUNCTION _mpb {
    PARAMETER nd.
    PARAMETER bdv.
    PARAMETER st.
    stateSet("burn_pending", "true").
    stateSet("burn_started", "false").
    stateSet("burn_phase", stateGet("phase", "")).
    stateSet("burn_node_time", nd:TIME).
    stateSet("burn_body", SHIP:BODY:NAME).
    stateSet("burn_start_time", st).
    stateSet("burn_dv", bdv).
}

LOCAL FUNCTION _cpb {
    PARAMETER reason.
    IF stateGet("burn_pending", "") = "true" {
        mLog("Clearing pending burn state: " + reason + ".").
    }
    FOR key IN LIST(
        "burn_pending", "burn_started", "burn_phase", "burn_node_time",
        "burn_start_time", "burn_dv", "burn_status", "burn_body",
        "burn_pause_reason", "burn_abort_reason", "burn_abort_detail",
        "burn_abort_time", "burn_abort_residual", "burn_abort_paused"
    ) {
        stateRemove(key).
    }
}
