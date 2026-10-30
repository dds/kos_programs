// ============================================================
// maneuver_mcc.ks — mid-course correction phase (MCC)
// (0:/lib/maneuver_mcc.ks)
//
// Split from maneuver_transfer.ks: MCC is its own reload band,
// so the ESCAPE/XING (XFER_PLAN) band no longer carries ~20KB of
// correction code it never runs — flight-found when the return
// mission's lib sync ran the FR3 core out of storage in a boot
// loop. Uses the shared targeting helpers (maneuver_targeting).
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL CAPTURE_PE IS -1.
GLOBAL CAPTURE_INC IS -1.
GLOBAL CAPTURE_LAN IS -1.
GLOBAL CAPTURE_AOP IS -1.
GLOBAL CAPTURE_DIR IS "".
GLOBAL MCC_AEROBRAKE_SAFE_PE_MIN IS 20000.
GLOBAL MCC_AEROBRAKE_SAFE_PE_MAX IS -1.
// Shared setup/runtime return budget defaults live in return_mcc_config.


LOCAL MCC_DV_CAP           IS 50.
LOCAL MCC_MIN_DV           IS 2.0.
LOCAL MCC_LATE_MIN_DV      IS 3.0.
LOCAL MCC_LATE_ETA         IS 7200.
LOCAL MCC_AEROBRAKE_ATMO_MARGIN IS 1000.
LOCAL MAX_RETRIES          IS 5.

LOCAL FUNCTION _mccIsAerobrakeReturn {
    PARAMETER target.
    IF target:NAME <> "Kerbin" { RETURN FALSE. }
    IF MISSION_TYPE = "kerbin_return" { RETURN TRUE. }
    IF stateGet("mission_type", "") = "kerbin_return" { RETURN TRUE. }
    RETURN xferSeq:CONTAINS("AEROBRAKE").
}

LOCAL FUNCTION _mccAerobrakeSafePeMin {
    PARAMETER target.
    PARAMETER targetPe.
    LOCAL minPe IS MCC_AEROBRAKE_SAFE_PE_MIN.
    IF minPe < 0 { SET minPe TO targetPe - 15000. }
    RETURN MAX(0, minPe).
}

LOCAL FUNCTION _mccAerobrakeSafePeMax {
    PARAMETER target.
    PARAMETER targetPe.
    LOCAL maxPe IS MCC_AEROBRAKE_SAFE_PE_MAX.
    IF maxPe < 0 {
        IF target:ATM:EXISTS {
            SET maxPe TO target:ATM:HEIGHT - MCC_AEROBRAKE_ATMO_MARGIN.
        } ELSE {
            SET maxPe TO targetPe + 15000.
        }
    }
    RETURN MAX(_mccAerobrakeSafePeMin(target, targetPe), maxPe).
}

LOCAL FUNCTION _mccAerobrakePatchSafe {
    PARAMETER patch.
    PARAMETER target.
    PARAMETER targetPe.
    IF patch = 0 { RETURN FALSE. }
    IF NOT target:ATM:EXISTS { RETURN FALSE. }
    LOCAL pe IS patch:PERIAPSIS.
    RETURN pe >= _mccAerobrakeSafePeMin(target, targetPe)
        AND pe <= _mccAerobrakeSafePeMax(target, targetPe).
}

LOCAL FUNCTION _mccReturnHold {
    PARAMETER reason.
    SET WARP TO 0.
    IF NOT thrustCutoffOk() { RETURN. }
    UNLOCK STEERING.
    mLogError("Return correction held: " + reason + ". Remaining in MCC.").
    mLog("STATS return-mcc status=held reason=" + reason
        + " body=" + SHIP:BODY:NAME
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 3)
        + " remainingDv=" + ROUND(SHIP:DELTAV:VACUUM, 1)).
    IF reason = "fuel-reserve" {
        PRINT "To explicitly spend the reserve toward52km entry: RUNPATH(" + CHAR(34)
            + "0:/cmd/returnmcc.ks" + CHAR(34) + ",52000,0). Then REBOOT.".
    }
    yieldToPrompt().
}

