// ============================================================
// aerobrake_assist.ks - Fuel-driven, periapsis-preserving propulsion.
// No staging, engine activation, nodes or archive access during thrust.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION aerobrakeApRecover {
    IF NOT stateGet("aerobrake_ap_active",FALSE) { RETURN TRUE. }
    IF NOT thrustCutoffOk() { RETURN FALSE. }
    stateSet("aerobrake_ap_active",FALSE).
    mLogWarn("STATS aerobrake-assist status=recovered same-pass-attempt-retained").
    RETURN TRUE.
}

GLOBAL FUNCTION aerobrakeApObserve {
    PARAMETER atmHeight.
    IF NOT stateGet("aerobrake_ap_pass_used",FALSE) { RETURN. }
    IF SHIP:ALTITUDE <= atmHeight {
        IF NOT stateGet("aerobrake_ap_entered",FALSE) { stateSet("aerobrake_ap_entered",TRUE). }
    } ELSE IF stateGet("aerobrake_ap_entered",FALSE) {
        // Ignition can precede entry. Being outside alone cannot re-arm it.
        stateSet("aerobrake_ap_pass_used",FALSE).
        stateSet("aerobrake_ap_entered",FALSE).
    }
}

LOCAL FUNCTION _aeroApCpuBegin {
    stateSet("aerobrake_prior_ipu",CONFIG:IPU).
    SET CONFIG:IPU TO MAX(CONFIG:IPU,2000).
}

LOCAL FUNCTION _aeroApCpuEnd {
    SET CONFIG:IPU TO stateGetNum("aerobrake_prior_ipu",CONFIG:IPU).
    stateRemove("aerobrake_prior_ipu").
}

LOCAL FUNCTION _aeroApRemainingDv {
    RETURN MIN(SHIP:DELTAV:VACUUM,STAGE:DELTAV:VACUUM).
}

// Diagnostics only: called before/after thrust and once a second in RAM.
LOCAL FUNCTION _aeroApAttitude {
    PARAMETER direction.
    LOCAL angles IS LEXICON("FACING_ERR",-1,"ORBIT_OFFSET",-1,"SURFACE_OFFSET",-1).
    IF NOT (direction:MAG > 0.5) { RETURN angles. }
    IF SHIP:FACING:FOREVECTOR:MAG > 0.5 {
        SET angles["FACING_ERR"] TO VANG(SHIP:FACING:FOREVECTOR,direction).
    }
    IF SHIP:VELOCITY:ORBIT:MAG > 1 {
        SET angles["ORBIT_OFFSET"] TO VANG(direction,-SHIP:VELOCITY:ORBIT).
    }
    IF SHIP:VELOCITY:SURFACE:MAG > 1 {
        SET angles["SURFACE_OFFSET"] TO VANG(direction,-SHIP:VELOCITY:SURFACE).
    }
    RETURN angles.
}

LOCAL FUNCTION _aeroApEngine {
    LOCAL thrustSum IS 0.
    LOCAL flowSum IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:AVAILABLETHRUST > 0 {
            IF eng:THROTTLELOCK OR NOT (eng:VISP > 0) {
                RETURN LEXICON("THRUST",0,"VE",0).
            }
            SET thrustSum TO thrustSum+eng:AVAILABLETHRUST.
            SET flowSum TO flowSum+eng:AVAILABLETHRUST/(eng:VISP*CONSTANT:G0).
        }
    }
    RETURN LEXICON("THRUST",thrustSum,"VE",thrustSum/MAX(0.000000001,flowSum)).
}

