// ============================================================
// fr3_ui.ks - FR3 launch confirmation display
// ============================================================

GLOBAL FUNCTION fr3PrintConfig {
    LOCAL seq IS fr3BuildPhaseSequence().
    LOCAL hasScanSat IS fr3HasPayload("SCANSAT").
    LOCAL hasLander IS fr3HasLandingPayload().

    flightPlanTitle("FR3 FLIGHT DIRECTOR", SHIP:NAME).
    flightPlanIdentity().
    flightPlanRow("LINK", HOMECONNECTION:ISCONNECTED).
    IF stateGet("mission_id", "") <> "" {
        flightPlanRow("MISSION", stateGet("mission_name", stateGet("mission_id", ""))).
        flightPlanRow("PROFILE", stateGet("mission_id", "")).
    }

    flightPlanSection("ASCENT PACKAGE").
    flightPlanRow("PARK ALT", ROUND(CFG["PARKING_ALT"]/1000,0) + " km").
    LOCAL incStr IS CFG["LAUNCH_INCLINATION"] + " deg".
    IF CFG["LAUNCH_INCLINATION"] = 0 { SET incStr TO "0 deg  (equatorial)". }
    flightPlanRow("INCL", incStr).
    flightPlanRow("FAIRING", ROUND(CFG["FAIRING_ALT"]/1000,0) + " km").
    IF MISSION["target"]:TOUPPER <> "KERBIN" {
        flightPlanSection("TRANSFER TARGETING").
        flightPlanRow("CAPTURE PE", ROUND(CFG["CAPTURE_PE"]/1000,0) + " km").
        IF CFG:HASKEY("CAPTURE_INC") {
            flightPlanRow("CAPTURE INC", ROUND(CFG["CAPTURE_INC"],1) + " deg").
        }
        IF CFG:HASKEY("CAPTURE_LAN") {
            flightPlanRow("CAPTURE LAN", ROUND(CFG["CAPTURE_LAN"],1) + " deg").
        }
        IF CFG:HASKEY("CAPTURE_AOP") {
            flightPlanRow("CAPTURE AOP", ROUND(CFG["CAPTURE_AOP"],1) + " deg").
        }
    }
    flightPlanSection("FINAL ORBIT").
    flightPlanRow("FINAL ALT", ROUND(CFG["TARGET_AP"]/1000,0) + " km").
    LOCAL tincStr IS CFG["TARGET_INCLINATION"] + " deg".
    IF CFG["TARGET_INCLINATION"] = 0 { SET tincStr TO "0 deg  (equatorial)". }
    flightPlanRow("FINAL INCL", tincStr).
    flightPlanRow("CIRC TOL", "ecc < " + CFG["CIRC_ECC_TOL"]).
    IF hasScanSat {
        flightPlanSection("SCANSAT PAYLOAD").
        flightPlanRow("DEPLOY TAG", CFG["SCANSAT_DECOUPLER_TAG"]).
    }
    IF hasLander {
        flightPlanSection("LANDING PACKAGE").
        LOCAL targetText IS "map-selected waypoint".
        IF LANDING_CFG["TARGET_WAYPOINT"] <> "" {
            SET targetText TO "waypoint " + LANDING_CFG["TARGET_WAYPOINT"].
        } ELSE IF LANDING_CFG["TARGET_LAT"] <> 0 OR LANDING_CFG["TARGET_LNG"] <> 0 {
            SET targetText TO ROUND(LANDING_CFG["TARGET_LAT"],4)
                + " lat  " + ROUND(LANDING_CFG["TARGET_LNG"],4) + " lng".
        }
        flightPlanRow("TARGET", targetText).
        flightPlanRow("DEORBIT PE", ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1) + " km").
        flightPlanRow("TOLERANCE", ROUND(LANDING_CFG["TARGET_TOLERANCE"]/1000,1) + " km").
    }
    flightPlanSection("SEQUENCE").
    flightPlanSequence(seq).
    flightPlanLine().
}