LOCAL FUNCTION _mccReturnBudget {
    LOCAL available IS SHIP:DELTAV:VACUUM.
    IF NOT (available >= 0 AND available < 1e30
            AND MCC_RETURN_RESERVE_DV >= 0 AND MCC_RETURN_RESERVE_DV < 1e30
            AND ABS(MCC_RETURN_DV_CAP) < 1e30) { RETURN 0. }
    LOCAL budget IS MAX(0,available-MCC_RETURN_RESERVE_DV).
    IF MCC_RETURN_DV_CAP >= 0 { SET budget TO MIN(budget,MCC_RETURN_DV_CAP). }
    RETURN budget.
}

LOCAL FUNCTION _mccReturnApoapsisCoast {
    PARAMETER target.
    PARAMETER targetPe.
    IF MCC_RETURN_AT_APOAPSIS <= 0
            OR _mccAerobrakePatchSafe(SHIP:ORBIT,target,targetPe) { RETURN TRUE. }
    IF SHIP:STATUS <> "ORBITING" OR SHIP:ALTITUDE <= target:ATM:HEIGHT
            OR NOT (SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
            AND VDOT(SHIP:POSITION-target:POSITION,SHIP:VELOCITY:ORBIT) > 0) {
        RETURN TRUE.
    }
    LOCAL wakeUt IS TIME:SECONDS+ETA:APOAPSIS-300.
    IF NOT (ETA:APOAPSIS > 0 AND ETA:APOAPSIS < 1e30)
            OR SHIP:ORBIT:HASNEXTPATCH {
        _mccReturnHold("unsafe-apoapsis-coast"). RETURN FALSE.
    }
    IF wakeUt <= TIME:SECONDS { RETURN TRUE. }
    LOCAL alarmId IS kacEnsureAlarm("Return apoapsis planning",wakeUt,
        "Running recovery wakes to solve the live Kerbin entry burn before apoapsis.").
    mLog("STATS return-mcc apoapsis-wake ut=" + wakeUt
        + " eta=" + (wakeUt-TIME:SECONDS) + " alarm=" + alarmId).
    LOCAL solarRef IS enterSolarCoast("Return apoapsis coast",TRUE,TRUE,wakeUt).
    waitUntilOrSOI(target,wakeUt,5,alarmId,solarRef,TRUE,TRUE).
    IF alarmId <> "" { DELETEALARM(alarmId). }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF ABORT OR SHIP:BODY:NAME <> target:NAME OR HASNODE
            OR SHIP:ORBIT:HASNEXTPATCH OR TIME:SECONDS < wakeUt {
        _mccReturnHold("apoapsis-coast-interrupted"). RETURN FALSE.
    }
    RETURN TRUE.
}

