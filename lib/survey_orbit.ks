// ============================================================
// survey_orbit.ks - Manual, archive-only scan-track comparison.
// Native maneuver propagation + existing rotating-body ground coordinates.
// Samples are a coverage proxy, NOT a sensor swath/percentage forecast.
// No phase, scanner, control, alarm or staging changes here.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION surveyOrbitIdle {
    PARAMETER craftRef.
    PARAMETER occupied.
    RETURN SHIP = craftRef AND SHIP = KUNIVERSE:ACTIVEVESSEL AND NOT ABORT
        AND WARP = 0 AND KUNIVERSE:TIMEWARP:ISSETTLED AND HASNODE = occupied
        AND (NOT occupied OR ALLNODES:LENGTH = 1)
        AND SHIP:STATUS = "ORBITING" AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001
        AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0
        AND stateGet("burn_pending","false") <> "true"
        AND stateGet("burn_started","false") <> "true"
        AND NOT stateGet("hop_route_active",FALSE)
        AND LIST("DONE","SCIENCE_OPS","SCANSAT_OPS"):CONTAINS(stateGet("phase","")).
}

GLOBAL FUNCTION surveyOrbitFloor {
    RETURN MAX(10000,shapePeFloor()).
}

GLOBAL FUNCTION surveyOrbitOwned {
    PARAMETER craftRef.
    PARAMETER nd.
    RETURN SHIP = craftRef AND KUNIVERSE:ACTIVEVESSEL = craftRef AND HASNODE
        AND ALLNODES:LENGTH = 1 AND NEXTNODE = nd.
}

// KSP may publish the updated maneuver list on the following physics tick.
// Do not mistake our just-removed preview for a newly supplied foreign node.
GLOBAL FUNCTION surveyOrbitRelease {
    PARAMETER craftRef.
    PARAMETER nd.
    IF NOT surveyOrbitOwned(craftRef,nd) { RETURN FALSE. }
    REMOVE nd. WAIT 0.1.
    RETURN SHIP = craftRef AND KUNIVERSE:ACTIVEVESSEL = craftRef AND NOT HASNODE.
}

LOCAL FUNCTION _surveyOrbitStop {
    PARAMETER craftRef.
    PARAMETER stopUt.
    PARAMETER wallEnd.
    PARAMETER report.
    IF TIME:SECONDS >= stopUt { RETURN "game-deadline". }
    IF KUNIVERSE:REALTIME >= wallEnd { RETURN "wall-deadline". }
    IF surveyOrbitIdle(craftRef,FALSE) { RETURN "". }
    diagnosticArchiveLine(report,"STATS scanorbit context active="+(SHIP = KUNIVERSE:ACTIVEVESSEL)
        +" sameCraft="+(SHIP = craftRef)+" abort="+ABORT+" warp="+WARP
        +" settled="+KUNIVERSE:TIMEWARP:ISSETTLED+" hasNode="+HASNODE
        +" nodes="+ALLNODES:LENGTH+" status="+SHIP:STATUS+" nextPatch="+SHIP:ORBIT:HASNEXTPATCH
        +" thrust="+SHIP:THRUST+" raw="+SHIP:CONTROL:MAINTHROTTLE+" pilot="+SHIP:CONTROL:PILOTMAINTHROTTLE
        +" pending="+stateGet("burn_pending","false")+" started="+stateGet("burn_started","false")
        +" phase="+stateGet("phase","")).
    RETURN "context-changed".
}

GLOBAL FUNCTION surveyOrbitSafe {
    PARAMETER obt_.
    PARAMETER lowerAlt.
    PARAMETER upperAlt.
    RETURN obt_:BODY = SHIP:BODY AND NOT obt_:HASNEXTPATCH
        AND obt_:ECCENTRICITY >= 0 AND obt_:ECCENTRICITY < 0.1
        AND obt_:PERIAPSIS >= MAX(lowerAlt,surveyOrbitFloor())
        AND obt_:APOAPSIS >= obt_:PERIAPSIS AND obt_:APOAPSIS <= upperAlt
        AND obt_:APOAPSIS < SHIP:BODY:SOIRADIUS-SHIP:BODY:RADIUS
        AND obt_:INCLINATION >= 75 AND obt_:INCLINATION <= 105
        AND obt_:PERIOD > 0 AND obt_:PERIOD < 1e30.
}

