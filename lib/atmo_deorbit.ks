// Native drag-inclusive impact targeting from a stable atmospheric-body orbit.
// Fixed retrograde entry depth; solve burn epoch + normal together. No vacuum
// braking lead, atmospheric extrapolation or in-air target search is used.
@LAZYGLOBAL OFF.
GLOBAL ATMO_DEORBIT_PE IS 5000.
GLOBAL ATMO_DEORBIT_PE_TOLERANCE IS 3000.
GLOBAL ATMO_DEORBIT_TOLERANCE IS 1500.
GLOBAL ATMO_DEORBIT_NORMAL_CAP IS 10.
GLOBAL ATMO_DEORBIT_DV_CAP IS 150.
GLOBAL ATMO_DEORBIT_TRIALS IS 64.
GLOBAL ATMO_DEORBIT_ROTATIONS IS 2.

LOCAL FUNCTION _atmoFrame {
    PARAMETER ctx.
    RETURN SHIP = ctx["SHIP"] AND SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:BODY = ctx["BODY"]
        AND stateGet("mission_id","") = ctx["MISSION"] AND stateGetNum("launch_time",0) = ctx["LAUNCH"]
        AND stateGet("phase","") = "ATMO_DEORBIT" AND NOT ABORT AND WARP = 0
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0
        AND TARGET_LOCK > 0 AND TARGET_LAT = ctx["LAT"] AND TARGET_LNG = ctx["LNG"].
}

LOCAL FUNCTION _atmoOwns {
    PARAMETER ctx.
    IF NOT _atmoFrame(ctx) OR NOT ALLNODES:CONTAINS(ctx["NODE"]) { RETURN FALSE. }
    LOCAL nd IS ctx["NODE"].
    RETURN ALLNODES:LENGTH = 1 AND ABS(nd:TIME-ctx["EXPECTED"][0]) < 0.00001
        AND ABS(nd:NORMAL-ctx["EXPECTED"][1]) < 0.00001
        AND ABS(nd:PROGRADE-ctx["EXPECTED"][2]) < 0.00001 AND ABS(nd:RADIALOUT) < 0.00001.
}

// A fixed tangent basis at the target, including poles/date-line. The
// Newton solve learns each axis response; no guessed north/south sign.
GLOBAL FUNCTION atmoLandingOffset {
    PARAMETER targetLat, targetLng, impactLat, impactLng.
    LOCAL center IS SHIP:BODY:POSITION.
    LOCAL upVec IS (LATLNG(targetLat,targetLng):ALTITUDEPOSITION(0)-center):NORMALIZED.
    LOCAL hit IS (LATLNG(impactLat,impactLng):ALTITUDEPOSITION(0)-center):NORMALIZED.
    LOCAL axis IS V(0,1,0).
    IF ABS(VDOT(upVec,axis)) > 0.9 { SET axis TO V(1,0,0). }
    LOCAL xAxis IS VCRS(upVec,axis):NORMALIZED.
    LOCAL yAxis IS VCRS(upVec,xAxis):NORMALIZED.
    LOCAL distance IS ARCCOS(MAX(-1,MIN(1,VDOT(upVec,hit))))*CONSTANT:PI/180*SHIP:BODY:RADIUS.
    LOCAL tangent IS VXCL(upVec,hit).
    IF tangent:MAG < 0.000000001 {
        IF distance > 1 { RETURN LEXICON("VALID",FALSE,"DIST",distance). }
        RETURN LEXICON("VALID",TRUE,"DIST",0,"X",0,"Y",0).
    }
    SET tangent TO tangent:NORMALIZED*distance.
    RETURN LEXICON("VALID",TRUE,"DIST",distance,"X",VDOT(tangent,xAxis),"Y",VDOT(tangent,yAxis)).
}

