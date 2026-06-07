// ============================================================
// fr3_profile.ks - FR3 mission profile tweaks
// ============================================================

LOCAL FUNCTION _landingCfgMappings {
    RETURN LIST(
        LIST("LANDING_TARGET_LAT", "TARGET_LAT"),
        LIST("LANDING_TARGET_LNG", "TARGET_LNG"),
        LIST("LANDING_TARGET_WAYPOINT", "TARGET_WAYPOINT"),
        LIST("LANDING_TARGET_LOCK", "TARGET_LOCK"),
        LIST("LANDING_DEORBIT_PE", "DEORBIT_PE"),
        LIST("LANDING_TARGET_TOLERANCE", "TARGET_TOLERANCE"),
        LIST("LANDING_GUIDANCE_ALT", "GUIDANCE_ALT"),
        LIST("LANDING_DEORBIT_OVERSHOOT", "DEORBIT_OVERSHOOT"),
        LIST("LANDING_DEORBIT_OVERSHOOT_TOLERANCE", "DEORBIT_OVERSHOOT_TOLERANCE"),
        LIST("LANDING_ASSIST_DECOUPLER_TAG", "CARRIER_TAG"),
        LIST("LANDING_ASSIST_SURFACE_TIPOVER", "CARRIER_TIP"),
        LIST("LANDING_ASSIST_SURFACE_TIP_TIME", "CARRIER_TIP_TIME"),
        LIST("LANDING_ASSIST_SURFACE_SETTLE_TIME", "CARRIER_SETTLE"),
        LIST("LANDING_ASSIST_MAX_TILT", "MAX_TILT")
    ).
}

LOCAL FUNCTION _copyLandingCfg {
    IF DEFINED LANDING_CFG {
        FOR mapping IN _landingCfgMappings() {
            LOCAL cfgKey IS mapping[0].
            LOCAL landingKey IS mapping[1].
            IF CFG:HASKEY(cfgKey) {
                SET LANDING_CFG[landingKey] TO CFG[cfgKey].
            }
        }
    }
}

GLOBAL FUNCTION fr3ApplyMissionProfile {
    IF MISSION["target"]:TOUPPER = "MUN" AND fr3HasLandingPayload() {
        IF DEFINED LANDING_CFG {
            SET LANDING_CFG["DEORBIT_PE"] TO 5000.
            SET LANDING_CFG["TARGET_TOLERANCE"] TO 2500.
            SET LANDING_CFG["GUIDANCE_ALT"] TO 5000.
        }
    }

    _copyLandingCfg().

    IF MISSION["target"]:TOUPPER = "MUN"
            AND fr3HasPayload("SCANSAT")
            AND fr3HasLandingPayload() {
        // Mun mapper + rover stack: deploy mapper in a useful polar orbit,
        // then spend the remaining vehicle on targeted rover landing.
        SET CFG["CAPTURE_PE"] TO 15000.
        SET CFG["CAPTURE_INC"] TO 90.
        SET CFG["TARGET_PE"] TO 250000.
        SET CFG["TARGET_AP"] TO 250000.
        SET CFG["TARGET_INCLINATION"] TO 90.
        SET CFG["MAX_INCL_CHANGE_DV"] TO 300.
    }
}
