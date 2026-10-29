// landing_light.ks - Runtime regional light policy and pre-deorbit validation.
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
            IF landingRequireKerbin() > 0 {
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
    mLog("STATS landing-light node mode=" + LANDING_LIGHT_MODE + " requireKerbin=" + landingRequireKerbin()
        + " ok=" + light["OK"] + " reason=" + light["REASON"]
        + " targetLat=" + targetLat + " targetLng=" + targetLng
        + " impactLat=" + impactPos:LAT
        + " impactLng=" + impactPos:LNG
        + " siteRadius=" + landingPlanningRadius()
        + " sun=" + ROUND(light["SUN"],2) + " kerbin=" + ROUND(light["KERBIN"],2)).
    RETURN light["OK"].
}