// The supplied cap/reserve can tighten, never relax, the selected mission.
// Charge only a selected, explicitly retained plan, using the shared SHAPE
// ledger. A cancelled plan keeps this conservative reservation like SHAPE.
GLOBAL FUNCTION surveyOrbitAffordable {
    PARAMETER cost.
    PARAMETER cap.
    PARAMETER reserve.
    LOCAL spent IS 0.
    LOCAL id IS SHIP:BODY:NAME + ":" + stateGetNum("launch_time",0).
    IF stateGet("shape_budget_id","") = id { SET spent TO stateGetNum("shape_budget_spent",0). }
    RETURN cost >= 0.3 AND cost <= cap AND cost < 1e30
        AND spent >= 0 AND spent < 1e30
        AND STAGE:DELTAV:VACUUM >= cost + 1
        AND SHIP:AVAILABLETHRUST > 0
        AND SHIP:DELTAV:VACUUM - cost >= reserve
        AND (SHAPE_DV_CAP < 0 OR cost <= SHAPE_DV_CAP)
        AND (SHAPE_TOTAL_DV_CAP < 0 OR spent + cost <= SHAPE_TOTAL_DV_CAP)
        AND (SHAPE_RESERVE_DV < 0 OR SHIP:DELTAV:VACUUM - cost >= SHAPE_RESERVE_DV).
}

// Identical absolute times for every candidate. Two interleaved192-point
// grids must agree on a gain; one sparse sample set must not select a burn.
// One count per1deg cell per grid; cell-centre cosine weights map area.
// Sparse along-track samples omit swath width, sunlight and sensor altitude
// performance. Return unknown on malformed addon data, never "all unscanned".
GLOBAL FUNCTION surveyOrbitScore {
    PARAMETER craftRef.
    PARAMETER nd.
    PARAMETER scanType.
    PARAMETER startUt.
    PARAMETER span.
    PARAMETER stopUt.
    PARAMETER wallEnd.
    PARAMETER details.
    PARAMETER mapCache.
    LOCAL seen IS LIST(LEXICON(),LEXICON()).
    LOCAL scores IS LIST(0,0).
    FROM { LOCAL j IS 0. } UNTIL j >= 384 STEP { SET j TO j + 1. } DO {
        IF NOT surveyOrbitIdle(craftRef,nd <> 0) OR (nd <> 0 AND NOT surveyOrbitOwned(craftRef,nd)) OR TIME:SECONDS >= stopUt
                OR KUNIVERSE:REALTIME >= wallEnd { RETURN -1. }
        LOCAL geo IS lmGroundGeoAt(startUt + span * (j + 0.5) / 384).
        IF NOT (ABS(geo:LAT) <= 90 AND ABS(geo:LNG) < 1e30) { RETURN -1. }
        LOCAL lng IS MOD(MOD(geo:LNG + 180,360) + 360,360) - 180.
        LOCAL latCell IS MIN(179,FLOOR(geo:LAT+90)).
        LOCAL lngCell IS FLOOR(lng+180).
        LOCAL key IS latCell + ":" + lngCell.
        LOCAL lane IS MOD(j,2).
        IF NOT seen[lane]:HASKEY(key) {
            SET seen[lane][key] TO TRUE.
            IF NOT mapCache:HASKEY(key) {
                LOCAL complete IS ADDONS:SCANSAT:COMPLETEDSCANS(SHIP:BODY,LATLNG(latCell-89.5,lngCell-179.5)).
                IF NOT complete:ISTYPE("List") { RETURN -1. }
                SET mapCache[key] TO complete:CONTAINS(scanType).
            }
            IF NOT mapCache[key] { SET scores[lane] TO scores[lane] + COS(latCell-89.5). }
        }
        IF MOD(j,16) = 0 { WAIT 0. }
    }
    SET details["A"] TO scores[0]. SET details["B"] TO scores[1].
    RETURN (scores[0]+scores[1])/2.
}