LOCAL FUNCTION _atmoRead {
    PARAMETER ctx.
    LOCAL out IS LEXICON("VALID",FALSE,"DIST",1e30).
    IF NOT _atmoOwns(ctx) OR NOT ADDONS:TR:HASIMPACT { RETURN out. }
    LOCAL impactUt IS TIME:SECONDS+ADDONS:TR:TIMETILLIMPACT.
    IF NOT (impactUt > ctx["NODE"]:TIME AND impactUt < 1e30) { RETURN out. }
    LOCAL hit IS ADDONS:TR:IMPACTPOS.
    SET out TO atmoLandingOffset(ctx["LAT"],ctx["LNG"],hit:LAT,hit:LNG).
    SET out["UT"] TO ctx["NODE"]:TIME. SET out["NORMAL"] TO ctx["NODE"]:NORMAL.
    SET out["PROGRADE"] TO ctx["NODE"]:PROGRADE.
    SET out["PE"] TO ctx["NODE"]:ORBIT:PERIAPSIS.
    SET out["IMPACT_UT"] TO impactUt. SET out["LAT"] TO hit:LAT. SET out["LNG"] TO hit:LNG.
    RETURN out.
}

LOCAL FUNCTION _atmoPut {
    PARAMETER ctx, epoch, normal, prograde.
    LOCAL out IS LEXICON("VALID",FALSE,"DIST",1e30).
    IF NOT _atmoOwns(ctx) { SET ctx["CANCELLED"] TO TRUE. RETURN out. }
    IF ctx["TRIALS"] >= ATMO_DEORBIT_TRIALS OR epoch < ctx["LOW"] OR epoch > ctx["HIGH"]
            OR epoch <= TIME:SECONDS+300 OR ABS(normal) > ATMO_DEORBIT_NORMAL_CAP
            OR SQRT(normal^2+prograde^2) > ATMO_DEORBIT_DV_CAP { RETURN out. }
    SET ctx["NODE"]:TIME TO epoch. SET ctx["NODE"]:NORMAL TO normal. SET ctx["NODE"]:PROGRADE TO prograde.
    SET ctx["EXPECTED"] TO LIST(epoch,normal,prograde).
    SET ctx["TRIALS"] TO ctx["TRIALS"]+1.
    WAIT 0.5.
    IF NOT _atmoOwns(ctx) { SET ctx["CANCELLED"] TO TRUE. RETURN out. }
    RETURN _atmoRead(ctx).
}

GLOBAL FUNCTION atmoLandingStep {
    PARAMETER current, timeProbe, normalProbe.
    LOCAL out IS LEXICON("OK",FALSE,"TIME",0,"NORMAL",0).
    IF NOT current["VALID"] OR NOT timeProbe["VALID"] OR NOT normalProbe["VALID"] { RETURN out. }
    LOCAL dt IS timeProbe["UT"]-current["UT"].
    LOCAL dn IS normalProbe["NORMAL"]-current["NORMAL"].
    IF ABS(dt) < 0.001 OR ABS(dn) < 0.001 { RETURN out. }
    LOCAL xt IS (timeProbe["X"]-current["X"])/dt.
    LOCAL yt IS (timeProbe["Y"]-current["Y"])/dt.
    LOCAL xn IS (normalProbe["X"]-current["X"])/dn.
    LOCAL yn IS (normalProbe["Y"]-current["Y"])/dn.
    LOCAL determinant IS xt*yn-xn*yt.
    IF NOT (ABS(determinant) > 0.000001 AND ABS(determinant) < 1e30) { RETURN out. }
    SET out["TIME"] TO (-current["X"]*yn+current["Y"]*xn)/determinant.
    SET out["NORMAL"] TO (-current["Y"]*xt+current["X"]*yt)/determinant.
    SET out["OK"] TO ABS(out["TIME"]) < 1e30 AND ABS(out["NORMAL"]) < 1e30.
    RETURN out.
}

