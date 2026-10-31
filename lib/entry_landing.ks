// Small chute-assisted terminal controller, resident in SCIENCE_ENTRY only.
// It never stages or waits for target input. Science continues while falling.
@LAZYGLOBAL OFF.
GLOBAL ENTRY_HAS_POWERED_LANDING IS TRUE.

GLOBAL FUNCTION entryLandingCreate {
    RETURN LEXICON("SHIP",SHIP,"BODY",SHIP:BODY,"MISSION",stateGet("mission_id",""),
        "LAUNCH",stateGetNum("launch_time",0),"ACTIVE",FALSE,"COMMAND",0,
        "DIRECTION",SHIP:UP:VECTOR,"HEARTBEAT",TIME:SECONDS,"LOG_AT",0,"IMPULSE",0,
        "LAST_UT",TIME:SECONDS,"STAGE",SHIP:CURRENTSTAGE,"WARNED",FALSE).
}

LOCAL FUNCTION _entryLandingBound {
    PARAMETER ctx.
    RETURN SHIP = ctx["SHIP"] AND SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:BODY = ctx["BODY"]
        AND stateGet("mission_id","") = ctx["MISSION"]
        AND stateGetNum("launch_time",0) = ctx["LAUNCH"]
        AND stateGet("phase","") = "SCIENCE_ENTRY".
}

GLOBAL FUNCTION entryLandingThrottle {
    PARAMETER ctx.
    IF NOT _entryLandingBound(ctx) OR ABORT OR WARP <> 0 { RETURN 0. }
    IF SHIP:CONTROL:PILOTMAINTHROTTLE > 0 OR TIME:SECONDS-ctx["HEARTBEAT"] > 1 { RETURN 0. }
    IF SHIP:CURRENTSTAGE <> ctx["STAGE"] OR NOT (SHIP:AVAILABLETHRUST > 0
            AND SHIP:AVAILABLETHRUST < 1e30 AND SHIP:MASS > 0 AND SHIP:MASS < 1e30) { RETURN 0. }
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN 0. }
    IF NOT (SHIP:ALTITUDE < SHIP:BODY:ATM:HEIGHT) { RETURN 0. }
    IF VANG(SHIP:FACING:FOREVECTOR,ctx["DIRECTION"]) > ENTRY_LANDING_ALIGN_DEG { RETURN 0. }
    RETURN MAX(0,MIN(1,ctx["COMMAND"])).
}

GLOBAL FUNCTION entryLandingStop {
    PARAMETER ctx.
    SET ctx["COMMAND"] TO 0.
    LOCAL stopped IS thrustCutoffOk().
    SET ctx["ACTIVE"] TO FALSE.
    UNLOCK STEERING.
    RETURN stopped.
}

