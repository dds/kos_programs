// ============================================================
// landing_light.ks — Future surface sunlight and direct Kerbin view.
// (0:/lib/landing_light.ks)
// Geometry only: independent of panel layout, attitude and electrical flow.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL LANDING_LIGHT_MODE IS "ANY". // ANY, SUNLIT, MORNING, AFTERNOON
GLOBAL LANDING_SUN_MIN_ELEV IS 10.
GLOBAL LANDING_SUN_MAX_ELEV IS 30.
GLOBAL LANDING_SUN_PREFERRED_ELEV IS 15.
GLOBAL LANDING_AFTERNOON_MIN_ELEV IS 30.
GLOBAL LANDING_AFTERNOON_MAX_ELEV IS 75.
GLOBAL LANDING_AFTERNOON_PREFERRED_ELEV IS 52.5.
GLOBAL LANDING_REQUIRE_KERBIN IS 0.
GLOBAL LANDING_KERBIN_MIN_ELEV IS 5.
GLOBAL LANDING_LIGHT_SCAN_ORBITS IS 4.
GLOBAL LANDING_LIGHT_SCAN_SAMPLES IS 128.
GLOBAL LANDING_LIGHT_TIME_MARGIN IS 300.

GLOBAL FUNCTION landingLightActive {
    RETURN LANDING_LIGHT_MODE <> "ANY" OR LANDING_REQUIRE_KERBIN > 0.
}

// Inverse of lmGroundGeoAt's rotation correction, in current RAW axes.
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

// Body POSITIONAT wraps a future local orbit at its CURRENT parent center.
// Subtract that center before accumulating the next orbit in the hierarchy.
// Directly subtracting POSITIONAT(Kerbin, ut) and POSITIONAT(Mun, ut)
// otherwise injects Kerbin's solar-orbit displacement into the Mun view.
// Return a common root-centered position; RAW axes still apply.
LOCAL FUNCTION _landingBodyOffsetAt {
    PARAMETER bdy.
    PARAMETER ut.
    LOCAL offset IS V(0, 0, 0).
    LOCAL cursor IS bdy.
    UNTIL NOT cursor:HASBODY {
        SET offset TO offset + POSITIONAT(cursor, ut) - cursor:BODY:POSITION.
        SET cursor TO cursor:BODY.
    }
    RETURN offset.
}

LOCAL FUNCTION _landingSunBand {
    IF LANDING_LIGHT_MODE = "AFTERNOON" {
        RETURN LEXICON("MIN", LANDING_AFTERNOON_MIN_ELEV, "MAX", LANDING_AFTERNOON_MAX_ELEV,
            "PREFERRED", LANDING_AFTERNOON_PREFERRED_ELEV).
    }
    RETURN LEXICON("MIN", LANDING_SUN_MIN_ELEV, "MAX", LANDING_SUN_MAX_ELEV,
        "PREFERRED", LANDING_SUN_PREFERRED_ELEV).
}

LOCAL FUNCTION _landingElevation {
    PARAMETER normal_.
    PARAMETER direction_.
    IF direction_:MAG < 1 { RETURN -90. }
    RETURN ARCSIN(MAX(-1, MIN(1, VDOT(normal_, direction_:NORMALIZED)))).
}

