// cmd/setup_mun_rover_landing_sim.ks
// Prepare a simulation copy in low Mun orbit for emergency rover landing.
// Usage: RUNPATH("0:/cmd/setup_mun_rover_landing_sim.ks").

RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

LOCAL targetUT IS TIME:SECONDS + 300.
LOCAL targetGeo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, targetUT)).

stateSet("vehicle", "FR3").
stateSet("target", "MUN").
stateSet("payloads", "ASSISTROVER").
stateSet("mission_id", "mun_rover_emergency_surface").
stateSet("mission_name", "Mun Rover Emergency Surface Release SIM").
stateSet("phase", "LAND_ASSIST").
stateSet("reload_required", "false").
stateSet("reload_reason", "").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").
stateSet("lib_band", "LANDING").

_cfg("MISSION_ID", "mun_rover_emergency_surface").
_cfg("MISSION_NAME", "Mun Rover Emergency Surface Release SIM").
_cfg("TARGET", "MUN").
_cfg("PAYLOADS", "ASSISTROVER").
_cfg("PROGRESSIVE_RELOAD", "1").
_cfg("SEQUENCE", "LAND_DEORBIT,LAND_ASSIST,DONE").
_cfg("TARGET_PE", "15000").
_cfg("TARGET_AP", "15000").
_cfg("TARGET_INCLINATION", "90").
_cfg("TARGET_LAT", targetGeo:LAT).
_cfg("TARGET_LNG", targetGeo:LNG).
_cfg("TARGET_LOCK", "1").
_cfg("TARGET_WAYPOINT", "").
_cfg("LANDING_AUTO_TARGET", "1").
_cfg("LANDING_AUTO_TARGET_MINUTES", "5").
_cfg("LANDING_SIM_MODE", "1").
_cfg("LANDING_SKIP_TARGET_SEARCH", "1").
_cfg("LANDING_DEORBIT_LEAD_MINUTES", "0.5").
_cfg("DEORBIT_PE", "-3000").
_cfg("TARGET_TOLERANCE", "2500").
_cfg("GUIDANCE_ALT", "5000").
_cfg("TARGET_DEORBIT_SCAN_ORBITS", "2").
_cfg("TARGET_DEORBIT_SCAN_SAMPLES", "256").
_cfg("TARGET_DEORBIT_SCAN_CENTER_MINUTES", "5").
_cfg("TARGET_DEORBIT_SCAN_WINDOW_MINUTES", "4").
_cfg("TARGET_DEORBIT_COARSE_STOP_DIST", "12000").
_cfg("TARGET_DEORBIT_REFINE_TOLERANCE", "250").
_cfg("TARGET_DEORBIT_MIN_LEAD", "60").
_cfg("TARGET_DEORBIT_PROCEED_ON_MISS", "0").
_cfg("LANDING_SITE_SCAN_ENABLE", "1").
_cfg("LANDING_SITE_SCAN_RADIUS", "1500").
_cfg("LANDING_SITE_SCAN_STEP", "250").
_cfg("LANDING_SITE_MAX_SLOPE", "12").
_cfg("MAX_TILT", "12").
_cfg("DEORBIT_OVERSHOOT", "1500").
_cfg("DEORBIT_OVERSHOOT_TOLERANCE", "1200").
_cfg("RELOAD_AFTER_LAND_ASSIST", "0").
_cfg("RELOAD_AFTER_LAND", "0").

PRINT "SIM rover landing setup complete.".
PRINT "Emergency assist-only setup complete.".
PRINT "Target locked near ground track T+5m:".
PRINT "  lat=" + ROUND(targetGeo:LAT,4) + " lng=" + ROUND(targetGeo:LNG,4).
PRINT "Then run landingcheck, then REBOOT.".
