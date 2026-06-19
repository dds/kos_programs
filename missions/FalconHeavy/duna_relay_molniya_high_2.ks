// KerboScript mission profile.
SET MISSION_ID TO "duna_relay_molniya_high_2".
SET MISSION_NAME TO "FalconHeavy Duna High Molniya Relay 2".
SET TARGET_ TO "DUNA".
SET PAYLOADS TO LIST("RELAY").
SET SEQUENCE TO LIST("PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK", "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF", "CAPTURE", "SHAPE", "RELAY_OPS", "DONE").

// Kerbin launch and Duna transfer.
SET PARKING_ALT TO 85000.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "INTERPLANETARY".
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.

// High Duna Molniya-style relay orbit. Duna's sidereal day is about
// 65,518s; with an 85km safe periapsis, a 1-Duna-day orbit has an
// apoapsis near 5,675km and provides long southern-hemisphere dwell.
SET CAPTURE_PE TO 85000.
SET CAPTURE_INC TO 63.4.
SET CAPTURE_AOP TO 90.
SET CAPTURE_DIR TO "PROGRADE".
SET TARGET_PE TO 85000.
SET TARGET_AP TO 5675000.
SET SHAPE_PE TO 85000.
SET SHAPE_AP TO 5675000.
SET SHAPE_INC TO 63.4.
SET SHAPE_AOP TO 90.
SET SHAPE_ALT_TOL TO 15000.
SET SHAPE_ANG_TOL TO 0.5.
SET SHAPE_AOP_TOL TO 1.

// Mirror the same orbit for the Molniya helper/calculator if this
// profile is resumed manually into MOLNIYA_INSERT.
SET MOLNIYA_PERIOD TO 65518.
SET MOLNIYA_AOP TO 90.
SET MOLNIYA_ECC TO 0.

SET COAST_AUTO_WARP TO 0.
SET KEEP_WARP TO 0.
