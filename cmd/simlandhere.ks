// cmd/simlandhere.ks - Pick a reachable simulation landing target ahead.
// Usage: RUNPATH("0:/cmd/simlandhere.ks").      // 5 minutes ahead
//        RUNPATH("0:/cmd/simlandhere.ks", 8).   // 8 minutes ahead

PARAMETER aheadMinutes IS 5.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL FUNCTION _offsetLatLng {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER northM.
    PARAMETER eastM.
    LOCAL degPerM IS 180 / CONSTANT:PI / SHIP:BODY:RADIUS.
    LOCAL lonScale IS MAX(0.01, COS(lat)).
    RETURN LEXICON(
        "LAT", lat + northM * degPerM,
        "LNG", lng + eastM * degPerM / lonScale
    ).
}

LOCAL FUNCTION _bestScanSatSite {
    PARAMETER lat.
    PARAMETER lng.
    LOCAL out IS LEXICON("FOUND", FALSE, "LAT", lat, "LNG", lng, "SLOPE", -1).
    IF NOT ADDONS:SCANSAT:AVAILABLE { RETURN out. }

    LOCAL radius IS 750.
    LOCAL step IS 250.
    LOCAL maxSlope IS 12.
    LOCAL bestScore IS 999999.
    LOCAL known IS 0.
    LOCAL samples IS 0.

    FROM { LOCAL north_ IS -radius. } UNTIL north_ > radius STEP { SET north_ TO north_ + step. } DO {
        FROM { LOCAL east_ IS -radius. } UNTIL east_ > radius STEP { SET east_ TO east_ + step. } DO {
            LOCAL pos IS _offsetLatLng(lat, lng, north_, east_).
            LOCAL geo IS LATLNG(pos["LAT"], pos["LNG"]).
            SET samples TO samples + 1.
            LOCAL elev IS ADDONS:SCANSAT:ELEVATION(SHIP:BODY, geo).
            IF elev >= 0 {
                SET known TO known + 1.
                LOCAL slope IS ADDONS:SCANSAT:SLOPE(SHIP:BODY, geo).
                IF slope >= 0 AND slope <= maxSlope {
                    LOCAL dist IS SQRT(north_ * north_ + east_ * east_).
                    LOCAL score IS slope * 100 + dist / 20.
                    IF score < bestScore {
                        SET bestScore TO score.
                        SET out["FOUND"] TO TRUE.
                        SET out["LAT"] TO pos["LAT"].
                        SET out["LNG"] TO pos["LNG"].
                        SET out["SLOPE"] TO slope.
                    }
                }
            }
        }
        WAIT 0.01.
    }
    PRINT "SCANsat samples=" + samples + " known=" + known.
    RETURN out.
}


LOCAL targetUT IS TIME:SECONDS + aheadMinutes * 60.
LOCAL geo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, targetUT)).
LOCAL lat IS geo:LAT.
LOCAL lng IS geo:LNG.
LOCAL site IS _bestScanSatSite(lat, lng).
LOCAL source IS "ground track T+" + ROUND(aheadMinutes,1) + "m".

IF site["FOUND"] {
    SET lat TO site["LAT"].
    SET lng TO site["LNG"].
    SET source TO source + " SCANsat slope=" + ROUND(site["SLOPE"],1).
}

SET TARGET_LAT TO lat.
SET TARGET_LNG TO lng.
SET TARGET_LOCK TO 1.
SET TARGET_WAYPOINT TO "".
SET LANDING_SIM_MODE TO 1.
SET LANDING_SKIP_TARGET_SEARCH TO 1.
SET LANDING_DEORBIT_LEAD_MINUTES TO aheadMinutes.
SET TARGET_DEORBIT_SCAN_ORBITS TO 2.
SET TARGET_DEORBIT_SCAN_SAMPLES TO 256.
SET TARGET_DEORBIT_SCAN_CENTER_MINUTES TO aheadMinutes.
SET TARGET_DEORBIT_SCAN_WINDOW_MINUTES TO 4.
missionOverrideClear().
LOG "SET TARGET_LAT TO " + configLiteral(TARGET_LAT) + "." TO missionOverridePath().
LOG "SET TARGET_LNG TO " + configLiteral(TARGET_LNG) + "." TO missionOverridePath().
LOG "SET TARGET_LOCK TO " + configLiteral(TARGET_LOCK) + "." TO missionOverridePath().
LOG "SET TARGET_WAYPOINT TO " + configLiteral(TARGET_WAYPOINT) + "." TO missionOverridePath().
LOG "SET LANDING_SIM_MODE TO " + configLiteral(LANDING_SIM_MODE) + "." TO missionOverridePath().
LOG "SET LANDING_SKIP_TARGET_SEARCH TO " + configLiteral(LANDING_SKIP_TARGET_SEARCH) + "." TO missionOverridePath().
LOG "SET LANDING_DEORBIT_LEAD_MINUTES TO " + configLiteral(LANDING_DEORBIT_LEAD_MINUTES) + "." TO missionOverridePath().
LOG "SET TARGET_DEORBIT_SCAN_ORBITS TO " + configLiteral(TARGET_DEORBIT_SCAN_ORBITS) + "." TO missionOverridePath().
LOG "SET TARGET_DEORBIT_SCAN_SAMPLES TO " + configLiteral(TARGET_DEORBIT_SCAN_SAMPLES) + "." TO missionOverridePath().
LOG "SET TARGET_DEORBIT_SCAN_CENTER_MINUTES TO " + configLiteral(TARGET_DEORBIT_SCAN_CENTER_MINUTES) + "." TO missionOverridePath().
LOG "SET TARGET_DEORBIT_SCAN_WINDOW_MINUTES TO " + configLiteral(TARGET_DEORBIT_SCAN_WINDOW_MINUTES) + "." TO missionOverridePath().
stateSet("phase", "LAND_DEORBIT").
stateSet("reload_required", "false").
stateSet("reload_reason", "").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").
stateSet("lib_band", "LAND_DEORBIT").

PRINT "SIM LANDING TARGET".
PRINT "  " + source.
PRINT "  lat=" + ROUND(lat,4) + " lng=" + ROUND(lng,4).
PRINT "  Phase -> LAND_DEORBIT".
mLog("STATS sim-landing-target source=" + source
    + " lat=" + ROUND(lat,4)
    + " lng=" + ROUND(lng,4)).
WAIT 1.
REBOOT.