LOCAL FUNCTION _atmoFit {
    PARAMETER ctx, epoch, retro.
    LOCAL best IS _atmoPut(ctx,epoch,0,-retro).
    LOCAL iteration IS 0.
    UNTIL NOT best["VALID"] OR best["DIST"] <= ATMO_DEORBIT_TOLERANCE
            OR ctx["TRIALS"] >= ATMO_DEORBIT_TRIALS-6 OR ctx["CANCELLED"] OR iteration >= 8 {
        LOCAL dt IS 10.
        IF best["UT"]+dt > ctx["HIGH"] { SET dt TO -dt. }
        LOCAL dn IS 1.
        IF best["NORMAL"]+dn > ATMO_DEORBIT_NORMAL_CAP { SET dn TO -dn. }
        LOCAL tProbe IS _atmoPut(ctx,best["UT"]+dt,best["NORMAL"],best["PROGRADE"]).
        LOCAL nProbe IS _atmoPut(ctx,best["UT"],best["NORMAL"]+dn,best["PROGRADE"]).
        LOCAL step IS atmoLandingStep(best,tProbe,nProbe).
        IF NOT step["OK"] { BREAK. }
        LOCAL shiftT IS MAX(-SHIP:ORBIT:PERIOD/12,MIN(SHIP:ORBIT:PERIOD/12,step["TIME"])).
        LOCAL shiftN IS MAX(-5,MIN(5,step["NORMAL"])).
        LOCAL improved IS FALSE.
        FOR fraction IN LIST(1,0.5,0.25) {
            LOCAL candidate IS _atmoPut(ctx,
                MAX(ctx["LOW"],MIN(ctx["HIGH"],best["UT"]+fraction*shiftT)),
                MAX(-ATMO_DEORBIT_NORMAL_CAP,MIN(ATMO_DEORBIT_NORMAL_CAP,best["NORMAL"]+fraction*shiftN)),
                best["PROGRADE"]).
            IF candidate["VALID"] {
                IF candidate["DIST"] < best["DIST"] { SET best TO candidate. SET improved TO TRUE. BREAK. }
            }
        }
        IF NOT improved { BREAK. }
        SET iteration TO iteration+1.
    }
    IF best["VALID"] AND NOT ctx["CANCELLED"] {
        SET best TO _atmoPut(ctx,best["UT"],best["NORMAL"],best["PROGRADE"]).
    }
    RETURN best.
}

LOCAL FUNCTION _atmoGroundDistance {
    PARAMETER ctx, epoch.
    IF NOT _atmoFrame(ctx) OR HASNODE OR ctx["GEOMETRY"] >= 4096 { RETURN 1e30. }
    SET ctx["GEOMETRY"] TO ctx["GEOMETRY"]+1.
    LOCAL point IS lmGroundGeoAt(epoch).
    RETURN geoDistance(point:LAT,point:LNG,ctx["LAT"],ctx["LNG"]).
}

