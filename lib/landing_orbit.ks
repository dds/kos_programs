// ============================================================
// landing_orbit.ks - Generic preparation of a landing parking orbit.
// (0:/lib/landing_orbit.ks)
// Separate from contract SHAPE and from target-specific LAND_DEORBIT.
// ============================================================
@LAZYGLOBAL OFF.

LOCAL FUNCTION _landPrepStable {
    LOCAL floorAlt IS 0.
    IF SHIP:BODY:ATM:EXISTS { SET floorAlt TO SHIP:BODY:ATM:HEIGHT. }
    RETURN NOT ABORT AND NOT phaseShouldYield AND SHIP:STATUS = "ORBITING"
        AND SHIP:PERIAPSIS > floorAlt AND SHIP:ORBIT:ECCENTRICITY >= 0
        AND SHIP:ORBIT:ECCENTRICITY < 1 AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}
LOCAL FUNCTION _landPrepAdmit {
    PARAMETER nd.
    PARAMETER targets.
    LOCAL orbitAfter IS nd:ORBIT.
    LOCAL cost IS nd:DELTAV:MAG.
    LOCAL ledger IS stateGet("land_prep_budget",LEXICON("SPENT",0,"NODE_UT",-1,"NODE_DV",0)).
    LOCAL spent IS ledger["SPENT"].
    LOCAL additional IS cost.
    IF ABS(nd:TIME-ledger["NODE_UT"]) < 0.5 { SET additional TO MAX(0,cost-ledger["NODE_DV"]). }
    LOCAL available IS SHIP:DELTAV:VACUUM.
    LOCAL stockStage IS STAGE:DELTAV:VACUUM.
    // The common planner validates plane/apsis improvement and its Pe floor.
    // Admission also preserves the current propulsion stage and return fuel.
    LOCAL allowed IS _landPrepStable() AND ledger["CONTEXT"] = landingOrbitContext() AND nd:ETA >= 60
        AND cost >= LAND_PREP_MIN_BURN_DV AND cost <= LAND_PREP_DV_CAP
        AND spent+additional <= LAND_PREP_TOTAL_DV_CAP
        AND available-cost >= LAND_PREP_RESERVE_DV AND stockStage >= cost+10
        AND SHIP:AVAILABLETHRUST > 0 AND orbitAfter:ECCENTRICITY < 1
        AND NOT orbitAfter:HASNEXTPATCH AND orbitAfter:PERIAPSIS >= SHAPE_MIN_PE.
    LOCAL beforePlane IS _landPrepPlaneError(SHIP:ORBIT,targets).
    LOCAL afterPlane IS _landPrepPlaneError(orbitAfter,targets).
    LOCAL improved IS ABS(orbitAfter:APOAPSIS-targets["AP"])+1 < ABS(SHIP:APOAPSIS-targets["AP"])
        OR ABS(orbitAfter:PERIAPSIS-targets["PE"])+1 < ABS(SHIP:PERIAPSIS-targets["PE"])
        OR afterPlane+0.001 < beforePlane.
    SET allowed TO allowed AND improved
        AND (beforePlane > LAND_PREP_ANG_TOL OR afterPlane <= LAND_PREP_ANG_TOL).
    mLog("STATS land-prep budget allowed=" + allowed + " dv=" + cost + " spent=" + spent
        + " available=" + available + " currentStageDv=" + stockStage
        + " reserve=" + LAND_PREP_RESERVE_DV + " totalCap=" + LAND_PREP_TOTAL_DV_CAP).
    RETURN allowed.
}

LOCAL FUNCTION _landPrepPlaneError {
    PARAMETER orbitInfo.
    PARAMETER targets.
    RETURN ARCCOS(MAX(-1,MIN(1,COS(orbitInfo:INCLINATION)*COS(targets["INC"])
        +SIN(orbitInfo:INCLINATION)*SIN(targets["INC"])*COS(orbitInfo:LAN-targets["LAN"])))).
}