LOCAL FUNCTION _surveyOrbitGain {
    PARAMETER trial.
    PARAMETER baseline.
    RETURN trial:HASKEY("A") AND trial:HASKEY("B")
        AND trial["A"] >= baseline["A"]+MAX(0.1,baseline["A"]*0.1)
        AND trial["B"] >= baseline["B"]+MAX(0.1,baseline["B"]*0.1).
}

// One gentle apsis change detunes the period; no circularization needed.
// Raising Ap at Pe / lowering Pe at Ap always keeps the other apsis fixed.
GLOBAL FUNCTION surveyOrbitDriftNode {
    PARAMETER raiseAp.
    PARAMETER stepAlt.
    LOCAL pe IS SHIP:PERIAPSIS.
    LOCAL ap IS SHIP:APOAPSIS.
    LOCAL burnRadius IS SHIP:BODY:RADIUS + ap.
    LOCAL otherRadius IS SHIP:BODY:RADIUS + pe - stepAlt.
    LOCAL burnEta IS ETA:APOAPSIS.
    IF raiseAp {
        SET burnRadius TO SHIP:BODY:RADIUS + pe.
        SET otherRadius TO SHIP:BODY:RADIUS + ap + stepAlt.
        SET burnEta TO ETA:PERIAPSIS.
    }
    IF otherRadius <= SHIP:BODY:RADIUS { RETURN 0. }
    IF burnEta < 180 { SET burnEta TO burnEta + SHIP:ORBIT:PERIOD. }
    LOCAL speedNow IS SQRT(SHIP:BODY:MU * (2/burnRadius - 1/SHIP:ORBIT:SEMIMAJORAXIS)).
    LOCAL speedNew IS SQRT(SHIP:BODY:MU * (2/burnRadius - 2/(burnRadius+otherRadius))).
    LOCAL nd IS NODE(TIME:SECONDS+burnEta,0,0,speedNew-speedNow).
    ADD nd. WAIT 0.02.
    RETURN nd.
}

