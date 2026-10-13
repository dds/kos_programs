// RO8 Mun low-orbit science and return, with no landing or plane change.
// Fresh launch or in-flight switch at BPLANE using cmd/setphase.ks.

SET MISSION_ID TO "mun_orbit_return".
SET MISSION_NAME TO "RO8 Mun Low Orbit Science and Return".
SET TARGET_ TO "MUN".
SET PAYLOADS TO LIST("SCISAT").
SET PARKING_ALT TO 78000.
SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "CAPTURE", "SCIENCE_OPS", "RETURN_SETUP").

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

// Small Pe-only arrival corrections. Retain 400 m/s AFTER capture for
// Mun departure and Kerbin approach corrections, with no landing/ascent.
// This is a planning reserve, not a guarantee for every arrival geometry.
SET BPLANE_DV_CAP TO 20.
SET REFINE_BPLANE_DV_CAP TO 10.
SET BPLANE_TRIM_DV_CAP TO 20.
SET BPLANE_TRIM_TOTAL_DV_CAP TO 30.
SET BPLANE_TRIM_RESERVE_DV TO -1.
SET BPLANE_CAPTURE_MARGIN TO 400.
SET CAPTURE_RESERVE_DV TO 400.
// Pe acquisition changes the SOI chord. Use absolute capture affordability
// instead of rejecting a cheap correction for its changed arrival time.
SET BPLANE_MAX_ARRIVAL_SHIFT TO -1.
SET BPLANE_MAX_CAPTURE_DV_INCREASE TO -1.

// Run available experiments and HOLD in low orbit for inspection/storage.
// Do not automatically transmit recoverable science or depart after 10 s.
// When ready: setphase RETURN_SETUP, then REBOOT (see README).
SET AUTO_TRANSMIT TO 0.
SET SCIENCE_OPS_HOLD TO 1.
SET SCIENCE_SURVEY_POINTS TO LIST().

// Return directly from orbit. No landing or surface-ascent phases.
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
