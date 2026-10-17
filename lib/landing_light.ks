// landing_light.ks - Orbital site search and pre-deorbit light checks.
@LAZYGLOBAL OFF.
// Economy braking can stop kilometres beyond the orbital aimpoint. Reserve
// a region around it during planning (20 km lead + 1 km local search);
// powered diversions retain the physical
// Sun/radio floors. This is a geographic margin, not a touchdown predictor.
GLOBAL LANDING_LIGHT_SITE_RADIUS IS 21000.

GLOBAL FUNCTION landingPlanningRadius {
    IF LANDING_FLEXIBLE_SITE <= 0 OR LANDING_ECONOMY_BRAKE <= 0 { RETURN 0. }
    RETURN MAX(0, LANDING_LIGHT_SITE_RADIUS).
}

LOCAL FUNCTION _landingRegionAngle {
    PARAMETER obj.
    PARAMETER ut.
    LOCAL radius IS SHIP:BODY:RADIUS.
    LOCAL theta IS MIN(180, landingPlanningRadius() / radius * 180 / CONSTANT:PI).
    LOCAL chord IS 2 * radius * SIN(theta / 2).
    LOCAL distance IS (landingBodyOffsetAt(obj, ut) - landingBodyOffsetAt(SHIP:BODY, ut)):MAG.
    // Include changing sightline direction across the region (parallax),
    // especially for nearby Kerbin, as well as its changing surface normal.
    RETURN theta + ARCSIN(MIN(1, chord / MAX(1, distance - radius))).
}

GLOBAL FUNCTION landingPlanningLight {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER ut.
    PARAMETER window IS FALSE.
    LOCAL fractions IS LIST(0).
    IF window { SET fractions TO LIST(0, -1, -0.5, 0.5, 1). }
    LOCAL center IS LEXICON().
    FOR fraction IN fractions {
        LOCAL sampleUT IS ut + fraction * MAX(60, LANDING_LIGHT_TIME_MARGIN).
        LOCAL light IS landingLightAt(lat, lng, sampleUT).
        IF NOT light["OK"] { RETURN light. }
        SET light["SUN_REGION_MARGIN"] TO 0.
        SET light["KERBIN_REGION_MARGIN"] TO 0.
        IF landingPlanningRadius() > 0 {
            IF LANDING_LIGHT_MODE <> "ANY" {
                LOCAL band IS landingSunBand().
                SET light["SUN_REGION_MARGIN"] TO _landingRegionAngle(SUN, sampleUT).
                IF light["SUN"] < band["MIN"] + light["SUN_REGION_MARGIN"] {
                    SET light["OK"] TO FALSE.
                    SET light["REASON"] TO "sun-site-margin".
                }
            }
            IF LANDING_REQUIRE_KERBIN > 0 {
                SET light["KERBIN_REGION_MARGIN"] TO _landingRegionAngle(BODY("Kerbin"), sampleUT).
                IF light["KERBIN"] < LANDING_KERBIN_MIN_ELEV + light["KERBIN_REGION_MARGIN"] {
                    SET light["OK"] TO FALSE.
                    SET light["REASON"] TO "kerbin-site-margin".
                }
            }
            IF NOT light["OK"] { RETURN light. }
        }
        IF fraction = 0 { SET center TO light. }
    }
    RETURN center.
}

