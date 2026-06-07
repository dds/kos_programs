// ============================================================
// fr3_ui.ks - FR3 launch confirmation display
// ============================================================

GLOBAL FUNCTION fr3PrintConfig {
    LOCAL seq IS fr3BuildPhaseSequence().
    LOCAL hasScanSat IS fr3HasPayload("SCANSAT").
    LOCAL hasLander IS fr3HasLandingPayload().

    uiTitle("FR3 FLIGHT DIRECTOR", SHIP:NAME).
    uiRow("CODE", codeVersion()).
    uiRow("CORE", CORE:TAG).
    uiRow("LINK", HOMECONNECTION:ISCONNECTED).
    uiRow("FREE", ROUND(CORE:VOLUME:FREESPACE,0) + " bytes").
    IF stateGet("mission_id", "") <> "" {
        uiRow("MISSION", stateGet("mission_name", stateGet("mission_id", ""))).
        uiRow("PROFILE", stateGet("mission_id", "")).
    }
    uiRow("TARGET", MISSION["target"]).
    uiRow("PAYLOADS", MISSION["payloads"]).

    uiSection("ASCENT PACKAGE").
    uiRow("PARK ALT", ROUND(CFG["PARKING_ALT"]/1000,0) + " km").
    LOCAL incStr IS CFG["LAUNCH_INCLINATION"] + " deg".
    IF CFG["LAUNCH_INCLINATION"] = 0 { SET incStr TO "0 deg  (equatorial)". }
    uiRow("INCL", incStr).
    uiRow("FAIRING", ROUND(CFG["FAIRING_ALT"]/1000,0) + " km").
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        uiSection("TRANSFER TARGETING").
        uiRow("CAPTURE PE", ROUND(CFG["CAPTURE_PE"]/1000,0) + " km").
        IF CFG:HASKEY("CAPTURE_INC") {
            uiRow("CAPTURE INC", ROUND(CFG["CAPTURE_INC"],1) + " deg").
        }
        IF CFG:HASKEY("CAPTURE_LAN") {
            uiRow("CAPTURE LAN", ROUND(CFG["CAPTURE_LAN"],1) + " deg").
        }
        IF CFG:HASKEY("CAPTURE_AOP") {
            uiRow("CAPTURE AOP", ROUND(CFG["CAPTURE_AOP"],1) + " deg").
        }
    }
    uiSection("FINAL ORBIT").
    uiRow("FINAL ALT", ROUND(CFG["TARGET_AP"]/1000,0) + " km").
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    uiRow("FINAL INCL", tincStr).
    uiRow("CIRC TOL", "ecc < " + CFG["CIRC_ECC_TOL"]).
    IF hasScanSat {
        uiSection("SCANSAT PAYLOAD").
        uiRow("DEPLOY TAG", CFG["SCANSAT_DECOUPLER_TAG"]).
    }
    IF hasLander {
        uiSection("LANDING PACKAGE").
        LOCAL targetText IS "map-selected waypoint".
        IF LANDING_CFG["TARGET_WAYPOINT"] <> "" {
            SET targetText TO "waypoint " + LANDING_CFG["TARGET_WAYPOINT"].
        } ELSE IF LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0 {
            SET targetText TO ROUND(LANDING_CFG["TARGET_LAT"],4)
                + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng".
        }
        uiRow("TARGET", targetText).
        uiRow("DEORBIT PE", ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + " km").
        uiRow("TOLERANCE", ROUND(LANDING_CFG["TARGET_TOLERANCE"]/1000,1) + " km").
    }
    uiSection("SEQUENCE").
    printSequence(seq).
    uiLine().
}