// Return MCC owns acquisition of the entry corridor. Work in Kerbin's
// frame as soon as the moon escape completes, then measure the flown
// orbit after each burn. An optional-correction skip must never count as
// a successful reentry acquisition. Preserve plane and landing hardware.
LOCAL FUNCTION _mccReturn {
    PARAMETER target, targetPe.
    IF maneuverBurnInterrupted() {
        _mccReturnHold("interrupted-burn-inspect-retained-node"). RETURN.
    }
    IF _getTargetPatch(SHIP, target) = 0 {
        _mccReturnHold("no-Kerbin-patch"). RETURN.
    }
    IF SHIP:BODY:NAME <> target:NAME { waitForSOI(target). }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF ABORT OR SHIP:BODY:NAME <> target:NAME {
        _mccReturnHold("Kerbin-soi-wait-interrupted"). RETURN.
    }
    IF NOT _mccReturnApoapsisCoast(target,targetPe) { RETURN. }

    // Three finite-burn corrections, each planned from the measured orbit.
    FROM { LOCAL attempt IS 0. } UNTIL attempt > 3 STEP { SET attempt TO attempt + 1. } DO {
        IF _mccAerobrakePatchSafe(SHIP:ORBIT, target, targetPe) {
            mLog("STATS return-mcc status=verified PeKm="
                + ROUND(SHIP:PERIAPSIS / 1000, 3) + " burns=" + attempt).
            nextPhase(xferSeq). RETURN.
        }
        IF attempt = 3 { BREAK. }
        IF ABORT { _mccReturnHold("abort-requested"). RETURN. }
        IF SHIP:ALTITUDE <= target:ATM:HEIGHT OR ETA:PERIAPSIS < 600 {
            _mccReturnHold("too-late-for-return-correction"). RETURN.
        }
        LOCAL cap IS _mccReturnBudget().
        IF cap <= 0 { _mccReturnHold("fuel-reserve"). RETURN. }
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL nd IS NODE(TIME:SECONDS + 120, 0, 0, 0).
        ADD nd.
        WAIT 0.1.
        mLog("STATS return-mcc setup attempt=" + (attempt + 1)
            + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 3)
            + " targetPeKm=" + ROUND(targetPe / 1000, 3)
            + " dvCap=" + ROUND(cap, 1)
            + " configuredCap=" + MCC_RETURN_DV_CAP
            + " reserveDv=" + MCC_RETURN_RESERVE_DV
            + " activeDv=" + ROUND(STAGE:DELTAV:VACUUM,1)
            + " totalDv=" + ROUND(SHIP:DELTAV:VACUUM,1)
            + " stageFloor=" + BURN_STAGE_LIMIT).
        newtonTarget(nd, target, "PE", targetPe, LEX("DV_CAP", cap, "TOL", 250)).
        WAIT 0.1.
        LOCAL planned IS _getTargetPatch(nd, target).
        LOCAL peOk IS _mccAerobrakePatchSafe(planned, target, targetPe).
        LOCAL plannedPe IS -9999.
        IF planned <> 0 { SET plannedPe TO planned:PERIAPSIS / 1000. }
        LOCAL dv IS nd:DELTAV:MAG.
        mLog("STATS return-mcc plan dv=" + ROUND(dv, 3)
            + " PeKm=" + ROUND(plannedPe, 3)
            + " corridorOk=" + peOk + " dvCap=" + ROUND(cap, 1)).
        IF NOT peOk OR dv > cap OR nd:TIME < TIME:SECONDS + 30 {
            REMOVE nd.
            _mccReturnHold("no-corridor-solution-within-budget"). RETURN.
        }
        // Far from Kerbin, sub-2 m/s burns can be essential. Do not use
        // the legacy optional-MCC minimum; allow finer executor cutoff.
        LOCAL oldAbs IS BURN_TRIM_ABS_COMPLETE_DV.
        LOCAL oldMax IS BURN_TRIM_COMPLETE_MAX_DV.
        SET BURN_TRIM_ABS_COMPLETE_DV TO MIN(oldAbs, 0.005).
        SET BURN_TRIM_COMPLETE_MAX_DV TO MIN(oldMax, 0.005).
        LOCAL success IS executeManeuver().
        SET BURN_TRIM_ABS_COMPLETE_DV TO oldAbs.
        SET BURN_TRIM_COMPLETE_MAX_DV TO oldMax.
        IF NOT success {
            _mccReturnHold("burn-failed-inspect-retained-node"). RETURN.
        }
        WAIT 1.
        mLog("STATS return-mcc flown PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 3)
            + " targetPeKm=" + ROUND(targetPe / 1000, 3)).
    }
    _mccReturnHold("flown-orbit-outside-corridor").
}