GLOBAL FUNCTION landingLitGroundTrack {
    LOCAL out IS LEXICON("FOUND", FALSE, "LAT", 0, "LNG", 0,
        "UT", 0, "SUN", -90, "KERBIN", -90, "REASON", "no-reachable-window").
    IF SHIP:ORBIT:ECCENTRICITY >= 1 OR SHIP:PERIAPSIS <= 0 { RETURN out. }
    LOCAL period IS SHIP:ORBIT:PERIOD.
    IF period <= 0 { RETURN out. }
    // Site selection precedes the deorbit solver's CPU scope, and operator
    // previews call us directly. Share its capped, reboot-recoverable budget.
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) {
        stateSet("landing_prior_ipu", priorIpu).
        SET CONFIG:IPU TO MIN(2000, LANDING_MIN_IPU).
    }
    LOCAL startUT IS TIME:SECONDS + MAX(600, period * 0.35).
    LOCAL endUT IS startUT + period * MAX(1, MIN(8, LANDING_LIGHT_SCAN_ORBITS)).
    LOCAL stepSec IS period / MAX(64, MIN(512, LANDING_LIGHT_SCAN_SAMPLES)).
    LOCAL sampleUT IS startUT.
    LOCAL beganUT IS TIME:SECONDS.
    LOCAL bestScore IS 999999999.
    LOCAL preferredSun IS LANDING_SUN_PREFERRED_ELEV.
    IF LANDING_LIGHT_MODE = "AFTERNOON" { SET preferredSun TO LANDING_AFTERNOON_PREFERRED_ELEV. }
    LOCAL samples IS 0.
    LOCAL eligible IS 0.
    LOCAL windowChecks IS 0.
    mLog("STATS landing-light search-start mode=" + LANDING_LIGHT_MODE
        + " requireKerbin=" + LANDING_REQUIRE_KERBIN
        + " orbits=" + MAX(1, MIN(8, LANDING_LIGHT_SCAN_ORBITS))
        + " samplesPerOrbit=" + MAX(64, MIN(512, LANDING_LIGHT_SCAN_SAMPLES))
        + " siteRadius=" + landingPlanningRadius() + " ipu=" + CONFIG:IPU).
    UNTIL sampleUT > endUT OR ABORT {
        LOCAL geo IS lmGroundGeoAt(sampleUT).
        LOCAL light IS landingPlanningLight(geo:LAT, geo:LNG, sampleUT).
        IF light["OK"] {
            SET eligible TO eligible + 1.
            LOCAL score IS MAX(0, LANDING_LIGHT_SUN_WEIGHT)
                * ABS(light["SUN"] - light["SUN_REGION_MARGIN"] - preferredSun)
                + 0.1 * (sampleUT - startUT) / period.
            IF LANDING_REQUIRE_KERBIN > 0 {
                SET score TO score + MAX(0, LANDING_LIGHT_KERBIN_WEIGHT)
                    * MAX(0, LANDING_KERBIN_PREFERRED_ELEV
                        - (light["KERBIN"] - light["KERBIN_REGION_MARGIN"])).
            }
            IF light["SETTING"] {
                SET score TO score + MAX(0, LANDING_LIGHT_SETTING_PENALTY).
            }
            IF score < bestScore {
                SET windowChecks TO windowChecks + 1.
                SET light TO landingPlanningLight(geo:LAT, geo:LNG, sampleUT, TRUE).
                IF light["OK"] {
                    SET bestScore TO score.
                    SET out TO LEXICON("FOUND", TRUE, "LAT", geo:LAT, "LNG", geo:LNG,
                        "UT", sampleUT, "SUN", light["SUN"], "KERBIN", light["KERBIN"], "REASON", "ok").
                }
            }
        } ELSE IF NOT out["FOUND"] { SET out["REASON"] TO light["REASON"]. }
        SET sampleUT TO sampleUT + stepSec.
        SET samples TO samples + 1.
        IF MOD(samples, 64) = 0 {
            mLog("STATS landing-light search-progress samples=" + samples
                + " elapsed=" + ROUND(TIME:SECONDS - beganUT,1)
                + " eligible=" + eligible + " windows=" + windowChecks
                + " found=" + out["FOUND"] + " lastReason=" + out["REASON"]).
        }
        IF MOD(samples, 8) = 0 { WAIT 0. }
    }
    IF ABORT { SET out["FOUND"] TO FALSE. SET out["REASON"] TO "aborted". }
    SET CONFIG:IPU TO priorIpu.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) { stateRemove("landing_prior_ipu"). }
    mLog("STATS landing-light search mode=" + LANDING_LIGHT_MODE + " requireKerbin=" + LANDING_REQUIRE_KERBIN
        + " minKerbin=" + LANDING_KERBIN_MIN_ELEV
        + " preferredKerbin=" + LANDING_KERBIN_PREFERRED_ELEV
        + " siteRadius=" + landingPlanningRadius()
        + " found=" + out["FOUND"] + " lastReason=" + out["REASON"]
        + " samples=" + samples + " elapsed=" + ROUND(TIME:SECONDS - beganUT,1)
        + " eligible=" + eligible + " windows=" + windowChecks
        + " lat=" + out["LAT"] + " lng=" + out["LNG"]
        + " passUT=" + ROUND(out["UT"],1)
        + " sun=" + out["SUN"] + " kerbin=" + out["KERBIN"]).
    RETURN out.
}

// Shared entry gate: new, timed and reboot-retained deorbit nodes all pass
// here before staging/ignition. Never discard a saved node on rejection.
GLOBAL FUNCTION landingLightNodeAllowed {
    PARAMETER nd.
    PARAMETER targetLat IS 999.
    PARAMETER targetLng IS 999.
    IF NOT landingLightActive() { RETURN TRUE. }
    IF targetLat = 999 OR targetLng = 999 {
        LOCAL targetInfo IS landingResolveTarget().
        IF NOT targetInfo["FOUND"] { RETURN FALSE. }
        SET targetLat TO targetInfo["LAT"].
        SET targetLng TO targetInfo["LNG"].
    }
    IF NOT ADDONS:TR:AVAILABLE { RETURN FALSE. }
    IF NOT ADDONS:TR:ISVERTWOTWO { RETURN FALSE. }
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT { RETURN FALSE. }
    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL impactUT IS TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT.
    IF impactUT <= nd:TIME { RETURN FALSE. }
    LOCAL light IS LEXICON().
    // The larger region is an UNFLOWN orbital planning constraint. Keep the
    // existing point policy for interrupted/suborbital recovery.
    IF SHIP:STATUS = "ORBITING" AND SHIP:PERIAPSIS > 0
            AND stateGet("deorbit_burn_started", "false") <> "true" {
        SET light TO landingPlanningLight(targetLat, targetLng, impactUT, TRUE).
    } ELSE { SET light TO landingLightWindow(targetLat, targetLng, impactUT). }
    mLog("STATS landing-light node mode=" + LANDING_LIGHT_MODE + " requireKerbin=" + LANDING_REQUIRE_KERBIN
        + " ok=" + light["OK"] + " reason=" + light["REASON"]
        + " targetLat=" + targetLat + " targetLng=" + targetLng
        + " impactLat=" + impactPos:LAT
        + " impactLng=" + impactPos:LNG
        + " siteRadius=" + landingPlanningRadius()
        + " sun=" + ROUND(light["SUN"],2) + " kerbin=" + ROUND(light["KERBIN"],2)).
    RETURN light["OK"].
}