LOCAL FUNCTION _atmoPasses {
    PARAMETER ctx.
    LOCAL passes IS LIST().
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL startUt IS TIME:SECONDS+900+period/2.
    LOCAL span IS MAX(4*period,MIN(3,MAX(1,ATMO_DEORBIT_ROTATIONS))*ABS(SHIP:BODY:ROTATIONPERIOD)).
    LOCAL step IS MAX(period/32,span/2048).
    LOCAL before IS _atmoGroundDistance(ctx,startUt).
    LOCAL middle IS _atmoGroundDistance(ctx,startUt+step).
    LOCAL epoch IS startUt+2*step.
    UNTIL epoch > startUt+span OR ctx["GEOMETRY"] >= 4050 OR NOT _atmoFrame(ctx) {
        LOCAL after IS _atmoGroundDistance(ctx,epoch).
        IF middle < before AND middle <= after {
            LOCAL lo IS epoch-2*step. LOCAL hi IS epoch.
            LOCAL index IS 0.
            UNTIL index >= 12 OR ctx["GEOMETRY"] >= 4050 {
                LOCAL left IS lo+(hi-lo)/3. LOCAL right IS hi-(hi-lo)/3.
                IF _atmoGroundDistance(ctx,left) < _atmoGroundDistance(ctx,right) { SET hi TO right. }
                ELSE { SET lo TO left. }
                SET index TO index+1.
            }
            LOCAL passUt IS (lo+hi)/2.
            LOCAL distance IS _atmoGroundDistance(ctx,passUt).
            LOCAL light IS landingPlanningLight(ctx["LAT"],ctx["LNG"],passUt,TRUE).
            IF light["OK"] AND distance < 30000 {
                LOCAL candidate IS LEXICON("UT",passUt,"DIST",distance).
                IF passes:LENGTH < 8 { passes:ADD(candidate). }
                ELSE {
                    LOCAL worst IS 0. LOCAL rank IS 1.
                    UNTIL rank >= passes:LENGTH {
                        IF passes[rank]["DIST"] > passes[worst]["DIST"] { SET worst TO rank. }
                        SET rank TO rank+1.
                    }
                    IF distance < passes[worst]["DIST"] { SET passes[worst] TO candidate. }
                }
            }
        }
        SET before TO middle. SET middle TO after. SET epoch TO epoch+step.
        IF MOD(ctx["GEOMETRY"],8) = 0 { WAIT 0. }
    }
    RETURN passes.
}

LOCAL FUNCTION _atmoAccepted {
    PARAMETER result, lat, lng, nd.
    IF NOT result["VALID"] OR NOT (result["DIST"] <= ATMO_DEORBIT_TOLERANCE
            AND result["PE"] > 0 AND result["PE"] < SHIP:BODY:ATM:HEIGHT
            AND ABS(result["PE"]-ATMO_DEORBIT_PE) <= ATMO_DEORBIT_PE_TOLERANCE
            AND ABS(nd:NORMAL) <= ATMO_DEORBIT_NORMAL_CAP
            AND nd:DELTAV:MAG >= 0.3 AND nd:DELTAV:MAG <= ATMO_DEORBIT_DV_CAP) { RETURN FALSE. }
    LOCAL ready IS entryLandingPreflight(nd:DELTAV:MAG).
    IF NOT ready["OK"] { RETURN FALSE. }
    LOCAL targetGrade IS landingTerrainGrade(lat,lng,100).
    LOCAL impactGrade IS landingTerrainGrade(result["LAT"],result["LNG"],100).
    IF NOT (targetGrade >= 0 AND targetGrade <= TAN(LANDING_TERRAIN_MAX_SLOPE)
            AND impactGrade >= 0 AND impactGrade <= TAN(LANDING_TERRAIN_MAX_SLOPE)) { RETURN FALSE. }
    LOCAL light IS landingPlanningLight(lat,lng,result["IMPACT_UT"],TRUE).
    RETURN light["OK"].
}

GLOBAL FUNCTION atmoLandingNodeReady {
    PARAMETER nd, lat, lng.
    LOCAL plan IS stateGet("atmo_deorbit_plan",LEXICON()).
    IF plan:LENGTH = 0 { RETURN FALSE. }
    IF plan["body"] <> SHIP:BODY:NAME OR plan["lat"] <> lat OR plan["lng"] <> lng { RETURN FALSE. }
    LOCAL ctx IS LEXICON("SHIP",SHIP,"BODY",SHIP:BODY,"MISSION",plan["mission"],"LAUNCH",plan["launch"],
        "NODE",nd,"LAT",lat,"LNG",lng,"EXPECTED",LIST(plan["ut"],plan["normal"],plan["prograde"])).
    IF NOT _atmoOwns(ctx) OR NOT landingReviewOrbitSafe() OR nd:TIME <= TIME:SECONDS+30 { RETURN FALSE. }
    WAIT 0.5.
    LOCAL result IS _atmoRead(ctx).
    LOCAL accepted IS _atmoAccepted(result,lat,lng,nd).
    IF NOT _atmoOwns(ctx) { RETURN FALSE. }
    mLogSummary("STATS atmo-deorbit validation accepted=" + accepted + " distance=" + result["DIST"]
        + " tolerance=" + ATMO_DEORBIT_TOLERANCE).
    RETURN accepted.
}

