// RO6 mun polar orbit and return mission

SET MISSION_ID TO "mun_polar_orbit_return".
SET MISSION_NAME TO "RO6 Mun Polar Orbit & Return".
SET TARGET_ TO "MUN".
SET PAYLOADS TO LIST("SCISAT").
SET PARKING_ALT TO 78000.
SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
     "CAPTURE", "SCIENCE_OPS", "DONE").

// RETURN_TRIM: high-leverage KSC-longitude correction on the Kerbin
// approach (a few m/s far out moves the impact thousands of km). It
// never holds the return — if it can't safely improve the miss it hands
// off to AEROBRAKE, which does the short-range impact nudge.
SET RETURN_TRIM TO TRUE.

// --- Ascent + 85 km parking orbit (the smooth ride / weightless time) ---
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "BODY_ORBIT".   // align to the Mun's plane
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.

// --- Mun flyby (no capture / no landing) ---
// CAPTURE_PE is the flyby periapsis altitude over the Mun. 50 km is a
// safe, scenic standoff (well clear of Mun terrain) for a tourist pass.
SET CAPTURE_PE TO 50000.
SET CAPTURE_INC TO 90.
SET CAPTURE_DIR TO "POLAR".
SET TARGET_PE TO 50000.


// Let the solver fly a closer Mun pass for more bending authority, so
// the return Pe can actually reach the 30km target instead of stalling
// shallow (~40km grazes and Trajectories sees no impact). 15km still
// clears Mun terrain (max ~7.5km) comfortably — and a closer flyby is
// the more thrilling view anyway.
SET RETURN_KSC_TARGET TO 1.
SET ESCAPE_KSC_TARGET TO 1.
SET TARGET_LAT TO -0.0972.               // KSC
SET TARGET_LNG TO -74.5577.
SET TARGET_LOCK TO 1.
SET AEROBRAKE_TARGETING TO 1.
SET AEROBRAKE_REENTRY_DIR TO "RETROGRADE".   // hold retrograde through entry
SET AEROBRAKE_ARM_CHUTES TO 1.
SET RETURN_ARM_CHUTES TO 1.
// Auto-deepen the reentry Pe to REENTRY_PE (25km) with the pug stage
// before it's jettisoned — guarantees capture + a Trajectories impact
// so the KSC impact-site targeting has something to steer.
SET AEROBRAKE_PE_TARGETING TO 1.

// --- Stage separation + chutes ---
// Shed the pug stage at 50.5km, flinging it clear. The pug stays
// attached through the AEROBRAKE deepen + KSC-targeting burns (it has
// the engine), then drops here. 50.5km, not lower: at 49km the pug's
// solar panel cooked off before separation. Reentry stability is the
// onion capsule's job (blunt heat shield forward). Tag must match the
// FTSV1 decoupler in the VAB.
SET DESCENT_DECOUPLER_TAG TO "descent_decoupler".
SET DESCENT_DECOUPLE_ALT TO 50500.
SET DESCENT_CHUTES_TAG TO "descent_chutes".
SET DESCENT_RELEASE_ALT TO 38000.            // arm/stage chutes (Kerbin)
// Shed the heat shield low (~500m AGL) for a lighter final descent.
SET DESCENT_HEATSHIELD_TAG TO "descent_heatshield".
SET DESCENT_HEAT_SHIELD_DROP_ALT TO 500.