LOCAL FUNCTION _landPrepRun {
    PARAMETER targets.
    IF maneuverBurnInterrupted() OR stateGet("deorbit_burn_started","false") = "true" {
        mLogError("LAND_PREP: interrupted burn retained; inspect the achieved orbit and node before retrying.").
        PRINT "After inspection: RUNPATH('0:/cmd/shaperetry.ks'). then REBOOT. to replan the achieved orbit.".
        yieldToPrompt(). RETURN FALSE.
    }
    LOCAL ledger IS stateGet("land_prep_budget",LEXICON()).
    LOCAL prepContext IS landingOrbitContext().
    IF HASNODE AND ABS(NEXTNODE:TIME-ledger["NODE_UT"]) >= 0.5 {
        mLogError("LAND_PREP: unrelated node preserved; review before preparing the orbit.").
        yieldToPrompt(). RETURN FALSE.
    }
    LOCAL attempts IS 0.
    UNTIL shapeConverged(targets) OR attempts >= 6 OR ABORT OR phaseShouldYield
            OR landingOrbitContext() <> prepContext {
        LOCAL planned IS 0.
        LOCAL created IS FALSE.
        IF HASNODE {
            // Only an unflown node recorded by this phase may resume after
            // reboot. Foreign nodes and partly flown burns are never removed.
            IF ABS(NEXTNODE:TIME-ledger["NODE_UT"]) >= 0.5 {
                mLogError("LAND_PREP: existing maneuver is not this phase's pending node; node preserved.").
                yieldToPrompt(). RETURN FALSE.
            }
            SET planned TO LEXICON("node",NEXTNODE,"label","retained-preparation").
        } ELSE {
            SET planned TO shapeNextBurn(targets).
            SET created TO TRUE.
        }
        IF NOT planned:ISTYPE("Lexicon") {
            mLogError("LAND_PREP: no safe correction meets the preparation tolerances/minimum.").
            yieldToPrompt(). RETURN FALSE.
        }
        LOCAL nd IS NEXTNODE.
        IF NOT _landPrepAdmit(nd,targets) {
            IF created { REMOVE nd. }
            mLogError("LAND_PREP: preparation exceeds orbit/fuel/stage limits; no burn started. Retained nodes are preserved.").
            yieldToPrompt(). RETURN FALSE.
        }
        LOCAL nodeUt IS nd:TIME.
        // Reboots during the executor's long KAC/solar coast reuse the same
        // already-reserved node, rather than charging another burn.
        // stateGet returns the cached Lexicon itself. Copy before changing
        // it, or stateSet's unchanged-value check can suppress the flush.
        SET ledger TO ledger:COPY.
        LOCAL additional IS nd:DELTAV:MAG.
        IF ABS(nodeUt-ledger["NODE_UT"]) < 0.5 { SET additional TO MAX(0,additional-ledger["NODE_DV"]). }
        SET ledger["SPENT"] TO ledger["SPENT"]+additional.
        SET ledger["NODE_UT"] TO nodeUt.
        SET ledger["NODE_DV"] TO nd:DELTAV:MAG.
        // One state update contains ownership AND the reserved cost.
        stateSet("land_prep_budget",ledger).
        IF NOT _landPrepStable() OR landingOrbitContext() <> prepContext OR NOT HASNODE {
            mLogWarn("LAND_PREP: context changed while recording the plan; no burn started.").
            yieldToPrompt(). RETURN FALSE.
        }
        IF ABS(NEXTNODE:TIME-nodeUt) >= 0.5 {
            mLogWarn("LAND_PREP: the next node changed; maneuver preserved, no burn started.").
            yieldToPrompt(). RETURN FALSE.
        }
        mLog("STATS land-prep execution label=" + planned["label"]
            + " dv=" + nd:DELTAV:MAG + " nodeUt=" + nodeUt + " stageFloor=" + BURN_STAGE_LIMIT).
        LOCAL ok IS executeManeuver().
        LOCAL stopped IS thrustCutoffOk().
        IF NOT ok OR NOT stopped OR maneuverBurnInterrupted() OR ABORT OR phaseShouldYield {
            mLogError("LAND_PREP: execution incomplete; node/achieved orbit retained for review.").
            yieldToPrompt(). RETURN FALSE.
        }
        SET ledger TO ledger:COPY.
        SET ledger["NODE_UT"] TO -1.
        SET ledger["NODE_DV"] TO 0.
        stateSet("land_prep_budget",ledger).
        SET attempts TO attempts+1.
        WAIT 1.
    }
    LOCAL solved IS _landPrepStable() AND NOT HASNODE AND landingOrbitContext() = prepContext AND shapeConverged(targets)
        AND SHIP:PERIAPSIS >= SHAPE_MIN_PE.
    mLog("STATS land-prep result solved=" + solved + " burns=" + attempts
        + " Ap=" + SHIP:APOAPSIS + " Pe=" + SHIP:PERIAPSIS
        + " inc=" + SHIP:ORBIT:INCLINATION + " spent=" + ledger["SPENT"]).
    IF NOT solved { yieldToPrompt(). }
    IF solved AND ledger["NODE_UT"] >= 0 {
        SET ledger TO ledger:COPY.
        SET ledger["NODE_UT"] TO -1.
        SET ledger["NODE_DV"] TO 0.
        stateSet("land_prep_budget",ledger).
    }
    RETURN solved.
}