LOCAL FUNCTION _aeroApPlan {
    PARAMETER atmHeight.
    PARAMETER peLow.
    PARAMETER peHigh.
    PARAMETER targetPe.
    LOCAL skipped IS LEXICON("OK",FALSE,"REASON","disabled-node-or-prior-attempt").
    IF AEROBRAKE_AP_BURN <= 0 OR ABORT OR HASNODE
            OR AEROBRAKE_REENTRY_DIR = "PROGRADE"
            OR stateGet("aerobrake_ap_pass_used",FALSE) { RETURN skipped. }
    SET skipped["REASON"] TO "not-coasting-or-outside-entry-corridor".
    IF NOT (SHIP:ALTITUDE > atmHeight AND SHIP:MASS > 0
            AND SHIP:VELOCITY:ORBIT:MAG > 1 AND SHIP:VELOCITY:SURFACE:MAG > 1
            AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
            AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0
            AND SHIP:PERIAPSIS >= peLow+100 AND SHIP:PERIAPSIS <= peHigh-100) { RETURN skipped. }
    LOCAL entryEta IS aerobrakeApEntryEta(atmHeight).
    SET skipped["REASON"] TO "outside-planning-window".
    IF NOT (entryEta > 0 AND entryEta <= AEROBRAKE_AP_PLAN_LEAD+30) { RETURN skipped. }
    LOCAL budget IS _aeroApRemainingDv()-MAX(0,AEROBRAKE_AP_RESERVE_DV).
    LOCAL engine IS _aeroApEngine().
    SET skipped["REASON"] TO "fuel-engine-or-corridor-unavailable".
    IF NOT (budget > 0.1 AND budget < 1e30 AND engine["THRUST"] > 0
            AND engine["VE"] > 0 AND peHigh > peLow+200) { RETURN skipped. }
    LOCAL rMag IS SHIP:BODY:RADIUS+SHIP:ALTITUDE.
    LOCAL radial IS (SHIP:POSITION-SHIP:BODY:POSITION):NORMALIZED.
    LOCAL vr IS VDOT(SHIP:VELOCITY:ORBIT,radial).
    LOCAL vt IS (SHIP:VELOCITY:ORBIT-vr*radial):MAG.
    LOCAL bodyRadius IS SHIP:BODY:RADIUS.
    LOCAL acc IS engine["THRUST"]/SHIP:MASS.
    LOCAL targetAp IS MAX(atmHeight+1000,targetPe+1000).
    // Conservative surface/orbit frame allowance for the atmospheric attitude gate.
    LOCAL rotationAngle IS 0.
    IF ABS(SHIP:BODY:ROTATIONPERIOD) > 0 {
        SET rotationAngle TO ARCSIN(MIN(1,2*CONSTANT:PI*(bodyRadius+atmHeight)
            /ABS(SHIP:BODY:ROTATIONPERIOD)/SQRT(SHIP:BODY:MU/(bodyRadius+atmHeight)))).
    }
    LOCAL ctx IS LEXICON("POS",V(rMag,0,0),"VEL",V(vr,vt,0),"MU",SHIP:BODY:MU,
        "ACC",acc,"VE",engine["VE"],"BUDGET",budget,"TARGET_PE",bodyRadius+targetPe,
        "LOW",bodyRadius+peLow,"HIGH",bodyRadius+peHigh,"TARGET_AP",bodyRadius+targetAp,
        "ATMO",bodyRadius+atmHeight,"ANGLE",MAX(0,AEROBRAKE_AP_MAX_OFF_RETRO-rotationAngle),
        "ENERGY",SHIP:VELOCITY:ORBIT:MAG^2/2-SHIP:BODY:MU/rMag).
    LOCAL epoch IS TIME:SECONDS.
    LOCAL fullTime IS engine["VE"]/acc*(1-CONSTANT:E^(-budget/engine["VE"])).
    // Center the useful energy reduction, even when fuel greatly exceeds
    // that needed. This estimates timing only; prediction still has all fuel.
    LOCAL rp IS bodyRadius+targetPe.
    LOCAL peSpeed IS SQRT(MAX(0,2*(ctx["ENERGY"]+SHIP:BODY:MU/rp))).
    LOCAL goalSpeed IS SQRT(MAX(0,SHIP:BODY:MU*(2/rp-2/(rp+ctx["TARGET_AP"])))).
    LOCAL usefulDv IS MIN(budget,MAX(0,peSpeed-goalSpeed)).
    LOCAL usefulTime IS engine["VE"]/acc*(1-CONSTANT:E^(-usefulDv/engine["VE"])).
    LOCAL peEta IS ETA:PERIAPSIS.
    LOCAL best IS skipped.
    _aeroApCpuBegin().
    FOR delay IN LIST(MAX(15,peEta-usefulTime/2),MAX(15,peEta),MAX(15,peEta-fullTime)) {
        LOCAL trial IS aeroApPredict(ctx,delay).
        IF trial["OK"] {
            IF NOT best["OK"] { SET best TO trial. }
            ELSE IF trial["ENERGY"] < best["ENERGY"] { SET best TO trial. }
        } ELSE IF NOT best["OK"] { SET best TO trial. }
    }
    IF best["OK"] { SET best TO aeroApPredict(ctx,best["DELAY"],1). }
    _aeroApCpuEnd().
    IF best["OK"] AND epoch+best["DELAY"] <= TIME:SECONDS+5 {
        SET best["OK"] TO FALSE. SET best["REASON"] TO "forecast-too-late".
    }
    mLog("STATS aerobrake-assist plan ok=" + best["OK"] + " reason=" + best["REASON"]
        + " model=finite-vacuum entryEta=" + entryEta + " fuelDv=" + budget
        + " computeSec=" + (TIME:SECONDS-epoch)).
    IF NOT best["OK"] { RETURN best. }
    SET best["IGNITE"] TO epoch+best["DELAY"].
    SET best["BODY"] TO SHIP:BODY:NAME.
    SET best["STAGE"] TO STAGE:NUMBER.
    SET best["TARGET_PE"] TO targetPe.
    SET best["LOW"] TO peLow.
    SET best["HIGH"] TO peHigh.
    SET best["TARGET_AP"] TO targetAp.
    SET best["ENTERED"] TO FALSE.
    // The live one-second taper decays exponentially. Include its settling
    // time to the 0.01 m/s cutoff instead of expiring a short burn early.
    SET best["SETTLE"] TO MAX(5,LN(MAX(1,acc*CONSTANT:E^(best["DV"]/engine["VE"])/0.01))+2).
    mLog("STATS aerobrake-assist forecast igniteUt=" + best["IGNITE"]
        + " dv=" + best["DV"] + " duration=" + best["DURATION"]
        + " Pe=" + (best["PE"]-bodyRadius) + " Ap=" + (best["AP"]-bodyRadius)
        + " peLow=" + peLow + " peHigh=" + peHigh + " targetAp=" + targetAp).
    RETURN best.
}

