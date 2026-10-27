// landing_route.ks - Shared preparation goals and advisory conic costs.
// Reference estimates never authorize burns or replace native descent checks.
@LAZYGLOBAL OFF.

// -1 apsides choose a low, mildly elliptical orbit above the safety floor.
// -1 plane elements retain the current plane, not the contract's SHAPE_*.
GLOBAL LAND_PREP_AP IS -1.
GLOBAL LAND_PREP_PE IS -1.
GLOBAL LAND_PREP_INC IS -1.
GLOBAL LAND_PREP_LAN IS -1.
GLOBAL LAND_PREP_MIN_PE IS 10000.
GLOBAL LAND_PREP_ALT_TOL IS 1000.
GLOBAL LAND_PREP_ANG_TOL IS 0.5.
GLOBAL LAND_PREP_MIN_BURN_DV IS 0.3.
GLOBAL LAND_PREP_DV_CAP IS 150.
GLOBAL LAND_PREP_TOTAL_DV_CAP IS 300.
GLOBAL LAND_PREP_RESERVE_DV IS 900.

GLOBAL FUNCTION landingPrepTargets {
    LOCAL floorAlt IS MAX(0,LAND_PREP_MIN_PE).
    IF SHIP:BODY:ATM:EXISTS { SET floorAlt TO MAX(floorAlt,SHIP:BODY:ATM:HEIGHT+10000). }
    LOCAL peAlt IS LAND_PREP_PE.
    IF peAlt < 0 { SET peAlt TO MAX(floorAlt,MIN(SHIP:PERIAPSIS,floorAlt+1000)). }
    LOCAL apAlt IS LAND_PREP_AP.
    IF apAlt < 0 { SET apAlt TO peAlt+10000. }
    LOCAL inc IS LAND_PREP_INC.
    IF inc < 0 { SET inc TO SHIP:ORBIT:INCLINATION. }
    LOCAL lan IS LAND_PREP_LAN.
    IF lan < 0 { SET lan TO SHIP:ORBIT:LAN. }
    IF NOT (peAlt >= floorAlt AND apAlt >= peAlt AND inc >= 0 AND inc <= 180
            AND lan >= 0 AND lan < 360 AND apAlt < 1e30) { RETURN LEXICON(). }
    RETURN LEXICON("AP",apAlt,"PE",peAlt,"INC",inc,"LAN",lan).
}

LOCAL FUNCTION _routeSpeed {
    PARAMETER mu.
    PARAMETER atRadius.
    PARAMETER oppositeRadius.
    RETURN SQRT(2*mu*oppositeRadius/(atRadius*(atRadius+oppositeRadius))).
}

LOCAL FUNCTION _routeLatitudeHeights {
    PARAMETER peRadius.
    PARAMETER apRadius.
    PARAMETER siteLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    LOCAL limitLat IS MIN(inc,180-inc).
    IF ABS(siteLat) > limitLat+0.000001 { RETURN LIST(-1,-1). }
    IF ABS(SIN(inc)) < 0.000001 {
        RETURN LIST(peRadius-SHIP:BODY:RADIUS,apRadius-SHIP:BODY:RADIUS).
    }
    LOCAL firstAngle IS ARCSIN(MAX(-1,MIN(1,SIN(siteLat)/SIN(inc)))).
    LOCAL eccentricity IS (apRadius-peRadius)/(apRadius+peRadius).
    LOCAL parameterM IS 2*peRadius*apRadius/(peRadius+apRadius).
    LOCAL firstHeight IS parameterM/(1+eccentricity*COS(firstAngle-SHIP:ORBIT:ARGUMENTOFPERIAPSIS))-SHIP:BODY:RADIUS.
    LOCAL secondHeight IS parameterM/(1+eccentricity*COS(180-firstAngle-SHIP:ORBIT:ARGUMENTOFPERIAPSIS))-SHIP:BODY:RADIUS.
    RETURN LIST(MIN(firstHeight,secondHeight),MAX(firstHeight,secondHeight)).
}

