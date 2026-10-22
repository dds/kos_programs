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
    LOCAL positionVec IS lmGroundPositionAt(ut).
    LOCAL velocityVec IS lmGroundVelocityAt(ut).
    LOCAL upVec IS positionVec:NORMALIZED.
    LOCAL geo IS lmGroundGeoAt(ut).
    LOCAL asl IS positionVec:MAG-SHIP:BODY:RADIUS.
    LOCAL hull IS MAX(0,ALT:RADAR-SHIP:BOUNDS:BOTTOMALTRADAR).
    RETURN LEXICON("HS",VXCL(upVec,velocityVec):MAG,
        "DOWN",MAX(0,-VDOT(velocityVec,upVec)),
        "HEIGHT",MIN(asl-targetElevation,asl-geo:TERRAINHEIGHT-hull),
        "LAT",geo:LAT,"LNG",geo:LNG,"ASL",asl).
}

// The attached node is included by native POSITIONAT propagation. Find the
// conservative vertical ignition boundary on that post-node conic, then
// subtract nominal powered travel from remaining ballistic travel. That
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
    LOCAL activeAcc IS vesselLandingThrust()/MAX(0.01,SHIP:MASS).
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
    LOCAL firstState IS _landingLeadStateAt(lo,elevation).
    LOCAL firstGate IS lmStagedBrakeEnvelope(firstState["HS"],firstState["DOWN"],
        activeAcc,planAcc,stageDv,gravAcc,delay,TRUE).
    IF firstState["HEIGHT"] <= firstGate["V"] {
        SET policy["REASON"] TO "no-coast-before-powered-stop". RETURN policy.
    }
    LOCAL iteration IS 0.
    UNTIL iteration >= 12 OR ABORT {
        LOCAL midpoint IS (lo+hi)/2.
        LOCAL sample IS _landingLeadStateAt(midpoint,elevation).
        LOCAL envelope IS lmStagedBrakeEnvelope(sample["HS"],sample["DOWN"],
            activeAcc,planAcc,stageDv,gravAcc,delay,TRUE).
        IF sample["HEIGHT"] <= envelope["V"] { SET hi TO midpoint. }
        ELSE { SET lo TO midpoint. }
        SET iteration TO iteration+1.
    }
    IF ABORT { SET policy["REASON"] TO "abort". RETURN policy. }
    LOCAL ignition IS _landingLeadStateAt(hi,elevation).
    LOCAL rangeM IS lmNominalBrakeRange(ignition["HS"],activeAcc,planAcc,
        stageDv,gravAcc,0,SHIP:BODY:RADIUS,ignition["ASL"],2*MAX(0.05,LANDING_STAGE_SETTLE)).
    LOCAL ballistic IS lmSurfaceTrackOffset(ignition["LAT"],ignition["LNG"],
        impactGeo:LAT,impactGeo:LNG,lmGroundVelocityAt(impactUT)).
    IF rangeM < 0 OR NOT ballistic["VALID"] {
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
    mLog("STATS deorbit powered-lead aimM=" + ROUND(leadM,0)
        + " rangeM=" + ROUND(rangeM,0) + " ballisticM=" + ROUND(ballistic["DOWNFIELD"],0)
        + " ignitionUT=" + ROUND(hi,1) + " height=" + ROUND(ignition["HEIGHT"],0)
        + " hs=" + ROUND(ignition["HS"],1) + " down=" + ROUND(ignition["DOWN"],1)
        + " activeAcc=" + ROUND(activeAcc,2) + " planAcc=" + ROUND(planAcc,2)
        + " stageDvAfterDeorbit=" + ROUND(stageDv,1)
        + " nominalIgnitionDelay=0 nominalStageDelay=" + (2*MAX(0.05,LANDING_STAGE_SETTLE))
        + " safetyReaction=" + delay
        + " toleranceM=" + tolerance + " elapsed=" + ROUND(TIME:SECONDS-started,2)
        + " model=constant-descent nominal=true").
    RETURN policy.
}
