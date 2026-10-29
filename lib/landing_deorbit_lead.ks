// ============================================================
// landing_deorbit_lead.ks - Link the ballistic and powered landing footprints.
// (0:/lib/landing_deorbit_lead.ks)
// Bounded orbital prediction only; never loads the powered-descent FSM.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingDeorbitLegacyLead {
    PARAMETER overrideAim IS 0.
    LOCAL aimM IS 15000.
    IF overrideAim > 0 { SET aimM TO overrideAim. }
    RETURN LEXICON("VALID",TRUE,"AIM",aimM,"MIN",10000,"MAX",20000,
        "REASON","legacy","RANGE",-1,"BALLISTIC",-1,"IGNITION_UT",0).
}

LOCAL FUNCTION _landingLeadStateAt {
    PARAMETER ut.
    PARAMETER targetElevation.
    PARAMETER hullClearance.
    LOCAL positionVec IS lmGroundPositionAt(ut).
    LOCAL velocityVec IS lmGroundVelocityAt(ut).
    LOCAL upVec IS positionVec:NORMALIZED.
    LOCAL geo IS lmGroundGeoAt(ut).
    LOCAL asl IS positionVec:MAG-SHIP:BODY:RADIUS.
    LOCAL terrain IS geo:TERRAINHEIGHT.
    RETURN LEXICON("HS",VXCL(upVec,velocityVec):MAG,
        "DOWN",MAX(0,-VDOT(velocityVec,upVec)),
        "HEIGHT",MIN(asl-targetElevation,asl-terrain-hullClearance),
        "LAT",geo:LAT,"LNG",geo:LNG,"ASL",asl,"TERRAIN",terrain,"HULL",hullClearance).
}

// Enclose every box corner about CoM, in any future attitude. Subtracting
// ALT:RADAR and BOTTOMALTRADAR mixes KSP and kOS terrain samples; their
// difference is not a physical hull dimension (native RO9 reported >2km).
// Snapshot the expensive vessel bounds once per forecast, not per gate probe.
LOCAL FUNCTION _landingLeadHullClearance {
    PARAMETER vesselBounds.
    PARAMETER centerOfMass.
    RETURN vesselBounds:EXTENTS:MAG+(vesselBounds:ABSCENTER-centerOfMass):MAG.
}

// Mirror both live ignition gates, including the fixed-site geographic gate.
// A forecast that assumes V-only ignition while flight burns at H cannot
// converge reliably. Native conic samples supply local terrain clearance.
LOCAL FUNCTION _landingLeadGateAt {
    PARAMETER ut.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER elevation.
    PARAMETER activeAcc.
    PARAMETER planAcc.
    PARAMETER stageDv.
    PARAMETER gravAcc.
    PARAMETER delay.
    PARAMETER stack.
    PARAMETER hullClearance.
    LOCAL sample IS _landingLeadStateAt(ut,elevation,hullClearance).
    LOCAL envelope IS lmStagedBrakeEnvelope(sample["HS"],sample["DOWN"],
        activeAcc,planAcc,stageDv,gravAcc,delay,TRUE).
    IF sample["HEIGHT"] <= envelope["V"] { RETURN TRUE. }
    IF LANDING_FLEXIBLE_SITE > 0 { RETURN FALSE. }
    LOCAL velocityVec IS lmGroundVelocityAt(ut).
    LOCAL positionVec IS lmGroundPositionAt(ut).
    LOCAL hVel IS VXCL(positionVec:NORMALIZED,velocityVec).
    IF hVel:MAG <= APPROACH_HSPEED { RETURN FALSE. }
    LOCAL targetVec IS LATLNG(targetLat,targetLng):ALTITUDEPOSITION(elevation)-SHIP:BODY:POSITION.
    LOCAL downrange IS VDOT(VXCL(positionVec:NORMALIZED,targetVec-positionVec),hVel:NORMALIZED).
    IF downrange <= 0 { RETURN sample["HEIGHT"] <= TERRAIN_SAFE_ALT. }
    LOCAL nominal IS lmNominalBrakeRange(sample["HS"],activeAcc,planAcc,stageDv,gravAcc,0,
        SHIP:BODY:RADIUS,sample["ASL"],2*MAX(0.05,LANDING_STAGE_SETTLE),stack).
    IF nominal < 0 { RETURN FALSE. }
    LOCAL etaLo IS 0.
    // The fixed-site modeled deadline does not depend on V-ETA. Avoid a
    // nested twelve-sample search when that extra condition is irrelevant.
    IF NOT lmHorizontalBrakeGateArmed(sample["HEIGHT"],999999,stack["VALID"]) {
        LOCAL etaHi IS MAX(120,LANDING_BRAKE_ALIGN_LEAD*2).
        LOCAL iteration IS 0.
        UNTIL iteration >= 12 {
            LOCAL coastTime IS (etaLo+etaHi)/2.
            LOCAL future IS lmStagedBrakeEnvelope(sample["HS"],sample["DOWN"]+gravAcc*coastTime,
                activeAcc,planAcc,stageDv,gravAcc,delay,TRUE).
            LOCAL futureHeight IS sample["HEIGHT"]-sample["DOWN"]*coastTime-gravAcc*coastTime^2/2.
            IF futureHeight <= future["V"] { SET etaHi TO coastTime. }
            ELSE { SET etaLo TO coastTime. }
            SET iteration TO iteration+1.
        }
        IF NOT lmHorizontalBrakeGateArmed(sample["HEIGHT"],etaLo,stack["VALID"]) { RETURN FALSE. }
    }
    LOCAL hGate IS MIN(envelope["H"],nominal)+BRAKE_MARGIN
        + MAX(0,LANDING_BRAKE_GATE_LEAD_DIST)+MAX(0,LANDING_BRAKE_UNDERSHOOT_BIAS).
    RETURN downrange <= hGate.
}

