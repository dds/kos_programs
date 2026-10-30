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

// A required polar arrival is a substantial correction, not a 10 m/s trim.
// Keep finite correction limits and reserve 900 m/s AFTER capture as well.
SET BPLANE_DV_CAP TO 100.
SET REFINE_BPLANE_DV_CAP TO 100.
SET BPLANE_TRIM_DV_CAP TO 100.
SET BPLANE_TRIM_TOTAL_DV_CAP TO 150.
SET BPLANE_TRIM_RESERVE_DV TO 900.
SET BPLANE_CAPTURE_MARGIN TO 900.
SET BPLANE_MAX_ARRIVAL_SHIFT TO 600.
SET BPLANE_MAX_CAPTURE_DV_INCREASE TO 5.
// SHAPE includes the required ~44 m/s burn from the 100 km capture
// ellipse to the low science orbit, plus small plane/apsis cleanup.
// A 10/20 m/s trim allowance cannot complete that requested orbit.
SET SHAPE_DV_CAP TO 60.
SET SHAPE_TOTAL_DV_CAP TO 80.
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
// Contract target: local fallback requires a deliberate operator override.
SET LANDING_FLEXIBLE_SITE TO 0.
SET LANDING_CONFIRM_TARGET TO 0.
SET TARGET_TOLERANCE TO 1500.
SET GUIDANCE_ALT TO 3000.
SET TARGET_DEORBIT_SCAN_ORBITS TO 8.
SET TARGET_DEORBIT_SCAN_SAMPLES TO 512.
SET TARGET_DEORBIT_MIN_LEAD TO 120.
// Spend the attached transfer stage before budgeting the weaker lander's
// residual stop; retain conservative fallback for unknown/unsupported stacks.
SET LANDING_STAGE_BRAKE_CREDIT TO 1.
// Descend through braking while preserving this fixed site's stopping gates.
SET LANDING_ECONOMY_BRAKE TO 1.
// Couple the ballistic overshoot to the actual staged powered-braking range.
SET LANDING_POWERED_LEAD TO 1.
// Survey one surface rotation for close passes before spending native
// footprint trials; eight consecutive polar orbits can all miss this site.
SET TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS TO 1.
// A fixed site rotates sideways during descent too. Permit a small measured
// normal correction rather than leaving kilometres of lateral work to BRAKE.
SET TARGET_DEORBIT_NORMAL_DV_CAP TO 10.
SET TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM TO 0.25.
// Operator accepts a wider deorbit footprint after missing the closest pass.
// Keep the fixed touchdown target and its separate 1500 m tolerance.
SET DEORBIT_CROSSTRACK_AUTHORITY_KM TO 2.
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