GLOBAL FUNCTION landingKerbinElevationNow {
    PARAMETER lat.
    PARAMETER lng.
    LOCAL sitePos IS LATLNG(lat, lng):ALTITUDEPOSITION(0).
    LOCAL surfaceNormal IS sitePos - SHIP:BODY:POSITION.
    IF surfaceNormal:MAG < 1 { RETURN -90. }
    RETURN _landingElevation(surfaceNormal:NORMALIZED, BODY("Kerbin"):POSITION - sitePos).
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
        LOCAL toBlocker IS _landingBodyOffsetAt(ancestor, ut) - sitePos.
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
        "SUN", -90, "KERBIN", -90, "RISING", FALSE, "SETTING", FALSE).
    IF LANDING_LIGHT_MODE <> "ANY" AND LANDING_LIGHT_MODE <> "SUNLIT"
            AND LANDING_LIGHT_MODE <> "MORNING" AND LANDING_LIGHT_MODE <> "AFTERNOON" { RETURN out. }
    LOCAL band IS _landingSunBand().
    IF band["MIN"] < 0 OR band["MAX"] > 90
            OR band["MAX"] < band["MIN"]
            OR LANDING_KERBIN_MIN_ELEV < 0 OR LANDING_KERBIN_MIN_ELEV > 90 {
        RETURN out.
    }
    LOCAL offset IS _landingSurfaceOffsetAt(lat, lng, ut).
    IF offset:MAG < 1 { RETURN out. }
    LOCAL sitePos IS _landingBodyOffsetAt(SHIP:BODY, ut) + offset.
    LOCAL toSun IS _landingBodyOffsetAt(SUN, ut) - sitePos.
    IF toSun:MAG < 1 { RETURN out. }
    LOCAL sunElev IS _landingElevation(offset:NORMALIZED, toSun).
    LOCAL nextOffset IS _landingSurfaceOffsetAt(lat, lng, ut + 60).
    LOCAL nextSun IS _landingBodyOffsetAt(SUN, ut + 60)
        - _landingBodyOffsetAt(SHIP:BODY, ut + 60) - nextOffset.
    SET out["SUN"] TO sunElev.
    LOCAL nextSunElev IS _landingElevation(nextOffset:NORMALIZED, nextSun).
    SET out["RISING"] TO nextSunElev > sunElev + 0.00001.
    SET out["SETTING"] TO nextSunElev < sunElev - 0.00001.
    SET out["KERBIN"] TO _landingElevation(offset:NORMALIZED,
        _landingBodyOffsetAt(BODY("Kerbin"), ut) - sitePos).
    // Independent live-position check for the stock Mun's circular tidal
    // lock: the same site must not acquire a different Kerbin view while
    // waiting in orbit. Hold if the runtime prediction convention disagrees.
    IF LANDING_REQUIRE_KERBIN > 0 AND SHIP:BODY:NAME = "Mun" {
        LOCAL moonOrbit IS SHIP:BODY:ORBIT.
        IF moonOrbit:ECCENTRICITY < 0.0001
                AND ABS(SHIP:BODY:ROTATIONPERIOD - moonOrbit:PERIOD) < moonOrbit:PERIOD * 0.0001 {
            IF ABS(out["KERBIN"] - landingKerbinElevationNow(lat, lng)) > 0.5 {
                SET out["REASON"] TO "kerbin-frame-mismatch".
                RETURN out.
            }
        }
    }
    SET out["REASON"] TO "sun-below-margin".
    IF LANDING_LIGHT_MODE <> "ANY" {
        IF sunElev < band["MIN"] { RETURN out. }
        SET out["REASON"] TO "eclipse".
        IF NOT _landingSunClear(sitePos, toSun, ut) { RETURN out. }
        IF LANDING_LIGHT_MODE = "MORNING" {
            SET out["REASON"] TO "not-morning".
            IF NOT out["RISING"] OR sunElev > band["MAX"] { RETURN out. }
        } ELSE IF LANDING_LIGHT_MODE = "AFTERNOON" {
            SET out["REASON"] TO "not-afternoon".
            IF NOT out["SETTING"] OR sunElev > band["MAX"] { RETURN out. }
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
    LOCAL band IS _landingSunBand().
    LOCAL samples IS 0.
    UNTIL sampleUT > endUT {
        LOCAL geo IS lmGroundGeoAt(sampleUT).
        LOCAL light IS landingLightAt(geo:LAT, geo:LNG, sampleUT).
        IF light["OK"] {
            LOCAL score IS ABS(light["SUN"] - band["PREFERRED"])
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
    mLog("STATS landing-light search mode=" + LANDING_LIGHT_MODE + " requireKerbin=" + LANDING_REQUIRE_KERBIN
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
