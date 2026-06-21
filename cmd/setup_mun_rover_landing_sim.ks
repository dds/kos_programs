// cmd/setup_mun_rover_landing_sim.ks
// Prepare a simulation copy in low Mun orbit for emergency rover landing.
// Usage: RUNPATH("0:/cmd/setup_mun_rover_landing_sim.ks").

RUNPATH("0:/cmd/landingrescue.ks", "LAND_ASSIST").

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL targetUT IS TIME:SECONDS + 300.
LOCAL targetGeo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, targetUT)).

stateSet("vehicle", "FR3").
stateSet("target", "MUN").
stateSet("payloads", LIST("ASSISTROVER")).
stateSet("mission_id", "mun_rover_emergency_surface").
stateSet("mission_name", "Mun Rover Emergency Surface Release SIM").
stateSet("phase", "LAND_ASSIST").
stateSet("reload_required", "false").
stateSet("reload_reason", "").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").
stateSet("lib_band", "LANDING").

LOCAL profilePath IS missionProfileBegin("FR3", "mun_rover_emergency_surface").
missionOverrideClear().
LOG "SET MISSION_ID TO " + configLiteral("mun_rover_emergency_surface") + "." TO profilePath.
LOG "SET MISSION_NAME TO " + configLiteral("Mun Rover Emergency Surface Release SIM") + "." TO profilePath.
LOG "SET TARGET_ TO " + configLiteral("MUN") + "." TO profilePath.
LOG "SET PAYLOADS TO " + configLiteral(LIST("ASSISTROVER")) + "." TO profilePath.
LOG "SET PROGRESSIVE_RELOAD TO " + configLiteral(1) + "." TO profilePath.
LOG "SET SEQUENCE TO " + configLiteral(LIST("LAND_DEORBIT", "LAND_ASSIST", "DONE")) + "." TO profilePath.
LOG "SET TARGET_PE TO " + configLiteral(15000) + "." TO profilePath.
LOG "SET TARGET_AP TO " + configLiteral(15000) + "." TO profilePath.
LOG "SET TARGET_INCLINATION TO " + configLiteral(90) + "." TO profilePath.
LOG "SET TARGET_LAT TO " + configLiteral(targetGeo:LAT) + "." TO profilePath.
LOG "SET TARGET_LNG TO " + configLiteral(targetGeo:LNG) + "." TO profilePath.
LOG "SET TARGET_LOCK TO " + configLiteral(1) + "." TO profilePath.
LOG "SET TARGET_WAYPOINT TO " + configLiteral("") + "." TO profilePath.
LOG "SET LANDING_AUTO_TARGET TO " + configLiteral(1) + "." TO profilePath.
LOG "SET LANDING_AUTO_TARGET_MINUTES TO " + configLiteral(5) + "." TO profilePath.
LOG "SET LANDING_SIM_MODE TO " + configLiteral(1) + "." TO profilePath.
LOG "SET LANDING_SKIP_TARGET_SEARCH TO " + configLiteral(1) + "." TO profilePath.
LOG "SET LANDING_DEORBIT_LEAD_MINUTES TO " + configLiteral(0.5) + "." TO profilePath.
LOG "SET TARGET_TOLERANCE TO " + configLiteral(2500) + "." TO profilePath.
LOG "SET GUIDANCE_ALT TO " + configLiteral(5000) + "." TO profilePath.
LOG "SET TARGET_DEORBIT_SCAN_ORBITS TO " + configLiteral(2) + "." TO profilePath.
LOG "SET TARGET_DEORBIT_SCAN_SAMPLES TO " + configLiteral(256) + "." TO profilePath.
LOG "SET TARGET_DEORBIT_SCAN_CENTER_MINUTES TO " + configLiteral(5) + "." TO profilePath.
LOG "SET TARGET_DEORBIT_SCAN_WINDOW_MINUTES TO " + configLiteral(4) + "." TO profilePath.
LOG "SET TARGET_DEORBIT_MIN_LEAD TO " + configLiteral(60) + "." TO profilePath.
LOG "SET LANDING_SITE_SCAN_ENABLE TO " + configLiteral(1) + "." TO profilePath.
LOG "SET LANDING_SITE_SCAN_RADIUS TO " + configLiteral(1500) + "." TO profilePath.
LOG "SET LANDING_SITE_SCAN_STEP TO " + configLiteral(250) + "." TO profilePath.
LOG "SET LANDING_SITE_MAX_SLOPE TO " + configLiteral(12) + "." TO profilePath.
LOG "SET MAX_TILT TO " + configLiteral(12) + "." TO profilePath.
LOG "SET RELOAD_AFTER_LAND_ASSIST TO " + configLiteral(0) + "." TO profilePath.
LOG "SET RELOAD_AFTER_LAND TO " + configLiteral(0) + "." TO profilePath.

PRINT "SIM rover landing setup complete.".
PRINT "Emergency assist-only setup complete.".
PRINT "Target locked near ground track T+5m:".
PRINT "  lat=" + ROUND(targetGeo:LAT,4) + " lng=" + ROUND(targetGeo:LNG,4).
PRINT "Then run landingcheck, then REBOOT.".