// Inspect the next band's local dependency closure without syncing/loading
// it into this band's limited volume. Cached transitions work offline.
LOCAL FUNCTION _landPrepNextCached {
    LOCAL i IS 0.
    UNTIL i >= xferSeq:LENGTH {
        IF xferSeq[i] = "LAND_PREP" {
            IF i+1 >= xferSeq:LENGTH { RETURN TRUE. }
            LOCAL band IS bootLibBandForPhase(xferSeq[i+1],"").
            LOCAL roots IS bootLibBandRoots(band).
            missionAppendUnique(roots,missionTypeConditionalRoots(band)).
            IF LIBS:LENGTH > 0 {
                SET roots TO LIST().
                FOR ln IN LIBS { roots:ADD(ln). }
            }
            missionAppendUnique(roots,missionExtraLibs()).
            LOCAL libs IS LIST().
            LOCAL deps IS dependencyLibs().
            FOR ln IN roots { bootLibAppendResolved(libs,ln,deps). }
            FOR ln IN libs {
                IF bootLibArchiveOnly(ln) OR bootLocalScriptPath(ln) = "" { RETURN FALSE. }
            }
            RETURN TRUE.
        }
        SET i TO i+1.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _landPrepLinkWait {
    LOCAL coastBody IS SHIP:BODY.
    UNTIL HOMECONNECTION:ISCONNECTED OR _landPrepNextCached()
            OR NOT _landPrepStable() OR HASNODE OR SHIP:BODY <> coastBody {
        LOCAL wakeUt IS TIME:SECONDS+MAX(60,MIN(300,SHIP:ORBIT:PERIOD/8)).
        LOCAL alarm IS kacEnsureAlarm("Landing orbit link check",wakeUt,"Check link before loading landing-deorbit band.").
        mLog("STATS land-prep wait reason=deorbit-library-link wakeUt=" + wakeUt + " alarm=" + alarm).
        LOCAL solarRef IS enterSolarCoast("Landing orbit link wait",TRUE,TRUE,wakeUt).
        waitUntilOrSOI(coastBody,wakeUt,10,alarm,solarRef,TRUE,TRUE).
        IF alarm <> "" { DELETEALARM(alarm). }
    }
    RETURN (HOMECONNECTION:ISCONNECTED OR _landPrepNextCached())
        AND SHIP:BODY = coastBody AND NOT HASNODE AND _landPrepStable().
}

GLOBAL FUNCTION phaseLandPrep {
    IF NOT _landPrepStable() OR NOT vesselLandingPrepareRoles() {
        mLogError("LAND_PREP requires a stable parking orbit, Abort clear, idle controls and valid hardware roles.").
        yieldToPrompt(). RETURN.
    }
    IF NOT (LAND_PREP_MIN_PE > 0 AND LAND_PREP_ALT_TOL > 0 AND LAND_PREP_ANG_TOL > 0
            AND LAND_PREP_MIN_BURN_DV > 0 AND LAND_PREP_DV_CAP >= LAND_PREP_MIN_BURN_DV
            AND LAND_PREP_TOTAL_DV_CAP >= 0 AND LAND_PREP_RESERVE_DV >= 0) {
        mLogError("LAND_PREP: invalid preparation tolerances, floor or fuel limits.").
        yieldToPrompt(). RETURN.
    }
    IF NOT xferSeq:CONTAINS("LAND_PREP") {
        mLogError("LAND_PREP must be included in the mission sequence.").
        yieldToPrompt(). RETURN.
    }
    LOCAL context IS landingOrbitContext().
    LOCAL request IS configLiteral(LIST(LAND_PREP_AP,LAND_PREP_PE,LAND_PREP_INC,LAND_PREP_LAN,LAND_PREP_MIN_PE)).
    LOCAL intent IS stateGet("land_prep_intent",LEXICON()).
    IF NOT intent:HASKEY("CONTEXT") OR intent["CONTEXT"] <> context OR intent["REQUEST"] <> request {
        IF HASNODE OR maneuverBurnInterrupted() {
            mLogError("LAND_PREP: a retained node/burn blocks changing the preparation goal.").
            yieldToPrompt(). RETURN.
        }
        LOCAL targets IS landingPrepTargets().
        IF targets:LENGTH = 0 {
            mLogError("LAND_PREP: invalid apsides/plane or target below the body safety floor.").
            yieldToPrompt(). RETURN.
        }
        SET intent TO LEXICON("CONTEXT",context,"REQUEST",request,"TARGETS",targets).
        stateSet("land_prep_intent",intent).
    }
    LOCAL ledger IS stateGet("land_prep_budget",LEXICON()).
    IF NOT ledger:HASKEY("CONTEXT") OR ledger["CONTEXT"] <> context {
        stateSet("land_prep_budget",LEXICON("CONTEXT",context,"SPENT",0,"NODE_UT",-1,"NODE_DV",0)).
    }
    stateRemove("landing_orbit_ready").
    LOCAL targets IS intent["TARGETS"].
    FOR row IN landingRouteLines(landingRouteSnapshot(targets)) { mLog(row). }
    mLog("STATS land-prep setup Ap=" + targets["AP"] + " Pe=" + targets["PE"]
        + " inc=" + targets["INC"] + " lan=" + targets["LAN"]
        + " altTolerance=" + LAND_PREP_ALT_TOL + " reserve=" + LAND_PREP_RESERVE_DV).
    // Scope only the common planner's control policy. Contract SHAPE goals,
    // precision settings and budget ledger are never rewritten.
    LOCAL priorAlt IS SHAPE_ALT_TOL.
    LOCAL priorAng IS SHAPE_ANG_TOL.
    LOCAL priorFloor IS SHAPE_MIN_PE.
    LOCAL priorMinimum IS SHAPE_MIN_BURN_DV.
    LOCAL priorStage IS BURN_STAGE_LIMIT.
    SET SHAPE_ALT_TOL TO LAND_PREP_ALT_TOL.
    SET SHAPE_ANG_TOL TO LAND_PREP_ANG_TOL.
    SET SHAPE_MIN_PE TO MAX(0,LAND_PREP_MIN_PE).
    IF SHIP:BODY:ATM:EXISTS { SET SHAPE_MIN_PE TO MAX(SHAPE_MIN_PE,SHIP:BODY:ATM:HEIGHT+10000). }
    SET SHAPE_MIN_BURN_DV TO LAND_PREP_MIN_BURN_DV.
    SET BURN_STAGE_LIMIT TO MAX(priorStage,vesselLandingStageFloor()).
    LOCAL solved IS _landPrepRun(targets).
    SET SHAPE_ALT_TOL TO priorAlt.
    SET SHAPE_ANG_TOL TO priorAng.
    SET SHAPE_MIN_PE TO priorFloor.
    SET SHAPE_MIN_BURN_DV TO priorMinimum.
    SET BURN_STAGE_LIMIT TO priorStage.
    IF NOT solved { RETURN. }
    stateSet("landing_orbit_ready",context).
    // Keep the timer RUNNING if the next band cannot yet be fetched. This
    // orbit is safe to wait in; an alarm is installed before every solar wait.
    IF NOT _landPrepLinkWait() {
        mLogWarn("LAND_PREP: link wait interrupted; keeping this phase.").
        yieldToPrompt(). RETURN.
    }
    nextPhase(xferSeq).
}
