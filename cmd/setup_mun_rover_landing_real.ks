// cmd/setup_mun_rover_landing_real.ks
// Rescue/setup the real FR3 Mun rover for emergency surface landing.
// Usage: RUNPATH("0:/cmd/setup_mun_rover_landing_real.ks").

RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").

RUNPATH("1:/lib/boot_lib").
bootPreamble().

stateSet("vehicle", "FR3").
stateSet("target", "MUN").
stateSet("payloads", LIST("ASSISTROVER")).
stateSet("mission_id", "mun_rover_emergency_surface").
stateSet("mission_name", "Mun Rover Emergency Surface Release").
stateSet("phase", "LAND_DEORBIT").
stateSet("reload_required", "true").
stateSet("reload_reason", "landing-setup").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").
stateSet("lib_band", "LAND_DEORBIT").

LOCAL profilePath IS missionProfileBegin("FR3", "mun_rover_emergency_surface").
missionOverrideClear().
LOG "SET MISSION_ID TO " + configLiteral("mun_rover_emergency_surface") + "." TO profilePath.
LOG "SET MISSION_NAME TO " + configLiteral("Mun Rover Emergency Surface Release") + "." TO profilePath.
LOG "SET TARGET_ TO " + configLiteral("MUN") + "." TO profilePath.
LOG "SET PAYLOADS TO " + configLiteral(LIST("ASSISTROVER")) + "." TO profilePath.
LOG "SET PROGRESSIVE_RELOAD TO " + configLiteral(1) + "." TO profilePath.
LOG "SET SEQUENCE TO " + configLiteral(LIST("LAND_DEORBIT", "LAND_ASSIST", "DONE")) + "." TO profilePath.
LOG "SET TARGET_PE TO " + configLiteral(15000) + "." TO profilePath.
LOG "SET TARGET_AP TO " + configLiteral(15000) + "." TO profilePath.
LOG "SET TARGET_INCLINATION TO " + configLiteral(90) + "." TO profilePath.
LOG "SET TARGET_TOLERANCE TO " + configLiteral(2500) + "." TO profilePath.
LOG "SET GUIDANCE_ALT TO " + configLiteral(5000) + "." TO profilePath.
LOG "SET TARGET_DEORBIT_SCAN_ORBITS TO " + configLiteral(5) + "." TO profilePath.
LOG "SET TARGET_DEORBIT_SCAN_SAMPLES TO " + configLiteral(512) + "." TO profilePath.
LOG "SET LANDING_SITE_SCAN_ENABLE TO " + configLiteral(1) + "." TO profilePath.
LOG "SET LANDING_SITE_SCAN_RADIUS TO " + configLiteral(1500) + "." TO profilePath.
LOG "SET LANDING_SITE_SCAN_STEP TO " + configLiteral(250) + "." TO profilePath.
LOG "SET LANDING_SITE_MAX_SLOPE TO " + configLiteral(12) + "." TO profilePath.
LOG "SET MAX_TILT TO " + configLiteral(12) + "." TO profilePath.
LOG "SET GUIDANCE_CORRECTION_THRESHOLD TO " + configLiteral(500) + "." TO profilePath.
LOG "SET RELOAD_AFTER_LAND_ASSIST TO " + configLiteral(0) + "." TO profilePath.
LOG "SET RELOAD_AFTER_LAND TO " + configLiteral(0) + "." TO profilePath.

PRINT "Rover landing setup complete.".
PRINT "Phase: LAND_DEORBIT -> LAND_ASSIST -> DONE.".
PRINT "Select a waypoint on the map, then REBOOT.".