// Live guards run through the throttle lock, including between owner ticks.
// A tripped guard latches; a queued positive command cannot restart the burn.
LOCAL FUNCTION _aeroApSafeThrottle {
    PARAMETER command.
    PARAMETER control.
    IF control["REASON"] <> "" { RETURN 0. }
    IF NOT (ABS(command) < 1e30) { SET control["REASON"] TO "invalid-command". }
    IF ABORT OR AEROBRAKE_AP_BURN <= 0 { SET control["REASON"] TO "disabled-or-abort". }
    IF TIME:SECONDS >= control["DEADLINE"] { SET control["REASON"] TO "forecast-duration". }
    IF TIME:SECONDS-control["UPDATED"] > 0.5 { SET control["REASON"] TO "stale-control". }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        SET control["REASON"] TO "landed".
    }
    IF SHIP:BODY:NAME <> control["BODY"] OR STAGE:NUMBER <> control["STAGE"] OR HASNODE {
        SET control["REASON"] TO "body-stage-or-node-changed".
    }
    IF NOT (SHIP:PERIAPSIS >= control["LOW"]+100 AND SHIP:PERIAPSIS <= control["HIGH"]-100) {
        SET control["REASON"] TO "periapsis-corridor".
    }
    IF NOT (SHIP:Q >= 0 AND SHIP:Q <= AEROBRAKE_AP_MAX_Q) {
        SET control["REASON"] TO "dynamic-pressure".
    }
    IF NOT (_aeroApRemainingDv() > MAX(0,AEROBRAKE_AP_RESERVE_DV)) {
        SET control["REASON"] TO "fuel-reserve".
    }
    IF control["APPLIED"] >= control["DV"]-0.01 { SET control["REASON"] TO "forecast-dv". }
    IF SHIP:ORBIT:ECCENTRICITY < 1 AND SHIP:APOAPSIS > 0
            AND SHIP:APOAPSIS <= control["TARGET_AP"] { SET control["REASON"] TO "apoapsis-target". }
    IF NOT (SHIP:AVAILABLETHRUST > 0 AND SHIP:MASS > 0
            AND SHIP:VELOCITY:ORBIT:MAG > 1 AND SHIP:VELOCITY:SURFACE:MAG > 1
            AND control["DIR"]:MAG > 0.5) { SET control["REASON"] TO "invalid-thrust-or-direction". }
    IF control["REASON"] <> "" { RETURN 0. }
    LOCAL facingErr IS VANG(SHIP:FACING:FOREVECTOR,control["DIR"]).
    SET control["PEAK_FACING_ERR"] TO MAX(control["PEAK_FACING_ERR"],facingErr).
    IF NOT (facingErr <= 5
            AND VDOT(control["DIR"],SHIP:VELOCITY:ORBIT) < -0.01*SHIP:VELOCITY:ORBIT:MAG) {
        SET control["REASON"] TO "alignment-or-energy". RETURN 0.
    }
    IF SHIP:ALTITUDE <= control["ATMO"]
            AND NOT (VANG(control["DIR"],-SHIP:VELOCITY:SURFACE) <= AEROBRAKE_AP_MAX_OFF_RETRO
                AND VANG(SHIP:FACING:FOREVECTOR,-SHIP:VELOCITY:SURFACE) <= AEROBRAKE_AP_MAX_OFF_RETRO) {
        SET control["REASON"] TO "entry-attitude". RETURN 0.
    }
    RETURN MAX(0,MIN(1,command)).
}