LOCAL FUNCTION _atmoHold {
    PARAMETER reason.
    mLogError("STATS atmo-deorbit decision=hold reason=" + reason + "; orbit/node retained").
    PRINT "Atmospheric deorbit held: " + reason + ". No replacement burn authorized.".
    yieldToPrompt().
}

GLOBAL FUNCTION phaseAtmoDeorbit {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF stateGet("landing_site_context","") <> landingOrbitContext() OR NOT TARGET_LOCK {
        stateSet("phase","LANDING_REVIEW"). yieldToPrompt(). RETURN.
    }
    LOCAL saved IS stateGet("atmo_deorbit_plan",LEXICON()).
    IF saved:LENGTH > 0 AND saved["mission"] = stateGet("mission_id","")
            AND saved["launch"] = stateGetNum("launch_time",0) AND saved["body"] = SHIP:BODY:NAME {
        IF NOT HASNODE AND SHIP:BODY:ATM:EXISTS AND SHIP:PERIAPSIS < SHIP:BODY:ATM:HEIGHT {
            // A completed/partly flown entry cannot get another deorbit burn.
            IF NOT thrustCutoffOk() { RETURN. }
            stateRemove("deorbit_burn_started"). nextPhase(launchSeq). RETURN.
        }
    }
    IF NOT landingReviewOrbitSafe() OR NOT SHIP:BODY:ATM:EXISTS OR maneuverBurnInterrupted()
            OR NOT ADDONS:TR:AVAILABLE OR NOT ADDONS:TR:ISVERTWOTWO
            OR NOT (ATMO_DEORBIT_PE > 0 AND ATMO_DEORBIT_PE < SHIP:BODY:ATM:HEIGHT
                AND ATMO_DEORBIT_PE_TOLERANCE > 0 AND ATMO_DEORBIT_PE_TOLERANCE < ATMO_DEORBIT_PE
                AND ATMO_DEORBIT_TRIALS >= 8 AND ATMO_DEORBIT_TRIALS <= 96
                AND ATMO_DEORBIT_TOLERANCE >= 100 AND ATMO_DEORBIT_TOLERANCE <= 5000
                AND ATMO_DEORBIT_NORMAL_CAP > 0 AND ATMO_DEORBIT_NORMAL_CAP <= 20
                AND ATMO_DEORBIT_TRIALS = FLOOR(ATMO_DEORBIT_TRIALS)
                AND ATMO_DEORBIT_DV_CAP > 0 AND ATMO_DEORBIT_DV_CAP <= 300) {
        _atmoHold("unsafe-context-or-configuration"). RETURN.
    }
    LOCAL nd IS 0.
    IF HASNODE {
        SET nd TO NEXTNODE.
        IF NOT atmoLandingNodeReady(nd,TARGET_LAT,TARGET_LNG) { _atmoHold("retained-node-unvalidated"). RETURN. }
    } ELSE {
        LOCAL ready IS entryLandingPreflight().
        IF NOT ready["OK"] { _atmoHold(ready["REASON"]). RETURN. }
        LOCAL ctx IS LEXICON("SHIP",SHIP,"BODY",SHIP:BODY,"MISSION",stateGet("mission_id",""),
            "LAUNCH",stateGetNum("launch_time",0),"LAT",TARGET_LAT,"LNG",TARGET_LNG,
            "TRIALS",0,"GEOMETRY",0,"CANCELLED",FALSE,"NODE",0).
        LOCAL passes IS _atmoPasses(ctx).
        mLogSummary("STATS atmo-deorbit passes=" + passes:LENGTH + " geometrySamples=" + ctx["GEOMETRY"]
            + " targetLat=" + TARGET_LAT + " targetLng=" + TARGET_LNG).
        LOCAL apo IS SHIP:BODY:RADIUS+SHIP:APOAPSIS.
        LOCAL pe IS SHIP:BODY:RADIUS+ATMO_DEORBIT_PE.
        LOCAL retro IS MAX(2,SQRT(SHIP:BODY:MU/apo)-SQRT(2*SHIP:BODY:MU*pe/(apo*(apo+pe)))).
        LOCAL accepted IS FALSE.
        UNTIL passes:LENGTH = 0 OR accepted OR ctx["TRIALS"] >= ATMO_DEORBIT_TRIALS-4 OR NOT _atmoFrame(ctx) {
            LOCAL best IS 0. LOCAL index IS 1.
            UNTIL index >= passes:LENGTH {
                IF passes[index]["DIST"] < passes[best]["DIST"] { SET best TO index. }
                SET index TO index+1.
            }
            LOCAL passUt IS passes[best]["UT"]. passes:REMOVE(best).
            SET ctx["LOW"] TO MAX(TIME:SECONDS+600,passUt-SHIP:ORBIT:PERIOD/2).
            SET ctx["HIGH"] TO passUt-30.
            LOCAL epoch IS MAX(ctx["LOW"],passUt-SHIP:ORBIT:PERIOD/4).
            IF HASNODE { _atmoHold("foreign-node"). RETURN. }
            SET nd TO NODE(epoch,0,0,-retro). ADD nd.
            SET ctx["NODE"] TO nd. SET ctx["EXPECTED"] TO LIST(epoch,0,-retro).
            ADDONS:TR:SETTARGET(LATLNG(TARGET_LAT,TARGET_LNG)).
            LOCAL result IS _atmoFit(ctx,epoch,retro).
            IF NOT _atmoOwns(ctx) { _atmoHold("planning-context-changed"). RETURN. }
            SET accepted TO _atmoAccepted(result,TARGET_LAT,TARGET_LNG,nd).
            IF NOT _atmoOwns(ctx) { _atmoHold("planning-context-changed"). RETURN. }
            mLogSummary("STATS atmo-deorbit candidate accepted=" + accepted + " distance=" + result["DIST"]
                + " trials=" + ctx["TRIALS"] + " dv=" + nd:DELTAV:MAG).
            IF result["VALID"] {
                mLogSummary("STATS atmo-deorbit footprint burnUT=" + result["UT"] + " normal=" + result["NORMAL"]
                    + " Pe=" + result["PE"] + " impactUT=" + result["IMPACT_UT"]
                    + " lat=" + result["LAT"] + " lng=" + result["LNG"]).
            }
            IF NOT accepted { REMOVE nd. SET nd TO 0. }
        }
        IF NOT accepted { _atmoHold("no-validated-atmospheric-footprint"). RETURN. }
        SET saved TO LEXICON("mission",ctx["MISSION"],"launch",ctx["LAUNCH"],"body",SHIP:BODY:NAME,
            "ut",nd:TIME,"normal",nd:NORMAL,"prograde",nd:PROGRADE,"lat",TARGET_LAT,"lng",TARGET_LNG).
        stateSet("atmo_deorbit_plan",saved).
    }
    IF NOT atmoLandingNodeReady(nd,TARGET_LAT,TARGET_LNG) { _atmoHold("preburn-revalidation"). RETURN. }
    IF NOT executeDeorbitNode(nd,TARGET_LAT,TARGET_LNG,atmoLandingNodeReady@,FALSE) {
        _atmoHold("execution-incomplete"). RETURN.
    }
    IF NOT thrustCutoffOk() { RETURN. }
    stateRemove("deorbit_burn_started").
    bootCacheNextBand().
    nextPhase(launchSeq).
}
