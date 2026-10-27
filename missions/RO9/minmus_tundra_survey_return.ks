// RO9: exact retrograde Tundra objective -> review -> low survey orbit
// -> five overhead temperature observations -> review -> fixed landing -> home.
// All apsides and survey minimum altitudes are metres ASL.
SET MISSION_ID TO "minmus_tundra_survey_return".
SET MISSION_NAME TO "RO9 Minmus Tundra, Temperature Surveys and Return".
SET TARGET_ TO "MINMUS".
SET PAYLOADS TO LIST("SCISAT").
SET PARKING_ALT TO 78000.
SET SEQUENCE TO LIST(
    "PRELAUNCH","LAUNCH","FAIR","ANTS","PARK",
    "XING","BPLANE","COAST_1HALF","REFINE_BPLANE","COAST_2HALF",
    "CAPTURE","SHAPE","SCIENCE_OPS","LAND_PREP","ORBITAL_SURVEY","SCIENCE_OPS_LOW","LAND_DEORBIT","LAND_ASSIST",
    "SURFACE_RETURN_SETUP").
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "BODY_ORBIT".
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.

// Aim the encounter at the requested Pe/inclination; capture directly into
// the requested ellipse. SHAPE finishes LAN/AoP after capture, where those
// extra constraints do not have to share a single arrival asymptote.
SET CAPTURE_PE TO 9300.
SET CAPTURE_INC TO 116.6.
SET CAPTURE_LAN TO -1.
SET CAPTURE_AOP TO 270.
SET CAPTURE_DIR TO "RETROGRADE".
SET TARGET_PE TO 9300.
SET TARGET_AP TO 397272.
SET BPLANE_PE_ONLY TO 0.
SET BPLANE_REQUIRE_PLANE TO 1.
SET BPLANE_PE_TOL TO 1000.
// Arrival is an intermediate orbit: SHAPE still requires0.1deg at the
// requested LAN before science/landing. Avoid chasing a sub-minimum trim
// solely to enforce final-orbit precision before capture.
SET BPLANE_ANG_TOL TO 1.
// A converged micro-correction can be below the shared0.3m/s floor.
// Accept a1.5km no-burn Pe miss; SHAPE still enforces100m after capture.
SET BPLANE_MINIMUM_PE_TOL TO 1500.
SET CAPTURE_MIN_PE TO 7800.
SET CAPTURE_MAX_PE TO 10800.
SET CAPTURE_ACCEPT_BOUND TO 0.
SET BPLANE_DV_CAP TO 100.
SET REFINE_BPLANE_DV_CAP TO 100.
SET BPLANE_TRIM_DV_CAP TO 100.
SET BPLANE_TRIM_TOTAL_DV_CAP TO 200.
SET BPLANE_TRIM_RESERVE_DV TO 1000.
SET BPLANE_CAPTURE_MARGIN TO 1000.
SET CAPTURE_RESERVE_DV TO 1000.
SET BPLANE_MAX_ARRIVAL_SHIFT TO 600.
SET BPLANE_MAX_CAPTURE_DV_INCREASE TO 20.
SET SHAPE_AP TO 397272.
SET SHAPE_PE TO 9300.
SET SHAPE_INC TO 116.6.
SET SHAPE_LAN TO 337.
SET SHAPE_AOP TO 270.
SET SHAPE_ALT_TOL TO 100.
SET SHAPE_ANG_TOL TO 0.1.
SET SHAPE_AOP_TOL TO 0.2.
// These contract apsides need real sub-0.1m/s trims. The generic0.4m/s
// economy floor and0.05m/s executor residual cannot achieve100m here.
SET SHAPE_MIN_BURN_DV TO 0.002.
SET SHAPE_BURN_TOLERANCE TO 0.001.
// Keep an explicit9km floor for the final shaped orbit.
SET SHAPE_MIN_PE TO 9000.
SET SHAPE_DV_CAP TO 300.
SET SHAPE_TOTAL_DV_CAP TO 500.
SET SHAPE_RESERVE_DV TO 900.

