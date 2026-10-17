// ============================================================
// landing_light.ks — Future surface sunlight and direct Kerbin view.
// (0:/lib/landing_light.ks)
// Geometry only: independent of panel layout, attitude and electrical flow.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL LANDING_LIGHT_MODE IS "ANY". // ANY, SUNLIT, MORNING
GLOBAL LANDING_SUN_MIN_ELEV IS 10.
GLOBAL LANDING_SUN_MAX_ELEV IS 30.
GLOBAL LANDING_SUN_PREFERRED_ELEV IS 15.
GLOBAL LANDING_REQUIRE_KERBIN IS 0.
GLOBAL LANDING_KERBIN_MIN_ELEV IS 5.
GLOBAL LANDING_LIGHT_SCAN_ORBITS IS 4.
GLOBAL LANDING_LIGHT_SCAN_SAMPLES IS 128.
GLOBAL LANDING_LIGHT_TIME_MARGIN IS 300.

GLOBAL FUNCTION landingLightActive {
    RETURN LANDING_LIGHT_MODE <> "ANY" OR LANDING_REQUIRE_KERBIN > 0.
}

// Inverse of lmGroundGeoAt's rotation correction. All vectors use the
// current SHIP-RAW origin/axes. Future BODY positions share that origin;
// future VESSEL positions have different parent-motion semantics.
LOCAL FUNCTION _landingSurfaceOffsetAt {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER ut.
    LOCAL bdy IS SHIP:BODY.
    LOCAL longitude_ IS lng.
    IF ABS(bdy:ROTATIONPERIOD) > 0.01 {
        SET longitude_ TO lng + 360 * (ut - TIME:SECONDS) / bdy:ROTATIONPERIOD.
    }
    RETURN LATLNG(lat, longitude_):ALTITUDEPOSITION(0) - bdy:POSITION.
}

LOCAL FUNCTION _landingElevation {
    PARAMETER normal_.
    PARAMETER direction_.
    IF direction_:MAG < 1 { RETURN -90. }
    RETURN ARCSIN(MAX(-1, MIN(1, VDOT(normal_, direction_:NORMALIZED)))).
}

// Reject even partial eclipses by an ancestor body. Surface horizon and
// ridge shadows are separate: the elevation margin is not a terrain model.
LOCAL FUNCTION _landingSunClear {
    PARAMETER sitePos.
    PARAMETER toSun.
    PARAMETER ut.
    LOCAL ancestor IS SHIP:BODY.
    UNTIL NOT ancestor:HASBODY {
        SET ancestor TO ancestor:BODY.
        IF ancestor:NAME = SUN:NAME { BREAK. }
        LOCAL toBlocker IS POSITIONAT(ancestor, ut) - sitePos.
        LOCAL along_ IS VDOT(toBlocker, toSun:NORMALIZED).
        IF along_ > 0 AND along_ < toSun:MAG {
            LOCAL miss IS (toBlocker - along_ * toSun:NORMALIZED):MAG.
            LOCAL shadowRadius IS ancestor:RADIUS + SUN:RADIUS * along_ / toSun:MAG.
            IF miss <= shadowRadius { RETURN FALSE. }
        }
    }
    RETURN TRUE.
}

GLOBAL FUNCTION landingLightAt {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER ut.
    LOCAL out IS LEXICON("OK", FALSE, "REASON", "invalid-light-config",
        "SUN", -90, "KERBIN", -90, "RISING", FALSE).
    IF LANDING_LIGHT_MODE <> "ANY" AND LANDING_LIGHT_MODE <> "SUNLIT"
            AND LANDING_LIGHT_MODE <> "MORNING" { RETURN out. }
    IF LANDING_SUN_MIN_ELEV < 0 OR LANDING_SUN_MAX_ELEV > 90
            OR LANDING_SUN_MAX_ELEV < LANDING_SUN_MIN_ELEV
            OR LANDING_KERBIN_MIN_ELEV < 0 OR LANDING_KERBIN_MIN_ELEV > 90 {
        RETURN out.
    }
    LOCAL offset IS _landingSurfaceOffsetAt(lat, lng, ut).
    IF offset:MAG < 1 { RETURN out. }
    LOCAL sitePos IS POSITIONAT(SHIP:BODY, ut) + offset.
    LOCAL toSun IS POSITIONAT(SUN, ut) - sitePos.
    IF toSun:MAG < 1 { RETURN out. }
    LOCAL sunElev IS _landingElevation(offset:NORMALIZED, toSun).
    LOCAL nextOffset IS _landingSurfaceOffsetAt(lat, lng, ut + 60).
    LOCAL nextSun IS POSITIONAT(SUN, ut + 60)
        - POSITIONAT(SHIP:BODY, ut + 60) - nextOffset.
    SET out["SUN"] TO sunElev.
    SET out["RISING"] TO _landingElevation(nextOffset:NORMALIZED, nextSun) > sunElev + 0.00001.
    SET out["KERBIN"] TO _landingElevation(offset:NORMALIZED,
        POSITIONAT(BODY("Kerbin"), ut) - sitePos).
    SET out["REASON"] TO "sun-below-margin".
    IF LANDING_LIGHT_MODE <> "ANY" {
        IF sunElev < LANDING_SUN_MIN_ELEV { RETURN out. }
        SET out["REASON"] TO "eclipse".
        IF NOT _landingSunClear(sitePos, toSun, ut) { RETURN out. }
        IF LANDING_LIGHT_MODE = "MORNING" {
            SET out["REASON"] TO "not-morning".
            IF NOT out["RISING"] OR sunElev > LANDING_SUN_MAX_ELEV { RETURN out. }
        }
    }
    SET out["REASON"] TO "kerbin-below-margin".
    IF LANDING_REQUIRE_KERBIN > 0 AND out["KERBIN"] < LANDING_KERBIN_MIN_ELEV { RETURN out. }
    SET out["OK"] TO TRUE.
    SET out["REASON"] TO "ok".
    RETURN out.
}

// Ballistic impact time is a proxy for powered touchdown time. Sample a
// configurable window around it; do not claim a continuous radio/power link.
GLOBAL FUNCTION landingLightWindow {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER ut.
    LOCAL center IS landingLightAt(lat, lng, ut).
    IF NOT center["OK"] { RETURN center. }
    FOR fraction IN LIST(-1, -0.5, 0.5, 1) {
        LOCAL sample IS landingLightAt(lat, lng,
            ut + fraction * MAX(60, LANDING_LIGHT_TIME_MARGIN)).
        IF NOT sample["OK"] { RETURN sample. }
    }
    RETURN center.
}

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
    LOCAL samples IS 0.
    UNTIL sampleUT > endUT {
        LOCAL geo IS lmGroundGeoAt(sampleUT).
        LOCAL light IS landingLightAt(geo:LAT, geo:LNG, sampleUT).
        IF light["OK"] {
            LOCAL score IS ABS(light["SUN"] - LANDING_SUN_PREFERRED_ELEV)
                + 0.1 * (sampleUT - startUT) / period.
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
    mLog("STATS landing-light search found=" + out["FOUND"] + " lastReason=" + out["REASON"]
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
    mLog("STATS landing-light node ok=" + light["OK"] + " reason=" + light["REASON"]
        + " sun=" + ROUND(light["SUN"],2) + " kerbin=" + ROUND(light["KERBIN"],2)).
    RETURN light["OK"].
}
