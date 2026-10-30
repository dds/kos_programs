// RO9 in-flight Mun recovery: polar capture, survey hold, targeted landing/return.
SET MISSION_ID TO "mun_capture_recovery".
SET MISSION_NAME TO "RO9 Mun Polar Recovery".
SET TARGET_ TO "mun".
SET PAYLOADS TO LIST("SCISAT").
SET SEQUENCE TO LIST("BPLANE", "COAST_1HALF", "REFINE_BPLANE",
    "COAST_2HALF", "CAPTURE", "SHAPE", "SCIENCE_OPS",
    "LAND_DEORBIT", "LAND_ASSIST", "SURFACE_RETURN_SETUP").

SET BPLANE_PE_ONLY TO 0.
SET BPLANE_REQUIRE_PLANE TO 1.
SET BPLANE_REVIEW_UNCONVERGED TO 1.
SET BPLANE_REVIEW_MIN_PE TO 10000.
SET CAPTURE_PE TO 15000.
SET CAPTURE_INC TO 90.
SET CAPTURE_LAN TO -1.
SET CAPTURE_AOP TO -1.
SET CAPTURE_DIR TO "POLAR".
SET TARGET_PE TO 15000.
SET TARGET_AP TO 100000.
SET BPLANE_PE_TOL TO 2000.
// A polar approach can require more than the old 50 m/s Pe-only cap.
// The cap is a ceiling; every candidate still needs capture fuel + margin.
SET BPLANE_DV_CAP TO 150.
SET REFINE_BPLANE_DV_CAP TO 10.
SET BPLANE_TRIM_DV_CAP TO 150.
SET BPLANE_TRIM_TOTAL_DV_CAP TO 160.
SET BPLANE_TRIM_RESERVE_DV TO -1.
// Lowering Pe changes the SOI chord and thus entry time, even on the
// same pass. Use absolute capture affordability, not optional-trim rules.
SET BPLANE_MAX_ARRIVAL_SHIFT TO -1.
SET BPLANE_MAX_CAPTURE_DV_INCREASE TO -1.
SET BPLANE_CAPTURE_MARGIN TO 50.
SET CAPTURE_RESERVE_DV TO 50.
SET CAPTURE_MIN_PE TO 13000.
SET CAPTURE_MAX_PE TO 17000.
SET CAPTURE_ACCEPT_BOUND TO 1.

// Preserve the captured ellipse; do not spend fuel circularizing solely
// for the survey. SHAPE verifies the actual polar plane after capture.
SET SHAPE_PE TO 15000.
SET SHAPE_AP TO 100000.
SET SHAPE_INC TO 90.
SET SHAPE_LAN TO -1.
SET SHAPE_AOP TO -1.
SET SHAPE_DV_CAP TO 10.
SET SHAPE_TOTAL_DV_CAP TO 20.
SET SHAPE_RESERVE_DV TO 50.
// Contract temperature readings need their locations/altitude conditions.
// Do not automatically deorbit after the single generic experiment pass.
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
    "ESCAPE", "COAST", "MCC", "RETURN_TRIM", "AEROBRAKE", "DESCENT", "DONE").
// Target52km; drag may still require repeated passes.
// MCC and optional KSC corrections retain the52km floor (52-53km corridor).
// This is a planned orbit constraint, not a thermal guarantee.
SET RETURN_PE TO 52000.
SET RETURN_PE_TOLERANCE TO 1000.
SET RETURN_PE_MIN TO 52000.
SET RETURN_REENTRY_DIR TO "RETROGRADE".
SET RETURN_KSC_TARGET TO 1.
SET RETURN_KSC_TRIM_DV_CAP TO 20.
SET RETURN_ARM_CHUTES TO 1.
// Keep propulsion attached throughout aerobraking; DESCENT only starts
// after the craft is captured and below the aerobrake handoff speed.
SET RETURN_DESCENT_DECOUPLER_TAG TO "descent_decoupler".
SET RETURN_DESCENT_DECOUPLE_ALT TO 50500.
SET RETURN_DESCENT_CHUTES_TAG TO "descent_chutes".
SET RETURN_DESCENT_RELEASE_ALT TO 38000.