// Verify the first orbital contract before releasing LAND_PREP. Preserve
// the116.6deg plane (latitude reach63.4deg) for all five northern surveys.
// Lower Ap once to~19.3km while retaining Pe~9.3km; do not enter the
//3200-6600m range: those are minimum survey altitudes, not an upper band.
//6600m conservatively satisfies every requested threshold. No radius was
// supplied; use a configurable1km overhead acceptance, then require manual
// verification of the actual contract ticks at SCIENCE_OPS_LOW.
SET LAND_PREP_MIN_PE TO 9000.
SET LAND_PREP_ALT_TOL TO 250.
SET LAND_PREP_RESERVE_DV TO 900.
SET SCIENCE_OPS_HOLD TO 1.
// Keep the thermometers empty at the first orbital review. The dedicated
// survey phase deploys them only at the requested sites.
SET SCIENCE_OPS_RUN_ALL TO 0.
SET SCIENCE_SURVEY_POINTS TO LIST(
    LIST(52.648,2.235,6600), LIST(34.308,-12.419,6600),
    LIST(52.176,18.898,6600), LIST(35.436,-18.744,6600),
    LIST(52.128,82.575,6600)).
SET ORBITAL_SURVEY_BODY TO "Minmus".
SET ORBITAL_SURVEY_MIN_PE TO 9000.
SET ORBITAL_SURVEY_MAX_AP TO 30000.
SET ORBITAL_SURVEY_RADIUS TO 1000.
SET ORBITAL_SURVEY_ORBITS TO 48.
SET AUTO_TRANSMIT TO 0.
// Survey-first saves an ascent into a northern survey plane after landing.
// Keep the landing coordinates separate from all five overhead sites.
SET TARGET_LAT TO -29.189.
SET TARGET_LNG TO 17.465.
SET TARGET_LOCK TO 1.
SET TARGET_WAYPOINT TO "".
SET LANDING_USE_WAYPOINTS TO 0.
SET LANDING_AUTO_TARGET TO 0.
SET LANDING_FLEXIBLE_SITE TO 0.
SET LANDING_CONFIRM_TARGET TO 0.
SET LANDING_LIGHT_MODE TO "ANY".
SET LANDING_REQUIRE_KERBIN TO 0.
// Fixed landing target: live terrain/slope/footprint checks remain.
// Do not silently substitute an economy site or a selected survey waypoint.
SET LANDING_SITE_SCAN_ENABLE TO 0.
SET LANDING_REQUIRE_SITE TO 0.
SET LANDING_SKIP_TARGET_SEARCH TO 0.
SET LANDING_ECONOMY_BRAKE TO 1.
SET LANDING_STAGE_BRAKE_CREDIT TO 1.
SET LANDING_POWERED_LEAD TO 1.
SET LANDING_STAGE_DISCARD_HSPEED TO 0.
SET TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS TO 1.
SET TARGET_DEORBIT_NORMAL_DV_CAP TO 10.
SET TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM TO 0.25.
SET DEORBIT_CROSSTRACK_AUTHORITY_KM TO 0.5.
SET TARGET_TOLERANCE TO 1500.
SET GUIDANCE_ALT TO 3000.
// Low parking orbit needs many passes to sample Minmus longitudes. The
// survey is cheap geometry; the native TR solver still has64 total trials.
SET TARGET_DEORBIT_SCAN_ORBITS TO 48.
SET TARGET_DEORBIT_SCAN_SAMPLES TO 512.
SET TARGET_DEORBIT_MIN_LEAD TO 120.
SET TERRAIN_CHECK_RADIUS TO 500.
SET TERRAIN_CHECK_STEP TO 100.
SET MAX_TILT TO 12.
SET RELOAD_AFTER_LAND_ASSIST TO 0.
SET RELOAD_AFTER_LAND TO 0.

// Launch eastward at the minimum feasible inclination from29.189S.
// No expensive post-landing contract orbit: depart directly from low orbit.
SET SURFACE_RETURN_PARKING_ALT TO 10000.
SET SURFACE_RETURN_INCLINATION TO 29.189.
SET SURFACE_RETURN_SEQUENCE TO LIST("PRELAUNCH","LAUNCH","PARK","RETURN_SETUP").
SET SURFACE_RETURN_ORBIT TO LEXICON().
SET RETURN_SEQUENCE TO LIST("ESCAPE","COAST","MCC","AEROBRAKE","DESCENT","DONE").
SET RETURN_PE TO 53000.
SET RETURN_PE_TOLERANCE TO 1000.
SET RETURN_REENTRY_DIR TO "RETROGRADE".
SET RETURN_KSC_TARGET TO 0.
SET RETURN_ARM_CHUTES TO 1.
SET RETURN_DESCENT_FAIRING_TAG TO "none".
SET RETURN_DESCENT_DECOUPLER_TAG TO "return_decoupler".
SET RETURN_DESCENT_DECOUPLE_ALT TO 6000.
SET RETURN_DESCENT_CHUTES_TAG TO "descent_chutes".
SET RETURN_DESCENT_RELEASE_ALT TO 10000.
