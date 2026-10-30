// Arrival intent, actual future events and bounded execution-time evidence.
// No nodes, control commands or persistence in this library.
@LAZYGLOBAL OFF.
GLOBAL BPLANE_ARRIVAL_MODE IS "ORBIT".
GLOBAL BPLANE_SOLVE_ALLOWANCE IS 120.

GLOBAL FUNCTION arrivalModeOk {
    PARAMETER targetBody.
    PARAMETER desiredPe.
    IF NOT (desiredPe > 0 AND desiredPe < targetBody:SOIRADIUS-targetBody:RADIUS) { RETURN FALSE. }
    IF BPLANE_ARRIVAL_MODE = "ENTRY" {
        IF NOT targetBody:ATM:EXISTS { RETURN FALSE. }
        RETURN BPLANE_PE_TOL > 0 AND desiredPe-BPLANE_PE_TOL > 0
            AND desiredPe+BPLANE_PE_TOL < targetBody:ATM:HEIGHT.
    }
    IF BPLANE_ARRIVAL_MODE <> "ORBIT" AND BPLANE_ARRIVAL_MODE <> "FLYBY" { RETURN FALSE. }
    IF targetBody:ATM:EXISTS { RETURN desiredPe >= targetBody:ATM:HEIGHT. }
    RETURN TRUE.
}

GLOBAL FUNCTION arrivalPatchPeUt {
    PARAMETER patch.
    PARAMETER startUt.
    LOCAL peUt IS TIME:SECONDS+patch:ETA:PERIAPSIS.
    IF NOT (peUt > startUt AND peUt < 1e30) { RETURN -1. }
    IF patch:HASNEXTPATCH {
        IF NOT (peUt < TIME:SECONDS+patch:NEXTPATCHETA) { RETURN -1. }
    }
    RETURN peUt.
}

// Actual inbound radius crossing on this native patch, not an extrapolated
// periapsis beyond an intervening moon/escape. Return an absolute epoch.
GLOBAL FUNCTION arrivalPatchRadiusUt {
    PARAMETER patch.
    PARAMETER altitude.
    PARAMETER startUt.
    LOCAL peUt IS arrivalPatchPeUt(patch,startUt).
    LOCAL rp IS patch:BODY:RADIUS+patch:PERIAPSIS.
    LOCAL crossing IS patch:BODY:RADIUS+altitude.
    LOCAL ecc IS patch:ECCENTRICITY.
    IF NOT (peUt > 0 AND rp > 0 AND rp < crossing
            AND ecc > 0.000001 AND ecc < 1e30 AND patch:BODY:MU > 0) { RETURN -1. }
    LOCAL latus IS rp*(1+ecc).
    LOCAL cosine IS (latus/crossing-1)/ecc.
    IF NOT (cosine > -1 AND cosine < 1) { RETURN -1. }
    LOCAL beforePe IS conicTimeFromPe(ecc,latus,patch:BODY:MU,
        cosine,SQRT(MAX(0,1-cosine^2))).
    LOCAL crossingUt IS peUt-beforePe.
    IF NOT (crossingUt > startUt AND crossingUt < peUt) { RETURN -1. }
    RETURN crossingUt.
}

GLOBAL FUNCTION arrivalCoastPolicyOk {
    PARAMETER hit.
    PARAMETER targetBody.
    PARAMETER desiredPe.
    IF NOT arrivalModeOk(targetBody,desiredPe) { RETURN FALSE. }
    // Airless coast retains its existing parent-clearance/Pe/SOI proof.
    IF NOT targetBody:ATM:EXISTS { RETURN TRUE. }
    // Atmospheric destinations additionally need a real upcoming Pe on
    // this patch. An Ike-truncated Duna conic is not a Duna-entry solution.
    RETURN arrivalPatchPeUt(hit["patch"],hit["entryUt"]) > hit["entryUt"]+60.
}

GLOBAL FUNCTION arrivalGoalPolicyOk {
    PARAMETER hit.
    PARAMETER targetBody.
    PARAMETER desiredPe.
    IF NOT arrivalCoastPolicyOk(hit,targetBody,desiredPe) { RETURN FALSE. }
    LOCAL actualPe IS hit["patch"]:PERIAPSIS.
    IF NOT (actualPe > 0 AND actualPe < targetBody:SOIRADIUS-targetBody:RADIUS) { RETURN FALSE. }
    IF NOT targetBody:ATM:EXISTS { RETURN TRUE. }
    IF BPLANE_ARRIVAL_MODE = "ENTRY" {
        RETURN arrivalPatchRadiusUt(hit["patch"],targetBody:ATM:HEIGHT,hit["entryUt"]) > hit["entryUt"].
    }
    RETURN actualPe >= targetBody:ATM:HEIGHT.
}

GLOBAL FUNCTION arrivalRequiredCaptureDv {
    PARAMETER patch.
    PARAMETER targetBody.
    IF BPLANE_ARRIVAL_MODE = "ENTRY" OR BPLANE_ARRIVAL_MODE = "FLYBY" { RETURN 0. }
    RETURN bplaneCaptureCost(patch,targetBody).
}