// Two-impulse reference: lower Pe to the surface at Ap, then stop relative
// to the rotating ground at the new Pe. Neither target longitude nor a
// finite powered landing is solved by this idealized cost comparison.
GLOBAL FUNCTION landingRouteEstimate {
    PARAMETER targets.
    PARAMETER siteLat.
    PARAMETER surfaceElevation.
    PARAMETER descentAcc.
    LOCAL result IS LEXICON("VALID",FALSE,"REASON","invalid-orbit-or-target").
    LOCAL radiusM IS SHIP:BODY:RADIUS.
    LOCAL mu IS SHIP:BODY:MU.
    IF targets:LENGTH = 0 OR SHIP:BODY:ATM:EXISTS { RETURN result. }
    IF NOT (mu > 0 AND mu < 1e30 AND radiusM > 0 AND radiusM < 1e30
            AND SHIP:PERIAPSIS > surfaceElevation AND SHIP:APOAPSIS >= SHIP:PERIAPSIS
            AND SHIP:APOAPSIS < 1e30 AND targets["PE"] > surfaceElevation
            AND targets["PE"] >= LAND_PREP_MIN_PE AND targets["AP"] >= targets["PE"]
            AND targets["AP"] < 1e30 AND radiusM+surfaceElevation > 0
            AND ABS(siteLat) <= 90 AND SHIP:ORBIT:ECCENTRICITY >= 0
            AND SHIP:ORBIT:ECCENTRICITY < 1 AND NOT SHIP:ORBIT:HASNEXTPATCH) { RETURN result. }
    LOCAL planeError IS ARCCOS(MAX(-1,MIN(1,COS(SHIP:ORBIT:INCLINATION)*COS(targets["INC"])
        +SIN(SHIP:ORBIT:INCLINATION)*SIN(targets["INC"])*COS(SHIP:ORBIT:LAN-targets["LAN"])))).
    IF NOT (planeError <= 0.0001) {
        SET result["REASON"] TO "plane-change-not-modeled". RETURN result.
    }
    IF ABS(siteLat) > MIN(SHIP:ORBIT:INCLINATION,180-SHIP:ORBIT:INCLINATION)+0.000001 {
        SET result["REASON"] TO "target-latitude-unreachable". RETURN result.
    }
    LOCAL pe0 IS radiusM+SHIP:PERIAPSIS.
    LOCAL ap0 IS radiusM+SHIP:APOAPSIS.
    LOCAL pe1 IS radiusM+targets["PE"].
    LOCAL ap1 IS radiusM+targets["AP"].
    LOCAL surfaceRadius IS radiusM+surfaceElevation.
    // Compare the two ordinary apsis-transfer orders; the native SHAPE
    // planner still selects/validates each actual correction.
    LOCAL orderA IS ABS(_routeSpeed(mu,pe0,ap1)-_routeSpeed(mu,pe0,ap0))
        +ABS(_routeSpeed(mu,ap1,pe1)-_routeSpeed(mu,ap1,pe0)).
    LOCAL orderB IS ABS(_routeSpeed(mu,ap0,pe1)-_routeSpeed(mu,ap0,pe0))
        +ABS(_routeSpeed(mu,pe1,ap1)-_routeSpeed(mu,pe1,ap0)).
    LOCAL prepMin IS MIN(orderA,orderB).
    LOCAL prepMax IS MAX(orderA,orderB).
    LOCAL directDeorbit IS ABS(_routeSpeed(mu,ap0,surfaceRadius)-_routeSpeed(mu,ap0,pe0)).
    LOCAL parkDeorbit IS ABS(_routeSpeed(mu,ap1,surfaceRadius)-_routeSpeed(mu,ap1,pe1)).
    LOCAL spinSpeed IS 0.
    IF ABS(SHIP:BODY:ROTATIONPERIOD) > 0.01 {
        SET spinSpeed TO 2*CONSTANT:PI*surfaceRadius/SHIP:BODY:ROTATIONPERIOD.
    }
    LOCAL directSpeed IS _routeSpeed(mu,surfaceRadius,ap0).
    LOCAL parkSpeed IS _routeSpeed(mu,surfaceRadius,ap1).
    LOCAL eastProjection IS COS(SHIP:ORBIT:INCLINATION).
    LOCAL directStop IS SQRT(MAX(0,directSpeed^2+(spinSpeed*COS(siteLat))^2-2*directSpeed*spinSpeed*eastProjection)).
    LOCAL parkStop IS SQRT(MAX(0,parkSpeed^2+(spinSpeed*COS(siteLat))^2-2*parkSpeed*spinSpeed*eastProjection)).
    LOCAL directTotal IS directDeorbit+directStop.
    LOCAL parkTotalMin IS prepMin+parkDeorbit+parkStop.
    LOCAL parkTotalMax IS prepMax+parkDeorbit+parkStop.
    SET result TO LEXICON("VALID",TRUE,"REASON","reference-only","LAT",siteLat,"ELEVATION",surfaceElevation,
        "PREP_MIN",prepMin,"PREP_MAX",prepMax,"DIRECT_DEORBIT",directDeorbit,"DIRECT_STOP",directStop,
        "DIRECT_TOTAL",directTotal,"PARK_DEORBIT",parkDeorbit,"PARK_STOP",parkStop,
        "PARK_TOTAL_MIN",parkTotalMin,"PARK_TOTAL_MAX",parkTotalMax,
        "PERIOD_BEFORE",2*CONSTANT:PI*SQRT(((pe0+ap0)/2)^3/mu),
        "PERIOD_AFTER",2*CONSTANT:PI*SQRT(((pe1+ap1)/2)^3/mu),
        "CROSSING_BEFORE",_routeLatitudeHeights(pe0,ap0,siteLat),
        "CROSSING_AFTER",_routeLatitudeHeights(pe1,ap1,siteLat),
        "ALLOWANCE_VALID",FALSE,"DESCENT_ACC",descentAcc,"DIRECT_ALLOWANCE",-1,"PARK_ALLOWANCE",-1,
        "TARGET_KNOWN",FALSE,
        "PREP_RESERVE_MARGIN",SHIP:DELTAV:VACUUM-prepMax-LAND_PREP_RESERVE_DV,
        "DIRECT_REMAIN",SHIP:DELTAV:VACUUM-directTotal,
        "PARK_REMAIN",SHIP:DELTAV:VACUUM-parkTotalMax).
    LOCAL gravity IS mu/surfaceRadius^2.
    IF descentAcc > gravity AND descentAcc < 1e30 {
        // Sensitivity allowance only: constant initial acceleration and
        // surface gravity, with all terminal dV treated as vertical braking.
        // Real staging, tilt, terrain and guidance can cost more or less.
        SET result["ALLOWANCE_VALID"] TO TRUE.
        SET result["DIRECT_ALLOWANCE"] TO gravity*directStop/(descentAcc-gravity).
        SET result["PARK_ALLOWANCE"] TO gravity*parkStop/(descentAcc-gravity).
    }
    RETURN result.
}

