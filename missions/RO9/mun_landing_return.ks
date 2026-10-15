// RO9 Mun landing, surface ascent and shallow Kerbin return

SET MISSION_ID TO "mun_landing_return".
SET MISSION_NAME TO "RO9 mun Landing and Return".
SET TARGET_ TO "mun".
SET PAYLOADS TO LIST("SCISAT").
SET PARKING_ALT TO 78000.
SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "CAPTURE", "SHAPE", "SCIENCE_OPS", "LAND_DEORBIT", "LAND_ASSIST",
    "SURFACE_RETURN_SETUP").

// Kerbin ascent and 78 km parking orbit.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "BODY_ORBIT".
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.

SET CAPTURE_PE TO 15000.
SET CAPTURE_INC TO 90.
SET CAPTURE_DIR TO "POLAR".
SET BPLANE_REQUIRE_PLANE TO 1.
SET TARGET_PE TO 15000.
SET TARGET_AP TO 100000.
// Capture preserves the arrival plane; SHAPE finishes any residual
// plane/apsis error before the polar science orbit is considered ready.
SET SHAPE_PE TO 15000.
SET SHAPE_AP TO 15000.
SET SHAPE_INC TO 90.

// Precision is optional when fuel is marginal: hold with the original
// encounter/orbit rather than silently buying a different arrival.
// These are capture/landing floors, not a guarantee of return fuel.
SET BPLANE_TRIM_DV_CAP TO 10.
SET BPLANE_TRIM_TOTAL_DV_CAP TO 20.
SET BPLANE_TRIM_RESERVE_DV TO 900.
SET BPLANE_MAX_ARRIVAL_SHIFT TO 600.
SET BPLANE_MAX_CAPTURE_DV_INCREASE TO 5.
SET SHAPE_DV_CAP TO 10.
SET SHAPE_TOTAL_DV_CAP TO 20.
SET SHAPE_RESERVE_DV TO 650.


// Hold in polar orbit for both contract temperature readings before landing.
SET SCIENCE_OPS_HOLD TO 1.
// Each entry: latitude, longitude, exclusive minimum altitude (metres ASL).
SET SCIENCE_SURVEY_POINTS TO LIST(
    LIST(-66.765, 0.528, 10000), LIST(-39.831, 17.824, 10000)).

// Automated landing: contract site, with terrain refinement nearby.
// Contract landing site supplied by the operator.
SET TARGET_LAT TO 44.593.
SET TARGET_LNG TO -24.926.
SET TARGET_LOCK TO 1.
SET LANDING_AUTO_TARGET TO 0.
SET LANDING_CONFIRM_TARGET TO 0.
SET TARGET_TOLERANCE TO 1500.
SET GUIDANCE_ALT TO 3000.
SET TARGET_DEORBIT_SCAN_ORBITS TO 8.
SET TARGET_DEORBIT_SCAN_SAMPLES TO 512.
SET TARGET_DEORBIT_MIN_LEAD TO 120.
SET LANDING_SITE_SCAN_ENABLE TO 1.
SET LANDING_SITE_SCAN_RADIUS TO 500.
SET LANDING_SITE_SCAN_STEP TO 100.
SET LANDING_SITE_MAX_SLOPE TO 8.
SET TERRAIN_CHECK_RADIUS TO 500.
SET TERRAIN_CHECK_STEP TO 100.
SET MAX_TILT TO 12.
SET RELOAD_AFTER_LAND_ASSIST TO 0.
SET RELOAD_AFTER_LAND TO 0.

// After touchdown, generate the surface-ascent leg, then the Kerbin leg.
// Return setup persists these values through both profile changes/reboots.
SET SURFACE_RETURN_PARKING_ALT TO 10000.
SET SURFACE_RETURN_INCLINATION TO 90.
SET RETURN_SEQUENCE TO LIST(
    "ESCAPE", "COAST", "MCC", "RETURN_TRIM", "AERO9RAKE", "DESCENT", "DONE").
// Unshielded craft: target a 53 km initial Pe and allow repeated passes.
// Optional KSC corrections must preserve the 52-54 km entry corridor.
// This is a planned orbit constraint, not a thermal guarantee.
SET RETURN_PE TO 53000.
SET RETURN_PE_TOLERANCE TO 1000.
SET RETURN_REENTRY_DIR TO "RETRO9RADE".
SET RETURN_KSC_TARGET TO 1.
SET RETURN_KSC_TRIM_DV_CAP TO 20.
SET RETURN_ARM_CHUTES TO 1.
// Keep propulsion attached throughout aerobraking; DESCENT only starts
// after the craft is captured and below the aerobrake handoff speed.
SET RETURN_DESCENT_DECOUPLER_TAG TO "descent_decoupler".
SET RETURN_DESCENT_DECOUPLE_ALT TO 50500.
SET RETURN_DESCENT_CHUTES_TAG TO "descent_chutes".
SET RETURN_DESCENT_RELEASE_ALT TO 38000.