// Conservative duration from measured limited thrust and current wet mass.
// Reserve time for taper; a staged burn also uses the weakest attached
// throttleable engine and the existing bounded manual-staging allowance.
GLOBAL FUNCTION arrivalBurnSeconds {
    PARAMETER dv.
    IF NOT (dv >= 0 AND dv < 1e30 AND SHIP:MASS > 0 AND SHIP:MASS < 1e30) { RETURN -1. }
    LOCAL activeThrust IS 0.
    LOCAL weakest IS 1e30.
    FOR eng IN SHIP:ENGINES {
        IF NOT eng:THROTTLELOCK AND eng:AVAILABLETHRUST > 0 AND eng:THRUSTLIMIT > 0 {
            LOCAL limited IS eng:AVAILABLETHRUST.
            SET weakest TO MIN(weakest,limited).
            IF eng:IGNITION AND NOT eng:FLAMEOUT { SET activeThrust TO activeThrust+limited. }
        }
    }
    IF NOT (activeThrust > 0 AND activeThrust < 1e30) { RETURN -1. }
    LOCAL acceleration IS activeThrust/SHIP:MASS.
    LOCAL stageTime IS 0.
    IF NOT (STAGE:DELTAV:VACUUM >= dv AND STAGE:DELTAV:VACUUM < 1e30) {
        IF NOT (weakest > 0 AND weakest < 1e30) { RETURN -1. }
        SET acceleration TO MIN(acceleration,weakest/SHIP:MASS).
        SET stageTime TO MAX(0,BURN_STAGE_MAX_EVENTS)
            *MAX(0,BURN_STAGE_MANUAL_WAIT+BURN_STAGE_TIMEOUT+BURN_STAGE_SETTLE).
    }
    RETURN 2*dv/acceleration+MAX(2,BURN_MIN_FULL_THRUST_SECONDS)+stageTime.
}

// Same midpoint placement used by both the scheduler and node creation.
// For long burns the midpoint moves later to leave solver/alignment time;
// the remaining half burn must still fit before the SOI boundary.
GLOBAL FUNCTION arrivalCorrectionLead {
    PARAMETER duration.
    RETURN MAX(BPLANE_LEAD,duration/2+BPLANE_SOLVE_ALLOWANCE
        +MAX(30,BPLANE_EXISTING_NODE_MIN_ETA)).
}

// At most one geometry/sensitivity approach check, then one final check.
// The caller owns persistence, KAC and the no-repeated-checkpoint contract.
GLOBAL FUNCTION arrivalRetryTiming {
    PARAMETER hit.
    PARAMETER correctionCap.
    PARAMETER minimumDv.
    PARAMETER solutionDv IS -1.
    PARAMETER finalOnly IS FALSE.
    LOCAL plan IS LEXICON("OK",FALSE,"WAKE",0,"LATEST",0,"CHECKPOINT","final").
    LOCAL duration IS arrivalBurnSeconds(correctionCap).
    IF NOT (duration >= 0 AND duration < 1e30 AND BPLANE_SOLVE_ALLOWANCE >= 0
            AND BPLANE_FINAL_REFINE_LEAD >= 0) { RETURN plan. }
    LOCAL executionLead IS MAX(300,arrivalCorrectionLead(duration))
        +duration/2+SOI_BUFFER_TIME+MIDCOURSE_REFINE_MARGIN.
    // Wake before the admissible deadline, allowing polling/settling jitter.
    LOCAL finalUt IS hit["entryUt"]-MAX(BPLANE_FINAL_REFINE_LEAD,
        executionLead+MAX(1,MIDCOURSE_REFINE_MARGIN)).
    SET plan["LATEST"] TO hit["entryUt"]-executionLead.
    SET plan["WAKE"] TO finalUt.
    LOCAL peUt IS arrivalPatchPeUt(hit["patch"],hit["entryUt"]).
    IF NOT finalOnly AND peUt-hit["entryUt"] > 4*MAX(BPLANE_FINAL_REFINE_LEAD,executionLead) {
        // Long planetary SOI transits earn an earlier approach checkpoint.
        LOCAL approachUt IS hit["entryUt"]-MAX(MAX(BPLANE_FINAL_REFINE_LEAD,executionLead),
            0.25*(peUt-hit["entryUt"])).
        // Lever-arm estimate from the solved sub-minimum impulse. This is a
        // scheduling estimate only; every retry still solves native patches.
        IF solutionDv > 0 AND solutionDv <= minimumDv {
            LOCAL usefulUt IS peUt-(peUt-TIME:SECONDS)*solutionDv/(1.5*minimumDv).
            SET approachUt TO MIN(approachUt,usefulUt).
        }
        SET approachUt TO MAX(TIME:SECONDS+MIDCOURSE_REFINE_MIN_LEAD,approachUt).
        IF approachUt+MIDCOURSE_REFINE_MIN_LEAD < finalUt {
            SET plan["WAKE"] TO approachUt.
            SET plan["CHECKPOINT"] TO "approach".
        }
    }
    SET plan["OK"] TO plan["WAKE"] > 0 AND plan["LATEST"] > TIME:SECONDS.
    SET plan["BURN_SECONDS"] TO duration.
    SET plan["PE_UT"] TO peUt.
    RETURN plan.
}
