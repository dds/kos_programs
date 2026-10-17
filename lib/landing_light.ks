// landing_light.ks - Orbital site search and pre-deorbit light checks.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingLitGroundTrack {
    LOCAL out IS LEXICON("FOUND", FALSE, "LAT", 0, "LNG", 0,
        "UT", 0, "SUN", -90, "KERBIN", -90, "REASON", "no-reachable-window").
    IF SHIP:ORBIT:ECCENTRICITY >= 1 OR SHIP:PERIAPSIS <= 0 { RETURN out. }
    LOCAL period IS SHIP:ORBIT:PERIOD.
    IF period <= 0 { RETURN out. }
    LOCAL startUT IS TIME:SECONDS + MAX(600, period * 0.35).
    LOCAL endUT IS startUT + period * MAX(1, MIN(8, LANDING_LIGHT_SCAN_ORBITS)).
    LOCAL stepSec IS period / MAX(64, MIN(512, LANDING_LIGHT_SCAN_SAMPLES)).
    LOCAL sampleUT IS startUT.
    LOCAL bestScore IS 999999999.
    LOCAL preferredSun IS LANDING_SUN_PREFERRED_ELEV.
    IF LANDING_LIGHT_MODE = "AFTERNOON" { SET preferredSun TO LANDING_AFTERNOON_PREFERRED_ELEV. }
    LOCAL samples IS 0.
    UNTIL sampleUT > endUT {
        LOCAL geo IS lmGroundGeoAt(sampleUT).
        LOCAL light IS landingLightAt(geo:LAT, geo:LNG, sampleUT).
        IF light["OK"] {
            LOCAL score IS MAX(0, LANDING_LIGHT_SUN_WEIGHT) * ABS(light["SUN"] - preferredSun)
                + 0.1 * (sampleUT - startUT) / period.
            IF LANDING_REQUIRE_KERBIN > 0 {
                SET score TO score + MAX(0, LANDING_LIGHT_KERBIN_WEIGHT)
                    * MAX(0, LANDING_KERBIN_PREFERRED_ELEV - light["KERBIN"]).
            }
            IF light["SETTING"] {
                SET score TO score + MAX(0, LANDING_LIGHT_SETTING_PENALTY).
            }
            IF score < bestScore {
                SET light TO landingLightWindow(geo:LAT, geo:LNG, sampleUT).
                IF light["OK"] {
                    SET bestScore TO score.
                    SET out TO LEXICON("FOUND", TRUE, "LAT", geo:LAT, "LNG", geo:LNG,
                        "UT", sampleUT, "SUN", light["SUN"], "KERBIN", light["KERBIN"], "REASON", "ok").
                }
            }
        } ELSE IF NOT out["FOUND"] { SET out["REASON"] TO light["REASON"]. }
        SET sampleUT TO sampleUT + stepSec.
        SET samples TO samples + 1.
        IF MOD(samples, 8) = 0 { WAIT 0. }
    }
    mLog("STATS landing-light search mode=" + LANDING_LIGHT_MODE + " requireKerbin=" + LANDING_REQUIRE_KERBIN
        + " minKerbin=" + LANDING_KERBIN_MIN_ELEV
        + " preferredKerbin=" + LANDING_KERBIN_PREFERRED_ELEV
        + " found=" + out["FOUND"] + " lastReason=" + out["REASON"]
        + " samples=" + samples + " lat=" + out["LAT"] + " lng=" + out["LNG"]
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
    LOCAL impactUT IS TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT.
    IF impactUT <= nd:TIME { RETURN FALSE. }
    LOCAL light IS landingLightWindow(targetLat, targetLng, impactUT).
    mLog("STATS landing-light node mode=" + LANDING_LIGHT_MODE + " requireKerbin=" + LANDING_REQUIRE_KERBIN
        + " ok=" + light["OK"] + " reason=" + light["REASON"]
        + " lat=" + targetLat + " lng=" + targetLng
        + " sun=" + ROUND(light["SUN"],2) + " kerbin=" + ROUND(light["KERBIN"],2)).
    RETURN light["OK"].
}
