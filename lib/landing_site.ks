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
    IF CFG:HASKEY("LANDING_SITE_SCAN_ENABLE") {
        SET enabled TO CFG["LANDING_SITE_SCAN_ENABLE"].
    }
    IF enabled <= 0 { RETURN out. }

    IF NOT ADDONS:SCANSAT:AVAILABLE {
        mLogWarn("STATS site-scan status=no-scansat target="
            + ROUND(targetLat,4) + "," + ROUND(targetLng,4)).
        RETURN out.
    }

    LOCAL radius IS 1000.
    IF CFG:HASKEY("LANDING_SITE_SCAN_RADIUS") {
        SET radius TO CFG["LANDING_SITE_SCAN_RADIUS"].
    }
    LOCAL step IS 250.
    IF CFG:HASKEY("LANDING_SITE_SCAN_STEP") {
        SET step TO CFG["LANDING_SITE_SCAN_STEP"].
    }
    LOCAL maxSlope IS 12.
    IF CFG:HASKEY("LANDING_SITE_MAX_SLOPE") {
        SET maxSlope TO CFG["LANDING_SITE_MAX_SLOPE"].
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
                    LOCAL dist IS SQRT(north_^2 + east_^2).
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
        mLogWarn("STATS site-scan result status=selected target="
            + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
            + " selected=" + ROUND(out["LAT"],4) + "," + ROUND(out["LNG"],4)
            + " distM=" + ROUND(out["DIST"],0)
            + " slope=" + ROUND(out["SLOPE"],1)
            + " elev=" + ROUND(out["ELEV"],0)
            + " samples=" + samples
            + " known=" + known
            + " rejectedSlope=" + rejectedSlope).
    } ELSE {
        mLogWarn("STATS site-scan result status=no-site target="
            + ROUND(targetLat,4) + "," + ROUND(targetLng,4)
            + " radiusM=" + ROUND(radius,0)
            + " stepM=" + ROUND(step,0)
            + " maxSlope=" + ROUND(maxSlope,1)
            + " samples=" + samples
            + " known=" + known
            + " rejectedSlope=" + rejectedSlope).
    }

    RETURN out.
}
