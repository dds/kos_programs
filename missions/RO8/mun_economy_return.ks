// RO8 Mun: flexible-site landing and return with no requested plane change.
// Select for a fresh launch; this is not the contract-site/polar survey profile.

SET MISSION_ID TO "mun_economy_return".
SET MISSION_NAME TO "RO8 Mun Economy Landing and Return".
SET TARGET_ TO "MUN".
SET PAYLOADS TO LIST("SCISAT").
SET PARKING_ALT TO 78000.
SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "CAPTURE", "SCIENCE_OPS", "LAND_DEORBIT", "LAND_ASSIST",
    "SURFACE_RETURN_SETUP").

// Wait for the moon's orbital plane at launch, avoiding a later plane burn.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "BODY_ORBIT".
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.

// Accept the natural arrival plane, including its direction. Equatorial
// is not a requirement: forcing 0 degrees could spend the fuel we saved.
SET CAPTURE_PE TO 15000.
SET CAPTURE_INC TO -1.
SET CAPTURE_LAN TO -1.
SET CAPTURE_AOP TO -1.
SET CAPTURE_DIR TO "".
SET BPLANE_PE_ONLY TO 1.
SET BPLANE_REQUIRE_PLANE TO 0.
SET BPLANE_PE_TOL TO 2000.
SET TARGET_PE TO 15000.
// Capture directly into a low, near-circular orbit in one periapsis burn.
// No SHAPE phase: no 100 km ellipse followed by separate circularization.
SET TARGET_AP TO 15000.
SET SHAPE_INC TO -1.
SET SHAPE_LAN TO -1.
SET SHAPE_AOP TO -1.
SET CAPTURE_MIN_PE TO 13000.
SET CAPTURE_MAX_PE TO 17000.
SET CAPTURE_ACCEPT_BOUND TO 0.

// Small Pe-only arrival corrections. Keep a post-capture allowance for
// descent, surface ascent and departure; these floors are not a complete
// craft-specific round-trip budget and do not guarantee a successful return.
SET BPLANE_DV_CAP TO 20.
SET REFINE_BPLANE_DV_CAP TO 10.
SET BPLANE_TRIM_DV_CAP TO 20.
SET BPLANE_TRIM_TOTAL_DV_CAP TO 30.
SET BPLANE_TRIM_RESERVE_DV TO -1.
SET BPLANE_CAPTURE_MARGIN TO 1500.
SET CAPTURE_RESERVE_DV TO 1500.
// Pe acquisition changes the SOI chord. Use absolute capture affordability
// instead of rejecting a cheap correction for its changed arrival time.
SET BPLANE_MAX_ARRIVAL_SHIFT TO -1.
SET BPLANE_MAX_CAPTURE_DV_INCREASE TO -1.

// Run generic orbital experiments, then choose a nearby ground-track site.
// Ignore selected contract waypoints: no latitude/longitude detour.
SET SCIENCE_OPS_HOLD TO 0.
SET SCIENCE_SURVEY_POINTS TO LIST().
SET TARGET_LAT TO 0.
SET TARGET_LNG TO 0.
SET TARGET_LOCK TO 0.
SET TARGET_WAYPOINT TO "".
SET LANDING_USE_WAYPOINTS TO 0.
SET LANDING_AUTO_TARGET TO 1.
SET LANDING_AUTO_TARGET_MINUTES TO 5.
SET LANDING_CONFIRM_TARGET TO 0.
SET LANDING_SKIP_TARGET_SEARCH TO 0.
SET TARGET_TOLERANCE TO 1500.
SET GUIDANCE_ALT TO 3000.
SET TARGET_DEORBIT_SCAN_ORBITS TO 4.
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

// Aim east on ascent. The vacuum ascent code naturally limits achievable
// inclination to the landing latitude; it does not buy a plane change to 0.
SET SURFACE_RETURN_PARKING_ALT TO 10000.
SET SURFACE_RETURN_INCLINATION TO 0.
SET RETURN_SEQUENCE TO LIST("ESCAPE", "COAST", "MCC", "AEROBRAKE", "DESCENT", "DONE").
SET RETURN_PE TO 53000.
SET RETURN_PE_TOLERANCE TO 1000.
SET RETURN_REENTRY_DIR TO "RETROGRADE".
// Recover anywhere on Kerbin: no optional KSC-longitude/impact-site burns.
SET RETURN_KSC_TARGET TO 0.
SET RETURN_ARM_CHUTES TO 1.
SET RETURN_DESCENT_FAIRING_TAG TO "none".
SET RETURN_DESCENT_DECOUPLER_TAG TO "descent_decoupler".
SET RETURN_DESCENT_DECOUPLE_ALT TO 6000.
SET RETURN_DESCENT_CHUTES_TAG TO "descent_chutes".
SET RETURN_DESCENT_RELEASE_ALT TO 10000.