GLOBAL FUNCTION aerobrakeApAssist {
    PARAMETER atmHeight.
    PARAMETER peLow.
    PARAMETER peHigh.
    PARAMETER targetPe.
    LOCAL plan IS _aeroApPlan(atmHeight,peLow,peHigh,targetPe).
    IF NOT plan["OK"] {
        mLog("STATS aerobrake-assist skipped reason=" + plan["REASON"]
            + " Pe=" + SHIP:PERIAPSIS + " Ap=" + SHIP:APOAPSIS
            + " remainingDv=" + _aeroApRemainingDv()).
        RETURN plan.
    }
    LOCK THROTTLE TO 0.
    // Leave time to align before the predicted ignition, with zero throttle.
    UNTIL TIME:SECONDS >= plan["IGNITE"]-30 OR ABORT OR HASNODE
            OR SHIP:BODY:NAME <> plan["BODY"] OR STAGE:NUMBER <> plan["STAGE"] {
        WAIT 0.1.
    }
    IF ABORT OR HASNODE OR SHIP:BODY:NAME <> plan["BODY"] OR STAGE:NUMBER <> plan["STAGE"] {
        SET plan["OK"] TO FALSE. RETURN plan.
    }
    LOCAL priorDeferral IS LOG_ARCHIVE_DEFERRED.
    SET LOG_ARCHIVE_DEFERRED TO 1.
    _aeroApCpuBegin().
    stateSet("aerobrake_ap_pass_used",TRUE).
    stateSet("aerobrake_ap_entered",FALSE).
    stateSet("aerobrake_ap_active",TRUE).
    LOCAL control IS LEXICON("REASON","","DV",plan["DV"],"APPLIED",0,"PEAK_FACING_ERR",0,
        "LOW",peLow,"HIGH",peHigh,"TARGET_AP",plan["TARGET_AP"],"ATMO",atmHeight,
        "BODY",plan["BODY"],"STAGE",plan["STAGE"],"UPDATED",TIME:SECONDS,
        "DEADLINE",plan["IGNITE"]+plan["DURATION"]+plan["SETTLE"],"DIR",V(0,0,0)).
    SAS OFF.
    SET control["DIR"] TO aeroApDirection(SHIP:POSITION-SHIP:BODY:POSITION,
        SHIP:VELOCITY:ORBIT,SHIP:BODY:MU,SHIP:BODY:RADIUS+targetPe,
        SHIP:AVAILABLETHRUST/MAX(0.01,SHIP:MASS)).
    IF control["DIR"]:MAG < 0.5 { SET control["DIR"] TO -SHIP:VELOCITY:ORBIT. }
    LOCK STEERING TO control["DIR"].
    LOCAL angles IS _aeroApAttitude(control["DIR"]).
    mLog("STATS aerobrake-assist align status=begin mode=preserve-pe facingErr=" + angles["FACING_ERR"]
        + " orbitRetroOffset=" + angles["ORBIT_OFFSET"] + " surfaceRetroOffset=" + angles["SURFACE_OFFSET"]
        + " Pe=" + SHIP:PERIAPSIS + " Ap=" + SHIP:APOAPSIS).
    LOCAL alignDeadline IS plan["IGNITE"]+5.
    UNTIL (TIME:SECONDS >= plan["IGNITE"] AND control["DIR"]:MAG > 0.5
            AND VANG(SHIP:FACING:FOREVECTOR,control["DIR"]) <= 5)
            OR TIME:SECONDS >= alignDeadline OR ABORT OR HASNODE {
        SET control["DIR"] TO aeroApDirection(SHIP:POSITION-SHIP:BODY:POSITION,
            SHIP:VELOCITY:ORBIT,SHIP:BODY:MU,SHIP:BODY:RADIUS+targetPe,
            SHIP:AVAILABLETHRUST/MAX(0.01,SHIP:MASS)).
        IF control["DIR"]:MAG < 0.5 { SET control["DIR"] TO -SHIP:VELOCITY:ORBIT. }
        WAIT 0.05.
    }
    SET angles TO _aeroApAttitude(control["DIR"]).
    IF NOT (angles["FACING_ERR"] >= 0 AND angles["FACING_ERR"] <= 5) {
        SET control["REASON"] TO "alignment-timeout".
    }
    mLog("STATS aerobrake-assist align status=checked mode=preserve-pe facingErr=" + angles["FACING_ERR"]
        + " orbitRetroOffset=" + angles["ORBIT_OFFSET"] + " surfaceRetroOffset=" + angles["SURFACE_OFFSET"]
        + " reason=" + control["REASON"]).
    LOCAL command IS 0.
    LOCAL peakOrbitOffset IS angles["ORBIT_OFFSET"].
    LOCAL peakSurfaceOffset IS angles["SURFACE_OFFSET"].
    LOCAL nextAnglesUt IS TIME:SECONDS.
    LOCAL lastT IS TIME:SECONDS.
    LOCAL lastAcc IS SHIP:THRUST/MAX(0.01,SHIP:MASS).
    SET control["UPDATED"] TO TIME:SECONDS.
    LOCK THROTTLE TO _aeroApSafeThrottle(command,control).
    UNTIL control["REASON"] <> "" {
        LOCAL dt IS TIME:SECONDS-lastT.
        LOCAL liveAcc IS MAX(0,SHIP:THRUST)/MAX(0.01,SHIP:MASS).
        SET control["APPLIED"] TO control["APPLIED"]+(lastAcc+liveAcc)/2*MAX(0,dt).
        SET lastAcc TO liveAcc.
        IF dt > 0.5 { SET control["REASON"] TO "stale-control". }
        SET lastT TO TIME:SECONDS.
        SET control["UPDATED"] TO TIME:SECONDS.
        IF SHIP:ALTITUDE <= atmHeight { SET plan["ENTERED"] TO TRUE. }
        LOCAL acceleration IS SHIP:AVAILABLETHRUST/MAX(0.01,SHIP:MASS).
        SET control["DIR"] TO aeroApDirection(SHIP:POSITION-SHIP:BODY:POSITION,
            SHIP:VELOCITY:ORBIT,SHIP:BODY:MU,SHIP:BODY:RADIUS+targetPe,acceleration).
        IF TIME:SECONDS >= nextAnglesUt {
            SET angles TO _aeroApAttitude(control["DIR"]).
            SET peakOrbitOffset TO MAX(peakOrbitOffset,angles["ORBIT_OFFSET"]).
            SET peakSurfaceOffset TO MAX(peakSurfaceOffset,angles["SURFACE_OFFSET"]).
            SET nextAnglesUt TO TIME:SECONDS+1.
        }
        LOCAL energyLeft IS SHIP:VELOCITY:ORBIT:MAG^2/2
            -SHIP:BODY:MU/(SHIP:BODY:RADIUS+SHIP:ALTITUDE)
            +SHIP:BODY:MU/(2*SHIP:BODY:RADIUS+targetPe+control["TARGET_AP"]).
        LOCAL remaining IS MIN(control["DV"]-control["APPLIED"],
            energyLeft/MAX(1,-VDOT(control["DIR"],SHIP:VELOCITY:ORBIT))).
        SET command TO MAX(0,MIN(1,remaining
            /(MAX(0.01,acceleration)*MAX(1,2*dt)))).
        IF remaining <= 0.01 { SET control["REASON"] TO "forecast-or-energy-target". }
        IF NOT (ABS(control["APPLIED"]) < 1e30 AND acceleration > 0) {
            SET control["REASON"] TO "invalid-thrust".
        }
        LOCAL checked IS _aeroApSafeThrottle(command,control).
        WAIT 0.05.
    }
    SET command TO 0.
    LOCAL stopped IS thrustCutoffOk().
    // A failed physical cutoff already requests a hold. Keep its recovery
    // marker and local-log deferral; do no further I/O with uncertain thrust.
    IF NOT stopped { RETURN plan. }
    _aeroApCpuEnd().
    stateSet("aerobrake_ap_active",FALSE).
    IF plan["ENTERED"] { stateSet("aerobrake_ap_entered",TRUE). }
    LOCK STEERING TO SHIP:SRFRETROGRADE.
    SET LOG_ARCHIVE_DEFERRED TO priorDeferral.
    mLog("STATS aerobrake-assist result reason=" + control["REASON"]
        + " appliedDv=" + control["APPLIED"] + " forecastDv=" + plan["DV"]
        + " peakFacingErr=" + control["PEAK_FACING_ERR"]
        + " peakOrbitRetroOffset=" + peakOrbitOffset + " peakSurfaceRetroOffset=" + peakSurfaceOffset
        + " Ap=" + SHIP:APOAPSIS + " Pe=" + SHIP:PERIAPSIS + " qAtm=" + SHIP:Q
        + " remainingDv=" + _aeroApRemainingDv() + " cutoffOk=" + stopped).
    RETURN plan.
}