// ============================================================
GLOBAL FUNCTION phaseMidCourse {
    LOCAL target IS missionTargetBody().

    IF CAPTURE_PE < 0 {
        IF _mccIsAerobrakeReturn(target) {
            _mccReturnHold("missing-entry-periapsis"). RETURN.
        }
        mLog("No CAPTURE_PE. Skipping MCC.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL targetPe  IS CAPTURE_PE.
    IF _mccIsAerobrakeReturn(target) {
        _mccReturn(target, targetPe).
        RETURN.
    }
    LOCAL targetInc IS -1.
    LOCAL targetLan IS -1.
    LOCAL targetAoP IS -1.

    // Resolve CAPTURE_DIR to inclination
    IF CAPTURE_DIR <> "" {
        LOCAL dir IS CAPTURE_DIR.
        IF dir = "PROGRADE"   { SET targetInc TO 0. }
        IF dir = "POLAR"      { SET targetInc TO 90. }
        IF dir = "RETROPOLAR" { SET targetInc TO 90. }
        IF dir = "RETROGRADE" { SET targetInc TO 180. }
    }
    SET targetInc TO CAPTURE_INC.
    SET targetLan TO CAPTURE_LAN.
    SET targetAoP TO CAPTURE_AOP.
    IF targetAoP >= 0 AND targetLan < 0 {
        mLog("MCC: Ignoring CAPTURE_AOP without CAPTURE_LAN.").
        SET targetAoP TO -1.
    }

    LOCAL alreadyAtTarget IS SHIP:BODY:NAME = target:NAME.
    LOCAL patch IS _getTargetPatch(SHIP, target).
    IF patch = 0 {
        mLogWarn("No encounter with " + target:NAME + ". Skipping MCC.").
        nextPhase(xferSeq).
        RETURN.
    }

    LOCAL waitTime IS 0.
    IF alreadyAtTarget {
        SET waitTime TO MAX(60, MIN(1800, ETA:PERIAPSIS * 0.25)).
        mLog("MCC: Already inside " + target:NAME
            + " SOI — correcting current approach in "
            + ROUND(waitTime, 0) + "s.").
    } ELSE IF SHIP:ORBIT:NEXTPATCH:BODY:NAME <> target:NAME {
        SET waitTime TO ETA:TRANSITION + 3600.
        mLog("MCC: Interplanetary — coast " + ROUND(waitTime) + "s past SOI.").
    } ELSE {
        // Fire at ~50% of distance to SOI, not 50% of time. On the
        // outbound transfer leg the ship decelerates, so half-time
        // overshoots half-distance. Earlier corrections are cheaper.
        LOCAL soiPos IS POSITIONAT(SHIP, TIME:SECONDS + ETA:TRANSITION).
        LOCAL halfDist IS (soiPos - SHIP:POSITION):MAG / 2.
        LOCAL tLo IS 60.
        LOCAL tHi IS ETA:TRANSITION.
        FROM { LOCAL bi IS 0. } UNTIL bi >= 12 STEP { SET bi TO bi + 1. } DO {
            LOCAL tMid IS (tLo + tHi) / 2.
            LOCAL d IS (POSITIONAT(SHIP, TIME:SECONDS + tMid) - SHIP:POSITION):MAG.
            IF d < halfDist { SET tLo TO tMid. } ELSE { SET tHi TO tMid. }
        }
        SET waitTime TO (tLo + tHi) / 2.
        mLog("MCC: Local — coast to half-distance (" + ROUND(waitTime) + "s, transition=" + ROUND(ETA:TRANSITION) + "s).").
    }

    mLog("MCC: Pre-correction  Pe=" + ROUND(patch:PERIAPSIS/1000,1) + "km"
        + "  AoP=" + ROUND(patch:ARGUMENTOFPERIAPSIS,1)
        + "°  LAN=" + ROUND(patch:LAN,1) + "°.").
    mLog("STATS mcc setup target=" + target:NAME
        + " targetPeKm=" + ROUND(targetPe/1000,1)
        + " targetInc=" + ROUND(targetInc,1)
        + " targetLAN=" + ROUND(targetLan,1)
        + " targetAoP=" + ROUND(targetAoP,1)
        + " startPeKm=" + ROUND(patch:PERIAPSIS/1000,1)
        + " startInc=" + ROUND(patch:INCLINATION,1)
        + " startLAN=" + ROUND(patch:LAN,1)
        + " startAoP=" + ROUND(patch:ARGUMENTOFPERIAPSIS,1)).

    LOCAL aerobrakeReturn IS _mccIsAerobrakeReturn(target).
    IF aerobrakeReturn AND _mccAerobrakePatchSafe(patch, target, targetPe) {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        mLogWarn("MCC: current Kerbin aerobrake Pe is safe ("
            + ROUND(patch:PERIAPSIS/1000, 1)
            + "km); skipping optional correction.").
        mLog("STATS mcc result target=" + target:NAME
            + " status=skipped reason=safe-aerobrake-corridor"
            + " dv=0"
            + " PeKm=" + ROUND(patch:PERIAPSIS/1000,1)
            + " safeMinKm=" + ROUND(_mccAerobrakeSafePeMin(target, targetPe)/1000,1)
            + " safeMaxKm=" + ROUND(_mccAerobrakeSafePeMax(target, targetPe)/1000,1)
            + " targetPeKm=" + ROUND(targetPe/1000,1)).
        orbitSummary().
        nextPhase(xferSeq).
        RETURN.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    LOCAL nd IS NODE(TIME:SECONDS + waitTime, 0, 0, 0).
    ADD nd.
    WAIT 0.1.

    LOCAL mccOpts IS LEXICON("DV_CAP", MCC_DV_CAP).
    LOCAL elementTargets IS LEXICON().
    elementTargets:ADD("PE", targetPe).
    IF targetInc >= 0 { elementTargets:ADD("INC", targetInc). }
    IF targetLan >= 0 { elementTargets:ADD("LAN", targetLan). }
    IF targetAoP >= 0 { elementTargets:ADD("AOP", targetAoP). }
    LOCAL useElementSolver IS FALSE.
    IF targetLan >= 0 OR targetAoP >= 0 { SET useElementSolver TO TRUE. }

    // Local polar approaches couple PE and INC strongly. Running INC and
    // PE as independent Newton passes can turn a good 20km encounter into
    // a high flyby. LAN and AoP have the same problem, so when they are
    // requested we score all requested elements together. The unified
    // element solver handles PE-only, PE+INC, and PE+INC+LAN+AoP.
    LOCAL preCost IS 0.
    IF useElementSolver OR targetInc >= 0 {
        LOCAL preElemEval IS _patchElementsCostFromPatch(patch, elementTargets).
        SET preCost TO preElemEval["COST"].
        LOCAL elemOpts IS LEXICON().
        elemOpts:ADD("DV_CAP", MCC_DV_CAP).
        elemOpts:ADD("STEP_NORMAL", 2.0).
        elemOpts:ADD("STEP_PROGRADE", 1.0).
        elemOpts:ADD("STEP_RADIAL", 1.0).
        elemOpts:ADD("STEP_TIME", 120.0).
        elemOpts:ADD("MIN_STEP", 0.02).
        elemOpts:ADD("MAX_ITER", CHOOSE 100 IF useElementSolver ELSE 80).
        elemOpts:ADD("MIN_TIME", TIME:SECONDS + 60).
        _targetPatchElementsCoupled(nd, target, elementTargets, elemOpts).
    } ELSE {
        newtonTarget(nd, target, "PE", targetPe, mccOpts).
    }

    WAIT 0.1.

    LOCAL totalDv IS nd:DELTAV:MAG.
    LOCAL finalPatch IS _getTargetPatch(nd, target).
    LOCAL finalPeKm IS -9999.
    IF finalPatch <> 0 { SET finalPeKm TO finalPatch:PERIAPSIS / 1000. }
    LOCAL unsafeAerobrakeFinal IS FALSE.
    IF aerobrakeReturn AND finalPatch <> 0 {
        SET unsafeAerobrakeFinal TO NOT _mccAerobrakePatchSafe(finalPatch, target, targetPe).
    }
    LOCAL minMccDv IS MCC_MIN_DV.
    SET minMccDv TO MCC_MIN_DV.
    LOCAL lateEta IS ETA:PERIAPSIS.
    IF SHIP:ORBIT:HASNEXTPATCH { SET lateEta TO ETA:TRANSITION. }
    IF lateEta < MCC_LATE_ETA {
        SET minMccDv TO MAX(minMccDv, MCC_LATE_MIN_DV).
        SET minMccDv TO MCC_LATE_MIN_DV.
    }

    LOCAL worsened IS FALSE.
    IF (useElementSolver OR targetInc >= 0) AND finalPatch <> 0 {
        LOCAL finalElemEval IS _patchElementsCostFromPatch(finalPatch, elementTargets).
        LOCAL finalElemCost IS finalElemEval["COST"].
        IF finalElemCost > preCost * 1.05 { SET worsened TO TRUE. }
        IF ABS(finalElemEval["PE_ERR"]) > 100000 { SET worsened TO TRUE. }
    }

    IF totalDv < minMccDv OR finalPatch = 0 OR worsened OR unsafeAerobrakeFinal {
        IF worsened {
            mLogWarn("MCC made approach worse; skipping correction node.").
        } ELSE IF unsafeAerobrakeFinal {
            mLogWarn("MCC final Pe outside safe aerobrake corridor; skipping correction node.").
        } ELSE IF totalDv < minMccDv {
            mLogWarn("MCC correction below threshold; skipping correction node.").
        }
        mLog("Encounter on target. Skipping MCC burn.").
        mLog("STATS mcc result target=" + target:NAME
            + " status=skipped dv=" + ROUND(totalDv,1)
            + " minDv=" + ROUND(minMccDv,1)
            + " PeKm=" + ROUND(finalPeKm,1)
            + " worsened=" + worsened
            + " unsafeAerobrakeFinal=" + unsafeAerobrakeFinal).
        REMOVE nd.
    } ELSE {
        LOCAL logMsg IS "MCC planned: dV=" + ROUND(totalDv, 1)
            + " m/s  Pe=" + ROUND(finalPatch:PERIAPSIS/1000,1) + "km".
        IF targetInc >= 0 {
            SET logMsg TO logMsg + "  INC=" + ROUND(finalPatch:INCLINATION,1) + "°".
        }
        IF targetLan >= 0 {
            SET logMsg TO logMsg + "  LAN=" + ROUND(finalPatch:LAN,1) + "°".
        }
        IF targetAoP >= 0 {
            SET logMsg TO logMsg + "  AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1) + "°".
        }
        mLog(logMsg).
        mLog("STATS mcc result target=" + target:NAME
            + " status=planned dv=" + ROUND(totalDv,1)
            + " PeKm=" + ROUND(finalPatch:PERIAPSIS/1000,1)
            + " inc=" + ROUND(finalPatch:INCLINATION,1)
            + " LAN=" + ROUND(finalPatch:LAN,1)
            + " AoP=" + ROUND(finalPatch:ARGUMENTOFPERIAPSIS,1)).
        maneuverUiArchiveLog("mcc").
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                IF retries >= MAX_RETRIES {
                    mLogError("MCC failed. Abandoning.").
                    IF HASNODE { REMOVE NEXTNODE. }
                    BREAK.
                }
                WAIT 10.
            }
        }
    }
    orbitSummary().
    nextPhase(xferSeq).
}

GLOBAL FUNCTION phaseMcc {
    phaseMidCourse().
}