GLOBAL FUNCTION landingRouteSnapshot {
    PARAMETER targets.
    IF targets:LENGTH = 0 OR SHIP:BODY:ATM:EXISTS {
        RETURN LEXICON("VALID",FALSE,"REASON","reference-unavailable-for-orbit-or-body").
    }
    LOCAL targetSite IS landingResolveTarget().
    LOCAL siteLat IS 0.
    LOCAL surfaceElevation IS 0.
    IF targetSite["FOUND"] {
        IF NOT (ABS(targetSite["LAT"]) <= 90 AND ABS(targetSite["LNG"]) <= 180) {
            RETURN LEXICON("VALID",FALSE,"REASON","invalid-site-coordinates").
        }
        SET siteLat TO targetSite["LAT"].
        SET surfaceElevation TO LATLNG(targetSite["LAT"],targetSite["LNG"]):TERRAINHEIGHT.
    }
    LOCAL descentAcc IS vesselLandingThrust()/MAX(0.01,SHIP:MASS).
    LOCAL reserveAcc IS vesselLandingReserveAcc().
    IF reserveAcc > 0 { SET descentAcc TO MIN(descentAcc,reserveAcc). }
    LOCAL result IS landingRouteEstimate(targets,siteLat,surfaceElevation,descentAcc).
    SET result["TARGET_KNOWN"] TO targetSite["FOUND"].
    RETURN result.
}

GLOBAL FUNCTION landingRouteLines {
    PARAMETER result.
    LOCAL rows IS LIST("STATS landing-route model=apsis-reference valid=" + result["VALID"]
        + " reason=" + result["REASON"] + " policy=existing-preparation").
    IF NOT result["VALID"] { RETURN rows. }
    rows:ADD("STATS landing-route ideal directDv=" + ROUND(result["DIRECT_TOTAL"],2)
        + " prepareDv=" + ROUND(result["PREP_MIN"],2) + "/" + ROUND(result["PREP_MAX"],2)
        + " parkTotalDv=" + ROUND(result["PARK_TOTAL_MIN"],2) + "/" + ROUND(result["PARK_TOTAL_MAX"],2)).
    rows:ADD("STATS landing-route geometry targetKnown=" + result["TARGET_KNOWN"]
        + " lat=" + result["LAT"] + " elevation=" + result["ELEVATION"]
        + " periodBefore=" + ROUND(result["PERIOD_BEFORE"],1) + " periodAfter=" + ROUND(result["PERIOD_AFTER"],1)
        + " crossingBefore=" + result["CROSSING_BEFORE"] + " crossingAfter=" + result["CROSSING_AFTER"]).
    rows:ADD("STATS landing-route sensitivity available=" + result["ALLOWANCE_VALID"]
        + " acceleration=" + result["DESCENT_ACC"] + " directGravityAllowance=" + result["DIRECT_ALLOWANCE"]
        + " parkGravityAllowance=" + result["PARK_ALLOWANCE"]).
    rows:ADD("STATS landing-route budget prepareReserve=" + LAND_PREP_RESERVE_DV
        + " prepareReserveMargin=" + result["PREP_RESERVE_MARGIN"]
        + " referenceRemainingAfterLandingDirect=" + result["DIRECT_REMAIN"]
        + " referenceRemainingAfterLandingPark=" + result["PARK_REMAIN"]).
    rows:ADD("Reference only: longitude, terrain clearance, staging fuel and powered footprint require the native deorbit/landing checks.").
    RETURN rows.
}