// The attached node is included by native POSITIONAT propagation. Find the
// first live H/V ignition boundary on that post-node conic, then
// subtract integrated powered travel from remaining ballistic travel. That
// difference is the required phantom-impact lead, not a fixed 15 km.
// Same policy is recomputed for new, retained and pre-burn node admission.
GLOBAL FUNCTION landingDeorbitLeadPolicy {
    PARAMETER nd.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER legacyAim IS 15000.
    LOCAL policy IS landingDeorbitLegacyLead(legacyAim).
    IF LANDING_POWERED_LEAD <= 0 { RETURN policy. }
    SET policy["VALID"] TO FALSE.
    SET policy["REASON"] TO "unsupported-powered-model".
    IF LANDING_ECONOMY_BRAKE <= 0 OR LANDING_STAGE_BRAKE_CREDIT <= 0
            OR SHIP:BODY:ATM:EXISTS OR NOT ADDONS:TR:HASIMPACT { RETURN policy. }
    LOCAL started IS TIME:SECONDS.
    LOCAL vesselBounds IS SHIP:BOUNDS.
    LOCAL hullClearance IS _landingLeadHullClearance(vesselBounds,SHIP:POSITION).
    IF NOT (hullClearance >= 0 AND hullClearance < 1e30) {
        SET policy["REASON"] TO "invalid-vessel-bounds". RETURN policy.
    }
    LOCAL currentAsl IS SHIP:ALTITUDE.
    LOCAL currentRadar IS ALT:RADAR.
    LOCAL legacyRadarHull IS MAX(0,currentRadar-vesselBounds:BOTTOMALTRADAR).
    LOCAL stack IS landingBrakeStackAt(landingBrakeStack(),SHIP:MASS,nd:DELTAV:MAG).
    IF NOT stack["VALID"] { SET policy["REASON"] TO stack["REASON"]. RETURN policy. }

    LOCAL activeAcc IS stack["STAGES"][0]["THRUST"]/stack["MASS"].
    LOCAL planAcc IS vesselLandingReserveAcc().
    IF planAcc <= 0 { SET planAcc TO activeAcc. }
    SET planAcc TO MIN(activeAcc,planAcc).
    LOCAL gravAcc IS SHIP:BODY:MU/SHIP:BODY:RADIUS^2.
    IF planAcc <= gravAcc { SET policy["REASON"] TO "underpowered". RETURN policy. }
    LOCAL stageDv IS 0.
    IF activeAcc > planAcc {
        SET stageDv TO vesselLandingBrakeStageDv().
        // The deorbit burn spends transfer propellant BEFORE landing.
        IF stageDv <= nd:DELTAV:MAG {
            SET policy["REASON"] TO "unknown-or-exhausted-transfer-budget". RETURN policy.
        }
        SET stageDv TO stageDv-nd:DELTAV:MAG.
    }
    LOCAL impactUT IS TIME:SECONDS+ADDONS:TR:TIMETILLIMPACT.
    LOCAL impactGeo IS ADDONS:TR:IMPACTPOS.
    LOCAL lo IS nd:TIME+1.
    LOCAL hi IS impactUT.
    IF hi <= lo OR hi-lo > 1800 { SET policy["REASON"] TO "impact-time". RETURN policy. }
    LOCAL elevation IS LATLNG(targetLat,targetLng):TERRAINHEIGHT.
    LOCAL delay IS MAX(LANDING_BRAKE_REACTION_TIME,1+2*MAX(0.05,LANDING_STAGE_SETTLE)).
    IF _landingLeadGateAt(lo,targetLat,targetLng,elevation,activeAcc,planAcc,stageDv,gravAcc,delay,stack,hullClearance) {
        SET policy["REASON"] TO "no-coast-before-powered-stop". RETURN policy.
    }
    LOCAL iteration IS 0.
    UNTIL iteration >= 12 OR ABORT {
        LOCAL midpoint IS (lo+hi)/2.
        IF _landingLeadGateAt(midpoint,targetLat,targetLng,elevation,activeAcc,planAcc,stageDv,gravAcc,delay,stack,hullClearance) { SET hi TO midpoint. }
        ELSE { SET lo TO midpoint. }
        SET iteration TO iteration+1.
    }
    IF ABORT { SET policy["REASON"] TO "abort". RETURN policy. }
    LOCAL ignition IS _landingLeadStateAt(hi,elevation,hullClearance).
    LOCAL gate IS lmStagedBrakeEnvelope(ignition["HS"],ignition["DOWN"],
        activeAcc,planAcc,stageDv,gravAcc,delay,TRUE).
    LOCAL targetPosition IS LATLNG(targetLat,targetLng):ALTITUDEPOSITION(elevation)-SHIP:BODY:POSITION.
    LOCAL forecast IS landingPredictBrake(lmGroundPositionAt(hi),lmGroundVelocityAt(hi),stack,elevation,1,targetPosition).
    IF NOT forecast["VALID"] { SET policy["REASON"] TO forecast["REASON"]. RETURN policy. }
    LOCAL capturedGeo IS SHIP:BODY:GEOPOSITIONOF(forecast["POSITION"]+SHIP:BODY:POSITION).
    LOCAL travel IS lmSurfaceTrackOffset(ignition["LAT"],ignition["LNG"],capturedGeo:LAT,capturedGeo:LNG,
        lmGroundVelocityAt(hi)).
    LOCAL rangeM IS travel["DOWNFIELD"].
    LOCAL captureError IS lmSurfaceTrackOffset(targetLat,targetLng,capturedGeo:LAT,capturedGeo:LNG,
        lmGroundVelocityAt(hi)).
    LOCAL ballistic IS lmSurfaceTrackOffset(ignition["LAT"],ignition["LNG"],
        impactGeo:LAT,impactGeo:LNG,lmGroundVelocityAt(impactUT)).
    IF rangeM < 0 OR NOT travel["VALID"] OR NOT ballistic["VALID"] {
        SET policy["REASON"] TO "no-powered-range". RETURN policy.
    }
    LOCAL leadM IS ballistic["DOWNFIELD"]-rangeM.
    // Require an overshooting ballistic footprint; no negative-lead
    // workaround or relaxation of normal/cross-track/terrain admission.
    IF leadM <= 0 OR rangeM <= 0 {
        SET policy["REASON"] TO "no-positive-powered-lead". RETURN policy.
    }
    LOCAL tolerance IS MAX(250,MIN(2500,TARGET_TOLERANCE)).
    SET policy TO LEXICON("VALID",TRUE,"AIM",leadM,
        "MIN",MAX(0,leadM-tolerance),"MAX",leadM+tolerance,
        "REASON","powered-range","RANGE",rangeM,"BALLISTIC",ballistic["DOWNFIELD"],
        "IGNITION_UT",hi).
    LOCAL firstEngine IS stack["STAGES"][0].
    LOCAL lastEngine IS stack["STAGES"][stack["STAGES"]:LENGTH-1].
    LOCAL diagnostic IS "STATS deorbit powered-lead aimM=" + ROUND(leadM,0)
        + " rangeM=" + ROUND(rangeM,0) + " ballisticM=" + ROUND(ballistic["DOWNFIELD"],0)
        + " ignitionUT=" + ROUND(hi,1) + " height=" + ROUND(ignition["HEIGHT"],0)
        + " ignitionLat=" + ROUND(ignition["LAT"],5) + " ignitionLng=" + ROUND(ignition["LNG"],5)
        + " asl=" + ROUND(ignition["ASL"],1) + " targetElev=" + ROUND(elevation,1)
        + " localTerrain=" + ROUND(ignition["TERRAIN"],1) + " hull=" + ROUND(ignition["HULL"],2)
        + " hullMode=geometric-radius legacyRadarHull=" + ROUND(legacyRadarHull,2)
        + " originAsl=" + ROUND(currentAsl,1) + " originRadar=" + ROUND(currentRadar,1)
        + " vGate=" + ROUND(gate["V"],1) + " vNow=" + (ignition["HEIGHT"] <= gate["V"])
        + " nodeUt=" + nd:TIME + " prograde=" + nd:PROGRADE + " normal=" + nd:NORMAL
        + " hs=" + ROUND(ignition["HS"],1) + " down=" + ROUND(ignition["DOWN"],1)
        + " activeAcc=" + ROUND(activeAcc,2) + " planAcc=" + ROUND(planAcc,2)
        + " stageDvAfterDeorbit=" + ROUND(stageDv,1)
        + " nominalIgnitionDelay=0 nominalStageDelay=" + (2*MAX(0.05,LANDING_STAGE_SETTLE))
        + " safetyReaction=" + delay
        + " hLeadM=" + MAX(0,LANDING_BRAKE_GATE_LEAD_DIST)
        + " hBiasM=" + MAX(0,LANDING_BRAKE_UNDERSHOOT_BIAS)
        + " toleranceM=" + tolerance + " elapsed=" + ROUND(TIME:SECONDS-started,2)
        + " captureDownfield=" + ROUND(captureError["DOWNFIELD"],0)
        + " captureCross=" + ROUND(captureError["CROSS"],0)
        + " captureHeight=" + ROUND(forecast["HEIGHT"],0)
        + " captureHs=" + ROUND(forecast["HS"],2) + " captureVs=" + ROUND(forecast["VS"],2)
        + " poweredSeconds=" + ROUND(forecast["SECONDS"],1)
        + " impulseDv=" + ROUND(forecast["IMPULSE"],1) + " endMass=" + ROUND(forecast["MASS"],4)
        + " startMass=" + ROUND(stack["MASS"],6) + " stages=" + stack["STAGES"]:LENGTH
        + " firstThrust=" + ROUND(firstEngine["THRUST"],4)
        + " firstExhaust=" + ROUND(firstEngine["EXHAUST"],4)
        + " firstFuel=" + ROUND(firstEngine["FUEL"],6) + " firstDrop=" + ROUND(firstEngine["DROP"],6)
        + " lastThrust=" + ROUND(lastEngine["THRUST"],4)
        + " lastExhaust=" + ROUND(lastEngine["EXHAUST"],4)
        + " lastFuel=" + ROUND(lastEngine["FUEL"],6) + " lastDrop=" + ROUND(lastEngine["DROP"],6)
        + " modelSteps=" + forecast["STEPS"]
        + " model=variable-mass-controller capture=true".
    SET policy["DIAGNOSTIC"] TO diagnostic.
    mLogDetail(diagnostic).
    mLog("STATS deorbit powered-summary aimM=" + ROUND(leadM,0)
        + " rangeM=" + ROUND(rangeM,0) + " height=" + ROUND(ignition["HEIGHT"],0)
        + " captureDownfield=" + ROUND(captureError["DOWNFIELD"],0)
        + " captureCross=" + ROUND(captureError["CROSS"],0)
        + " toleranceM=" + tolerance + " impulseDv=" + ROUND(forecast["IMPULSE"],1)
        + " hBiasM=" + MAX(0,LANDING_BRAKE_UNDERSHOOT_BIAS)).
    RETURN policy.
}