GLOBAL FUNCTION surveyOrbitSearch {
    PARAMETER scanType.
    PARAMETER mode.
    PARAMETER cap.
    PARAMETER reserve.
    PARAMETER report.
    LOCAL craftRef IS SHIP.
    LOCAL out IS LEXICON("OK",FALSE,"REASON","no-useful-change","NODE",0).
    LOCAL period IS SHIP:ORBIT:PERIOD.
    // Repeated previews before the same crossing compare the same epochs.
    // A sliding now+offset window made192 sparse points reverse their ranking
    // after40s with an unchanged native map. Reserve two whole orbits so all
    // accepted burns precede the shared six-orbit comparison window.
    LOCAL startUt IS TIME:SECONDS+etaToTrueAnomaly(-SHIP:ORBIT:ARGUMENTOFPERIAPSIS)+2*period.
    LOCAL stopUt IS TIME:SECONDS + 45.
    LOCAL wallEnd IS KUNIVERSE:REALTIME + 60.
    LOCAL lowerAlt IS MAX(surveyOrbitFloor(),SHIP:PERIAPSIS*0.9).
    LOCAL upperAlt IS SHIP:APOAPSIS*1.1.
    LOCAL stepAlt IS MAX(500,(SHIP:PERIAPSIS+SHIP:APOAPSIS)*0.025).
    LOCAL mapCache IS LEXICON().
    LOCAL baseSamples IS LEXICON().
    LOCAL baseline IS surveyOrbitScore(craftRef,0,scanType,startUt,6*period,stopUt,wallEnd,baseSamples,mapCache).
    IF baseline < 0 { SET out["REASON"] TO "baseline-unavailable-or-deadline". RETURN out. }
    diagnosticArchiveLine(report,"STATS scanorbit baseline type="+scanType+" score="+baseline
        +" gridA="+baseSamples["A"]+" gridB="+baseSamples["B"]
        +" startUt="+startUt+" span="+(6*period)+" samples=384 model=paired-ground-track-points anchor=ascending-crossing"
        +" lowerAlt="+lowerAlt+" upperAlt="+upperAlt).
    LOCAL best IS LEXICON().
    LOCAL bestMerit IS 0.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    LOCAL lan IS SHIP:ORBIT:LAN.
    LOCAL trials IS LIST().
    FOR scale_ IN LIST(0.25,0.5,1,2) {
        FOR kind IN LIST("raise-ap","lower-pe") {
            LOCAL step_ IS MIN(stepAlt*scale_,MAX(0,SHIP:PERIAPSIS-lowerAlt-1)).
            IF kind = "raise-ap" { SET step_ TO MIN(stepAlt*scale_,MAX(0,upperAlt-SHIP:APOAPSIS-1)). }
            IF step_ > 0 { trials:ADD(LEXICON("KIND",kind,"STEP",step_)). }
        }
    }
    FOR kind IN LIST("polar","mirror") { trials:ADD(LEXICON("KIND",kind,"STEP",0)). }
    FOR trial IN trials {
        LOCAL kind IS trial["KIND"].
        LOCAL stopReason IS _surveyOrbitStop(craftRef,stopUt,wallEnd,report).
        IF stopReason <> "" { SET out["REASON"] TO stopReason. RETURN out. }
        LOCAL try_ IS mode = "auto" OR mode = kind OR (mode = "drift" AND (kind = "raise-ap" OR kind = "lower-pe")).
        LOCAL nd IS 0.
        IF try_ {
            IF kind = "raise-ap" OR kind = "lower-pe" {
                SET nd TO surveyOrbitDriftNode(kind = "raise-ap",trial["STEP"]).
            } ELSE {
                LOCAL wantInc IS 90.
                IF kind = "mirror" { SET wantInc TO 180-inc. }
                // Cheap analytic lower estimate; don't run the plane solver
                // for a maneuver already above the allowed cost at apoapsis.
                LOCAL va IS SQRT(SHIP:BODY:MU*(2/(SHIP:BODY:RADIUS+SHIP:APOAPSIS)-1/SHIP:ORBIT:SEMIMAJORAXIS)).
                LOCAL estimate IS 2*va*SIN(ABS(wantInc-inc)/2).
                IF estimate >= 0.3 AND estimate <= cap {
                    SET nd TO planPlaneMatch(wantInc,lan).
                    IF nd <> 0 AND surveyOrbitOwned(craftRef,nd) {
                        IF nd:ETA < 180 { SET nd:TIME TO nd:TIME+period. WAIT 0.02. }
                        // planPlaneMatch's general guard allows5deg; surveying
                        // needs a genuinely different, well-achieved plane.
                        IF ABS(nd:ORBIT:INCLINATION-wantInc) > 0.2
                                OR ABS(MOD(nd:ORBIT:LAN-lan+540,360)-180) > 0.2 {
                            IF NOT surveyOrbitRelease(craftRef,nd) {
                                _surveyOrbitStop(craftRef,stopUt,wallEnd,report).
                                SET out["REASON"] TO "preview-cleanup-context". RETURN out.
                            }
                            SET nd TO 0.
                        }
                    }
                }
            }
        }
        IF nd <> 0 {
            IF NOT surveyOrbitOwned(craftRef,nd) {
                SET out["REASON"] TO "node-ownership-changed". RETURN out.
            }
            LOCAL score IS -1.
            LOCAL samples IS LEXICON("A",-1,"B",-1).
            LOCAL dv IS nd:DELTAV:MAG.
            IF surveyOrbitIdle(craftRef,TRUE) AND surveyOrbitSafe(nd:ORBIT,lowerAlt,upperAlt)
                    AND surveyOrbitAffordable(dv,cap,reserve) AND nd:ETA >= 180
                    AND nd:TIME < startUt {
                SET score TO surveyOrbitScore(craftRef,nd,scanType,startUt,6*period,stopUt,wallEnd,samples,mapCache).
            }
            IF NOT surveyOrbitOwned(craftRef,nd) {
                SET out["REASON"] TO "node-ownership-changed". RETURN out.
            }
            diagnosticArchiveLine(report,"STATS scanorbit candidate mode="+kind+" dv="+dv
                +" score="+score+" baseline="+baseline+" Pe="+nd:ORBIT:PERIAPSIS
                +" Ap="+nd:ORBIT:APOAPSIS+" inc="+nd:ORBIT:INCLINATION+" lan="+nd:ORBIT:LAN
                +" stepM="+trial["STEP"]+" deltaPeriod="+(nd:ORBIT:PERIOD-period)
                +" gridA="+samples["A"]+" gridB="+samples["B"]).
            IF score >= 0 AND _surveyOrbitGain(samples,baseSamples) {
                LOCAL merit IS (score-baseline)/(dv+1).
                IF merit > bestMerit {
                    SET bestMerit TO merit.
                    SET best TO LEXICON("MODE",kind,"UT",nd:TIME,"PRO",nd:PROGRADE,
                        "NRM",nd:NORMAL,"RAD",nd:RADIALOUT,"SCORE",score,"DV",dv,"SAMPLES",samples).
                }
            }
            // Only our node, only while still on the same active vessel.
            // A context switch leaves the preview for manual inspection.
            IF SHIP <> craftRef OR KUNIVERSE:ACTIVEVESSEL <> craftRef {
                SET out["REASON"] TO "vessel-changed-preview-retained". RETURN out.
            }
            IF NOT HASNODE OR ALLNODES:LENGTH <> 1 OR NEXTNODE <> nd {
                SET out["REASON"] TO "node-ownership-changed". RETURN out.
            }
            IF NOT surveyOrbitRelease(craftRef,nd) {
                _surveyOrbitStop(craftRef,stopUt,wallEnd,report).
                SET out["REASON"] TO "preview-cleanup-context". RETURN out.
            }
            IF score < 0 AND (TIME:SECONDS >= stopUt OR KUNIVERSE:REALTIME >= wallEnd) {
                SET out["REASON"] TO "sampling-deadline". RETURN out.
            }
        }
    }
    IF best:LENGTH = 0 { RETURN out. }
    IF NOT surveyOrbitIdle(craftRef,FALSE) { SET out["REASON"] TO "context-changed". RETURN out. }
    LOCAL nd IS NODE(best["UT"],best["RAD"],best["NRM"],best["PRO"]).
    ADD nd. WAIT 0.02.
    IF NOT surveyOrbitOwned(craftRef,nd) { SET out["REASON"] TO "node-ownership-changed". RETURN out. }
    IF NOT surveyOrbitSafe(nd:ORBIT,lowerAlt,upperAlt) OR NOT surveyOrbitAffordable(nd:DELTAV:MAG,cap,reserve)
            OR nd:ETA < 180 OR NOT surveyOrbitIdle(craftRef,TRUE) {
        IF SHIP = craftRef AND KUNIVERSE:ACTIVEVESSEL = craftRef AND HASNODE AND NEXTNODE = nd {
            surveyOrbitRelease(craftRef,nd).
        }
        SET out["REASON"] TO "final-validation". RETURN out.
    }
    LOCAL finalSamples IS LEXICON().
    LOCAL finalScore IS surveyOrbitScore(craftRef,nd,scanType,startUt,6*period,stopUt,wallEnd,finalSamples,mapCache).
    IF NOT surveyOrbitOwned(craftRef,nd) { SET out["REASON"] TO "node-ownership-changed". RETURN out. }
    IF finalScore < 0 OR NOT _surveyOrbitGain(finalSamples,baseSamples) {
        surveyOrbitRelease(craftRef,nd).
        SET out["REASON"] TO "final-score-unconfirmed". RETURN out.
    }
    SET best["SCORE"] TO finalScore. SET best["SAMPLES"] TO finalSamples.
    diagnosticArchiveLine(report,"STATS scanorbit confirmation score="+finalScore
        +" gridA="+finalSamples["A"]+" gridB="+finalSamples["B"]+" baseline="+baseline
        +" baselineA="+baseSamples["A"]+" baselineB="+baseSamples["B"]+" mapCells="+mapCache:LENGTH).
    SET out["OK"] TO TRUE. SET out["REASON"] TO "sampled-improvement".
    SET out["NODE"] TO nd. SET out["BEST"] TO best.
    RETURN out.
}
