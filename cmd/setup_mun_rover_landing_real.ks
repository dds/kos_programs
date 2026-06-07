// cmd/setup_mun_rover_landing_real.ks
// Rescue/setup the real FR3 Mun rover for emergency surface landing.
// Usage: RUNPATH("0:/cmd/setup_mun_rover_landing_real.ks").
// Cached: RUNPATH("1:/cmd/setup_mun_rover_landing_real.ks").

IF EXISTS("0:/cmd/landingrescue.ks") {
    RUNPATH("0:/cmd/landingrescue.ks", "LAND_DEORBIT").
} ELSE IF EXISTS("1:/cmd/landingrescue.ks") {
    RUNPATH("1:/cmd/landingrescue.ks", "LAND_DEORBIT").
}

LOCAL FUNCTION _loadState {
    IF EXISTS("1:/lib/state.ksm") {
        RUNONCEPATH("1:/lib/state.ksm").
    } ELSE IF EXISTS("1:/lib/state.ks") {
        RUNONCEPATH("1:/lib/state.ks").
    } ELSE IF EXISTS("0:/lib/state.ks") {
        RUNONCEPATH("0:/lib/state.ks").
    } ELSE {
        PRINT "No state library found.".
        WAIT UNTIL FALSE.
    }
    stateInit().
}

LOCAL FUNCTION _cfg {
    PARAMETER key.
    PARAMETER value.
    stateSet("mission_cfg_" + key, value).
}

_loadState().

stateSet("vehicle", "FR3").
stateSet("target", "MUN").
stateSet("payloads", "ASSISTROVER").
stateSet("mission_id", "mun_rover_emergency_surface").
stateSet("mission_name", "Mun Rover Emergency Surface Release").
stateSet("phase", "LAND_DEORBIT").
stateSet("reload_required", "false").
stateSet("reload_reason", "").
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
_cfg("LANDING_DEORBIT_PE", "-5000").
_cfg("LANDING_TARGET_TOLERANCE", "2500").
_cfg("LANDING_GUIDANCE_ALT", "5000").
_cfg("TARGET_DEORBIT_SCAN_ORBITS", "32").
_cfg("TARGET_DEORBIT_SCAN_SAMPLES", "2048").
_cfg("TARGET_DEORBIT_COARSE_STOP_DIST", "4000").
_cfg("TARGET_DEORBIT_REFINE_TOLERANCE", "250").
_cfg("TARGET_DEORBIT_PROCEED_ON_MISS", "0").
_cfg("LANDING_SITE_SCAN_ENABLE", "1").
_cfg("LANDING_SITE_SCAN_RADIUS", "1500").
_cfg("LANDING_SITE_SCAN_STEP", "250").
_cfg("LANDING_SITE_MAX_SLOPE", "12").
_cfg("LANDING_ASSIST_RELEASE_ON_SURFACE", "1").
_cfg("LANDING_ASSIST_DECOUPLER_TAG", "probe_decoupler").
_cfg("LANDING_ASSIST_DESCENT_SPEED", "35").
_cfg("LANDING_ASSIST_MAX_TILT", "12").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_HSPEED", "80").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_THROTTLE", "1").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_LEAD", "30").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_MARGIN", "1200").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_FACTOR", "2.4").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_TILT", "25").
_cfg("LANDING_ASSIST_SURFACE_HBRAKE_MARGIN", "500").
_cfg("LANDING_ASSIST_SURFACE_HBRAKE_FACTOR", "1.1").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_RELEASE_HSPEED", "5").
_cfg("LANDING_ASSIST_SURFACE_BRAKE_AOA", "70").
_cfg("LANDING_ASSIST_SURFACE_PANIC_ALT", "2000").
_cfg("LANDING_ASSIST_SURFACE_PANIC_SPEED", "120").
_cfg("LANDING_ASSIST_SURFACE_DROP_ALT", "600").
_cfg("LANDING_ASSIST_SURFACE_DROP_MAX_VSPEED", "120").
_cfg("LANDING_ASSIST_SURFACE_FINAL_ALT", "250").
_cfg("LANDING_ASSIST_SURFACE_FINAL_MAX_SPEED", "4").
_cfg("LANDING_ASSIST_SURFACE_FINAL_SPEED", "0.8").
_cfg("LANDING_ASSIST_SURFACE_FINAL_HSPEED", "2").
_cfg("LANDING_ASSIST_SURFACE_RELEASE_ALT", "8").
_cfg("LANDING_ASSIST_SURFACE_RELEASE_HSPEED", "1").
_cfg("LANDING_ASSIST_SURFACE_RELEASE_VSPEED", "0.5").
_cfg("LANDING_ASSIST_SURFACE_RELEASE_SETTLE", "0.5").
_cfg("LANDING_ASSIST_SURFACE_POWERED_ROVER", "0").
_cfg("LANDING_ASSIST_SURFACE_RELEASE_AFTER_TOUCHDOWN", "1").
_cfg("LANDING_ASSIST_SURFACE_SETTLE_TIME", "2").
_cfg("LANDING_ASSIST_SURFACE_TIPOVER", "1").
_cfg("LANDING_ASSIST_SURFACE_TIP_TIME", "1.5").
_cfg("LANDING_DEORBIT_OVERSHOOT", "1500").
_cfg("LANDING_DEORBIT_OVERSHOOT_TOLERANCE", "1200").
_cfg("LANDING_SITE_GRID_RADIUS", "625").
_cfg("LANDING_SITE_GRID_STEP", "250").
_cfg("LANDING_SITE_MAX_SLOPE", "12").
_cfg("RELOAD_AFTER_LAND_ASSIST", "0").
_cfg("RELOAD_AFTER_LAND", "0").

PRINT "REAL rover landing rescue/setup complete.".
PRINT "Select target waypoint, run landingcheck if possible, then REBOOT.".
