// cmd/setup_mun_rover_landing_real.ks
// Rescue/setup the real FR3 Mun rover for emergency surface landing.
// Usage: RUNPATH("0:/cmd/setup_mun_rover_landing_real.ks").

RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

stateSet("vehicle", "FR3").
stateSet("target", "MUN").
stateSet("payloads", "ASSISTROVER").
stateSet("mission_id", "mun_rover_emergency_surface").
stateSet("mission_name", "Mun Rover Emergency Surface Release").
stateSet("phase", "LAND_DEORBIT").
stateSet("reload_required", "true").
stateSet("reload_reason", "landing-setup").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").
stateSet("lib_band", "LAND_DEORBIT").

_cfg("MISSION_ID", "mun_rover_emergency_surface").
_cfg("MISSION_NAME", "Mun Rover Emergency Surface Release").
_cfg("TARGET", "MUN").
_cfg("PAYLOADS", "ASSISTROVER").
_cfg("PROGRESSIVE_RELOAD", "1").
_cfg("SEQUENCE", "LAND_DEORBIT,LAND_ASSIST,DONE").
_cfg("TARGET_PE", "15000").
_cfg("TARGET_AP", "15000").
_cfg("TARGET_INCLINATION", "90").
_cfg("DEORBIT_PE", "-3000").
_cfg("LANDING_DEORBIT_MIN_DV", "350").
_cfg("LANDING_DEORBIT_MAX_DV", "600").
_cfg("TARGET_TOLERANCE", "2500").
_cfg("GUIDANCE_ALT", "5000").
_cfg("TARGET_DEORBIT_SCAN_ORBITS", "5").
_cfg("TARGET_DEORBIT_SCAN_SAMPLES", "512").
_cfg("TARGET_DEORBIT_COARSE_STOP_DIST", "8000").
_cfg("TARGET_DEORBIT_REFINE_TOLERANCE", "250").
_cfg("TARGET_DEORBIT_PROCEED_ON_MISS", "0").
_cfg("LANDING_SITE_SCAN_ENABLE", "1").
_cfg("LANDING_SITE_SCAN_RADIUS", "1500").
_cfg("LANDING_SITE_SCAN_STEP", "250").
_cfg("LANDING_SITE_MAX_SLOPE", "12").
_cfg("MAX_TILT", "12").
_cfg("DEORBIT_OVERSHOOT", "1500").
_cfg("DEORBIT_OVERSHOOT_TOLERANCE", "1200").
_cfg("GUIDANCE_CORRECTION_THRESHOLD", "500").
_cfg("RELOAD_AFTER_LAND_ASSIST", "0").
_cfg("RELOAD_AFTER_LAND", "0").

PRINT "Rover landing setup complete.".
PRINT "Phase: LAND_DEORBIT -> LAND_ASSIST -> DONE.".
PRINT "Select a waypoint on the map, then REBOOT.".