GLOBAL FUNCTION entryLandingTick {
    PARAMETER ctx.
    SET ctx["HEARTBEAT"] TO TIME:SECONDS.
    IF NOT _entryLandingBound(ctx) OR ABORT OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        SET ctx["COMMAND"] TO 0. RETURN FALSE.
    }
    IF SHIP:CURRENTSTAGE <> ctx["STAGE"] {
        SET ctx["COMMAND"] TO 0.
        IF NOT thrustCutoffOk() { RETURN FALSE. }
        SET ctx["STAGE"] TO SHIP:CURRENTSTAGE.
    }
    LOCAL height IS MAX(0,SHIP:BOUNDS:BOTTOMALTRADAR).
    LOCAL down IS MAX(0,-SHIP:VERTICALSPEED).
    LOCAL acceleration IS SHIP:AVAILABLETHRUST/MAX(0.001,SHIP:MASS).
    LOCAL gravity IS SHIP:BODY:MU/(SHIP:BODY:RADIUS+SHIP:ALTITUDE)^2.
    LOCAL plan IS entryLandingPlan(height,down,acceleration,gravity).
    IF NOT ctx["ACTIVE"] AND (height > ENTRY_LANDING_MAX_ALT
            OR (SHIP:AIRSPEED > ENTRY_LANDING_MAX_AIRSPEED AND height > 1500)) { RETURN FALSE. }
    LOCAL dt IS MAX(0,MIN(1,TIME:SECONDS-ctx["LAST_UT"])).
    SET ctx["IMPULSE"] TO ctx["IMPULSE"]+SHIP:THRUST/MAX(0.001,SHIP:MASS)*dt.
    SET ctx["LAST_UT"] TO TIME:SECONDS.
    IF NOT plan["OK"] {
        SET ctx["COMMAND"] TO 0.
        IF NOT ctx["WARNED"] {
            mLogWarn("STATS entry-landing authority=unavailable height=" + height + " down=" + down).
            SET ctx["WARNED"] TO TRUE.
        }
        RETURN ctx["ACTIVE"].
    }
    SET ctx["WARNED"] TO FALSE.
    // Begin aligning before ignition; no blocking attitude waits while falling.
    IF NOT ctx["ACTIVE"] AND height > 2*plan["STOP"]+10*down+200 { RETURN FALSE. }
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL horizontal IS VXCL(upVec,SHIP:VELOCITY:SURFACE).
    LOCAL desired IS V(0,0,0).
    LOCAL site IS landingResolveTarget().
    LOCAL targetDistance IS -1.
    IF site["FOUND"] AND height > 50 {
        LOCAL offset IS VXCL(upVec,LATLNG(site["LAT"],site["LNG"]):POSITION-SHIP:POSITION).
        SET targetDistance TO offset:MAG.
        LOCAL remaining IS MAX(5,height/MAX(3,down)).
        SET desired TO offset/MAX(5,remaining).
        IF desired:MAG > 20 { SET desired TO desired:NORMALIZED*20. }
    }
    LOCAL lateral IS (desired-horizontal)/3.
    LOCAL upAcc IS plan["UP_ACC"].
    LOCAL lateralCap IS MIN(acceleration*SIN(ENTRY_LANDING_MAX_TILT),upAcc*TAN(ENTRY_LANDING_MAX_TILT)).
    IF lateral:MAG > lateralCap AND lateral:MAG > 0 { SET lateral TO lateral:NORMALIZED*lateralCap. }
    LOCAL vector IS upVec*upAcc+lateral.
    SET ctx["DIRECTION"] TO upVec.
    IF vector:MAG > 0.001 { SET ctx["DIRECTION"] TO vector:NORMALIZED. }
    SET ctx["COMMAND"] TO MIN(1,vector:MAG/MAX(0.001,acceleration)).
    IF NOT ctx["ACTIVE"] {
        SET SAS TO FALSE.
        SET ctx["ACTIVE"] TO TRUE.
        LOCK STEERING TO ctx["DIRECTION"].
        LOCK THROTTLE TO entryLandingThrottle(ctx).
        mLogSummary("STATS entry-landing armed height=" + height + " down=" + down + " stoppingHeight=" + plan["STOP"]).
    }
    IF TIME:SECONDS >= ctx["LOG_AT"] {
        mLog("STATS entry-landing height=" + ROUND(height,1) + " down=" + ROUND(down,1)
            + " targetDown=" + ROUND(plan["TARGET_DOWN"],1) + " hs=" + ROUND(horizontal:MAG,1)
            + " align=" + ROUND(VANG(SHIP:FACING:FOREVECTOR,ctx["DIRECTION"]),1)
            + " command=" + ROUND(ctx["COMMAND"],3) + " applied=" + ROUND(ctx["IMPULSE"],1)
            + " targetDist=" + ROUND(targetDistance,1) + " stoppingHeight=" + ROUND(plan["STOP"],1)
            + " acc=" + ROUND(acceleration,2) + " gravity=" + ROUND(gravity,3)
            + " stageDv=" + ROUND(STAGE:DELTAV:VACUUM,1)
            + " stage=" + ctx["STAGE"]).
        SET ctx["LOG_AT"] TO TIME:SECONDS+5.
    }
    RETURN TRUE.
}
