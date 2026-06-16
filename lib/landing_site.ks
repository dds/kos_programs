// ============================================================
// landing_site.ks  —  SCANsat landing-site selection
// (0:/lib/landing_site.ks)
//
// Slope/biome site scan around a deorbit target (Mun lander and
// probe-drop flows; gated by LANDING_SITE_SCAN_ENABLE). Split
// out of deorbit_targeting so the Kerbin return bands stop
// carrying it. deorbit_targeting calls it only when this lib
// loaded this boot.
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL LANDING_SITE_SCAN_ENABLE IS 0.
GLOBAL LANDING_SITE_SCAN_RADIUS IS 1500.
GLOBAL LANDING_SITE_SCAN_STEP IS 250.
GLOBAL LANDING_SITE_MAX_SLOPE IS 12.

GLOBAL FUNCTION selectScanSatLandingSite {
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL out IS LEXICON(
        "FOUND", FALSE,
        "LAT", targetLat,
        "LNG", targetLng,
        "SLOPE", -1,
        "ELEV", -1,
        "DIST", 0
    ).

    LOCAL enabled IS 0.
    IF LANDING_SITE_SCAN_ENABLE > 0 {
        SET enabled TO LANDING_SITE_SCAN_ENABLE.
    }
    IF enabled <= 0 { RETURN out. }

    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("Site scan: SCANsat unavailable.").
        RETURN out.
    }

    LOCAL radius IS 1000.
    IF LANDING_SITE_SCAN_RADIUS > 0 {
        SET radius TO LANDING_SITE_SCAN_RADIUS.
    }
    LOCAL step IS 250.
    IF LANDING_SITE_SCAN_STEP > 0 {
        SET step TO LANDING_SITE_SCAN_STEP.
    }
    LOCAL maxSlope IS 12.
    IF LANDING_SITE_MAX_SLOPE > 0 {
        SET maxSlope TO LANDING_SITE_MAX_SLOPE.
    }

    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(targetLat)).
    LOCAL bestScore IS 999999999.
    LOCAL samples IS 0.
    LOCAL known IS 0.
    LOCAL rejectedSlope IS 0.

    FROM { LOCAL north_ IS -radius. } UNTIL north_ > radius STEP { SET north_ TO north_ + step. } DO {
        FROM { LOCAL east_ IS -radius. } UNTIL east_ > radius STEP { SET east_ TO east_ + step. } DO {
            LOCAL candLat IS targetLat + north_ * degPerM.
            LOCAL candLng IS targetLng + east_ * degPerM / lonScale.
            LOCAL candGeo IS LATLNG(candLat, candLng).
            SET samples TO samples + 1.

            LOCAL elev IS ADDONS:SCANSAT:ELEVATION(SHIP:BODY, candGeo).
            IF elev >= 0 {
                SET known TO known + 1.
                LOCAL slope IS ADDONS:SCANSAT:SLOPE(SHIP:BODY, candGeo).
                IF slope >= 0 AND slope <= maxSlope {
                    LOCAL dist IS SQRT(north_ * north_ + east_ * east_).
                    LOCAL score IS dist / 100 + slope * 25.
                    IF score < bestScore {
                        SET bestScore TO score.
                        SET out["FOUND"] TO TRUE.
                        SET out["LAT"] TO candLat.
                        SET out["LNG"] TO candLng.
                        SET out["SLOPE"] TO slope.
                        SET out["ELEV"] TO elev.
                        SET out["DIST"] TO dist.
                    }
                } ELSE {
                    SET rejectedSlope TO rejectedSlope + 1.
                }
            }
        }
        WAIT 0.
    }

    IF out["FOUND"] {
        mLog("Site scan selected: d=" + ROUND(out["DIST"],0)
            + "m slope=" + ROUND(out["SLOPE"],1) + ".").
    } ELSE {
        mLogWarn("Site scan found no safe site.").
    }

    RETURN out.
}
