// ============================================================
// maneuver.ks  —  Maneuver execution  (0:/lib/maneuver.ks)
// ============================================================

@CLOBBERBUILTINS ON.
@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL BURN_BRIEF IS 1.
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
GLOBAL BURN_ABORT_HOLD_VECTOR IS V(0, 0, 1).
GLOBAL BURN_FULL_THROTTLE_MIN_DV IS 10.


LOCAL ATOL      IS 2.0.
LOCAL CRT IS 300.
LOCAL CRL  IS 180.

GLOBAL FUNCTION executeManeuver {
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
    IF bdv <= BURN_TRIM_ABS_COMPLETE_DV {
        _ren(ntm).
        _cpb("already-complete").
        mLog("Maneuver already below absolute dV tolerance; skipping burn.").
        RETURN TRUE.
    }
    IF bdv < 50 { _stl(0.50). }
    IF bdv < 10 { _stl(0.10). }
    IF bdv < 2  { _stl(0.05). }
    IF bdv < 0.5 { _stl(0.02). }
    // Estimate the centered start with the thrust limits actually used.
    WAIT 0.1.
    LOCAL st IS _cst(nd).
    _mpb(nd, bdv, st).

    IF st < TIME:SECONDS {
        mLogWarn("Burn window already passed by " + ROUND(TIME:SECONDS - st, 0) + "s — removing node.").
        HUDTEXT("Burn window missed — replanning", 5, 2, 15, YELLOW, FALSE).
        REMOVE nd.
        _stl(1.0).
        _cpb("missed-window").
        RETURN FALSE.
    }

    _rmb(nd).

    mLog("Maneuver: dV=" + ROUND(bdv,1) + " m/s  ETA=" + ROUND(st - TIME:SECONDS,1) + "s").
    mLog("STATS burn setup dv=" + ROUND(bdv,1)
        + " eta=" + ROUND(st - TIME:SECONDS,1)
        + " nodeEta=" + ROUND(nd:ETA,1)
        + " body=" + SHIP:BODY:NAME
        + " maxAcc=" + ROUND(_sma(),2)).
    IF _sma() <= 0 {
        mLog("STATS burn thrust status=no-thrust maxThrust="
            + ROUND(SHIP:MAXTHRUST,1)
            + " availThrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).
    }

    LOCAL aid IS maneuverEnsureBurnAlarm(st, bdv, "Burn").

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
        // solar is sheddable (not a maneuver dep) — orient only when
        // a phase in this band actually brought the lib aboard.
        IF PHASES_HAS_SOLAR { orientForSolar(FALSE, TRUE). }
        mLog("Long coast wait (" + ROUND(rt - TIME:SECONDS, 0) + "s).").
        HUDTEXT("Coasting. Burn in " + ROUND(st - TIME:SECONDS, 0) + "s", 5, 2, 13, CYAN, FALSE).
        coastAutoWarp(rt, "Burn coast", aid).
        LOCAL sr IS -1.
        UNTIL TIME:SECONDS >= rt {
            SET sr TO trySolarHoldTick(sr).
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
        + " timeToBurn=" + ROUND(st - TIME:SECONDS, 1)).
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
    mLog("Burn start. dV=" + ROUND(bdv,1) + " m/s").
    stateSet("burn_status", "burning").
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
    LOCAL throttleCmd IS 0.0.
    LOCAL liveCutoff IS LEX("reason", "", "rem", -1, "time", 0,
        "lastTick", TIME:SECONDS, "tickDt", 0.02, "output", 0).
    LOCAL burnTrace IS LIST().
    LOCK STEERING TO steerVec.
    IF fixedBurnVector {
        LOCK THROTTLE TO throttleCmd.
    } ELSE {
        // This expression runs every physics tick, even while the main
        // loop is busy. A lock on throttleCmd alone repeats stale input.
        LOCK THROTTLE TO _burnNodeThrottle(nd, ignitionVec, throttleCmd, liveCutoff).
    }
    LOCAL db2 IS FALSE.
    LOCAL dra IS FALSE.
    LOCAL rdv IS 0.
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

        IF _ns() {
            SET throttleCmd TO 0.0.
            HUDTEXT("Staging!", 2, 2, 15, YELLOW, FALSE).
            mLog("Auto-stage triggered.").
            WAIT 0.3.
            STAGE.
            WAIT 0.7.
            SET lastDvTime TO TIME:SECONDS.
            SET prevVel TO SHIP:VELOCITY:ORBIT.
            SET prevGravity TO _gacc().
        }

        LOCAL rem IS remNow.
        IF fixedBurnVector {
            SET rem TO MAX(0, bdv - appliedDv).
        }
        LOCAL ma    IS _sma().
        IF ma <= 0 {
            SET throttleCmd TO 0.0.
            SET burnAbort TO "no-thrust".
            SET burnAbortDetail TO "No available thrust after staging check.".
            stateSet("burn_status", "aborted-no-thrust").
            BREAK.
        }
        LOCAL dc IS 1.
        IF NOT fixedBurnVector {
            SET dc TO VDOT(ignitionVec, nd:DELTAV).
        }
        IF rem < 2 {
            SET db2 TO TRUE.
        } ELSE IF db2 AND rem > 2 {
            SET throttleCmd TO 0.0.
            SET rdv TO rem.
            SET dra TO TRUE.
            mLogError("Burn dV rebounded after trim phase: remaining="
                + ROUND(rem, 2) + " m/s — stopping maneuver.").
            SET throttleCmd TO 0.0.
            BREAK.
        }

        IF NOT fixedBurnVector AND dc < 0 { SET throttleCmd TO 0.0. BREAK. }

        IF rem > BURN_TRIM_ABS_COMPLETE_DV {
            // Taper by time-to-go even above 10 m/s. A fixed dV gate
            // and minimum throttle can overshoot on high-acceleration
            // craft or when the script takes several physics ticks.
            LOCAL horizon IS MAX(1.0, 2 * dt).
            SET throttleCmd TO MIN(1.0, rem / (ma * horizon)).
            IF rem <= BURN_FULL_THROTTLE_MIN_DV {
                SET throttleCmd TO MIN(0.5, throttleCmd).
            }
        } ELSE {
            SET throttleCmd TO 0.0.
            BREAK.
        }
        WAIT 0.01.
    }

    SET throttleCmd TO 0.0.
    LOCK THROTTLE TO 0.0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    // Let the zero command reach a physics update before restoring
    // thrust limits or removing the node.
    WAIT 0.01.
    LOCAL res IS nd:DELTAV:MAG.
    IF liveCutoff["reason"] <> "" {
        SET burnCompleteReason TO liveCutoff["reason"].
    }
    IF NOT _nf(res) OR liveCutoff["reason"] = "live-node-invalid" {
        SET burnAbort TO "invalid-node-residual".
        SET burnAbortDetail TO "Invalid residual at live cutoff or final sample.".
        IF NOT _nf(res) { SET res TO -1. }
    }
    // Flush only after the zero command has reached physics. mLog can
    // copy the entire log to the archive, so it is not burn-loop work.
    FOR traceLine IN burnTrace { mLogWarn(traceLine). }
    mLogWarn("STATS burn cutoff reason=" + burnCompleteReason
        + " cutoffRem=" + _fs(liveCutoff["rem"],3)
        + " cutoffUt=" + ROUND(liveCutoff["time"],3)
        + " sampledResidual=" + ROUND(res,3)
        + " fixed=" + fixedBurnVector).
    IF burnAbort = "" AND NOT fixedBurnVector
            AND res > BURN_TRIM_ABS_COMPLETE_DV {
        SET burnAbort TO "residual-outside-tolerance".
        SET burnAbortDetail TO "remaining=" + ROUND(res, 3)
            + " stop=" + burnCompleteReason.
        stateSet("burn_status", "aborted-residual").
    }
    IF burnAbort <> "" {
        SET BURN_ABORT_HOLD_VECTOR TO steerVec.
        LOCK STEERING TO BURN_ABORT_HOLD_VECTOR.
        _stl(1.0).
        stateSet("burn_abort_time", TIME:SECONDS).
        stateSet("burn_abort_residual", res).
        stateSet("burn_abort_paused", totalPaused).
        mLog("STATS burn abort reason=" + burnAbort
            + " detail=" + burnAbortDetail
            + " dv=" + ROUND(bdv,1)
            + " residual=" + ROUND(res,2)
            + " applied=" + ROUND(appliedDv,2)
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
    SET throttleCmd TO 0.0.
    LOCK THROTTLE TO 0.0.
    _ren(ntm).
    _stl(1.0).
    IF dra {
        _cpb("dv-rebound").
    } ELSE {
        _cpb("complete").
    }

    // Clean up the KAC alarm now that the burn is done.
    IF aid <> "" {
        DELETEALARM(aid).
    }

    IF dra {
        mLog("STATS burn abort reason=dv-rebound"
            + " dv=" + ROUND(bdv,1)
            + " reboundDv=" + ROUND(rdv,2)
            + " duration=" + ROUND(TIME:SECONDS - bsc,1)
            + " paused=" + ROUND(totalPaused,1)
            + " pauseCount=" + pauseCount
            + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
            + " ecc=" + _fs(SHIP:ORBIT:ECCENTRICITY,4)
            + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
        RETURN FALSE.
    }

    UNLOCK STEERING.
    mLogWarn("Burn complete. Residual dV ~" + ROUND(res, 2) + " m/s.").
    mLogWarn("STATS burn result dv=" + ROUND(bdv,1)
        + " residual=" + ROUND(res,2)
        + " applied=" + ROUND(appliedDv,2)
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

// No logging, file access, waits, steering, or staging in this function:
// cooked-control locks run it as a high-priority physics-tick trigger.
LOCAL FUNCTION _burnNodeThrottle {
    PARAMETER nd, ignitionVec, command, cutoff.
    LOCAL tickNow IS TIME:SECONDS.
    LOCAL tickDt IS MAX(0.02, tickNow - cutoff["lastTick"]).
    SET cutoff["lastTick"] TO tickNow.
    SET cutoff["tickDt"] TO tickDt.
    SET cutoff["output"] TO 0.
    IF command <= 0 OR cutoff["reason"] <> "" { RETURN 0. }

    LOCAL residual IS nd:DELTAV.
    LOCAL rem IS residual:MAG.
    LOCAL reason IS "".
    IF NOT _nf(rem) { SET reason TO "live-node-invalid". }
    ELSE IF rem <= BURN_TRIM_ABS_COMPLETE_DV {
        SET reason TO "live-node-trim".
    } ELSE IF VDOT(ignitionVec, residual) < 0 {
        SET reason TO "live-vector-passed-target".
    }
    IF reason <> "" {
        SET cutoff["reason"] TO reason.
        SET cutoff["rem"] TO rem.
        SET cutoff["time"] TO tickNow.
        RETURN 0.
    }

    LOCAL acc IS _sma().
    IF acc <= 0 { RETURN 0. }
    // Reserve several physics steps for control latency; this limit
    // reads the current node and acceleration, never the loop's sample.
    LOCAL horizon IS MAX(1.0, 4 * tickDt).
    SET cutoff["output"] TO MIN(command, rem / (acc * horizon)).
    RETURN cutoff["output"].
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

LOCAL FUNCTION _stl {
    PARAMETER pct.
    FOR eng IN SHIP:ENGINES {
        SET eng:THRUSTLIMIT TO pct * 100.
    }
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
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
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

LOCAL FUNCTION _ns {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
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
    stateSet("burn_phase", stateGet("phase", "")).
    stateSet("burn_node_time", nd:TIME).
    stateSet("burn_start_time", st).
    stateSet("burn_dv", bdv).
}

LOCAL FUNCTION _cpb {
    PARAMETER reason.
    IF stateGet("burn_pending", "") = "true" {
        mLog("Clearing pending burn state: " + reason + ".").
    }
    FOR key IN LIST(
        "burn_pending", "burn_phase", "burn_node_time",
        "burn_start_time", "burn_dv", "burn_status",
        "burn_pause_reason", "burn_abort_reason", "burn_abort_detail",
        "burn_abort_time", "burn_abort_residual", "burn_abort_paused"
    ) {
        stateRemove(key).
    }
}
