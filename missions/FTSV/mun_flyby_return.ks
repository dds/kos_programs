// ============================================================
// FTSV mission profile — Mun Flyby & Return (near KSC)
// (0:/missions/FTSV/mun_flyby_return.ks)
//
// The inaugural FTSV-class tourist flight. Goals, in order:
//   SAFETY    — high (85 km) parking orbit for a gentle ascent and a
//               settled checkout before trans-Munar injection; a Mun
//               flyby (no capture, no landing) so a single failure
//               can't strand the crew; conservative reentry depth and
//               armed chutes.
//   ENJOYMENT — long weightless coasts (parking orbit + the multi-hour
//               trans-Munar leg), a close Mun flyby with a viewing
//               hold at periapsis, then home.
//   PRECISION — return targeted as close to KSC as the reentry timing
//               allows.
//
// Weightlessness / "gravity stage": the 85 km park plus the trans-Munar
// coast IS the zero-g experience for this vehicle. A future FTSV with a
// spin/gravity stage would add it here; for now there is none — the
// thrill is the flyby, and the trajectory budget assumes no such burn.
// ============================================================

SET MISSION_ID TO "mun_flyby_return".
SET MISSION_NAME TO "FTSV Mun Flyby & Return".
SET TARGET_ TO "MUN".
SET PAYLOADS TO LIST("TOURIST").
SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "FLYBY", "MCC", "AEROBRAKE", "DESCENT", "DONE").

// --- Ascent + 85 km parking orbit (the smooth ride / weightless time) ---
SET PARKING_ALT TO 85000.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "BODY_ORBIT".   // align to the Mun's plane
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.
SET COAST_AUTO_WARP TO 1.                // auto-warp the long quiet coasts
SET KEEP_WARP TO 1.

// --- Mun flyby (no capture / no landing) ---
// CAPTURE_PE is the flyby periapsis altitude over the Mun. 50 km is a
// safe, scenic standoff (well clear of Mun terrain) for a tourist pass.
SET CAPTURE_PE TO 50000.
SET FLYBY_POST_PE_HOLD TO 900.           // ~15 min viewing hold at Pe
SET FLYBY_EXIT_SOI TO 1.                 // continue out of the Mun SOI

// --- Return to Kerbin, as close to KSC as the geometry allows ---
// After the flyby exits the Mun SOI the craft is back in Kerbin's SOI;
// MCC lowers the Kerbin periapsis to REENTRY_PE and times the reentry
// for KSC, then AEROBRAKE flies the entry and DESCENT brings the chutes.
SET REENTRY_PE TO 30000.                 // shallow, gentle entry for crew
SET RETURN_KSC_TARGET TO 1.
SET ESCAPE_KSC_TARGET TO 1.
SET TARGET_LAT TO -0.0972.               // KSC
SET TARGET_LNG TO -74.5577.
SET TARGET_LOCK TO 1.
SET AEROBRAKE_TARGETING TO 1.
SET AEROBRAKE_REENTRY_DIR TO "RETROGRADE".
SET AEROBRAKE_ARM_CHUTES TO 1.
SET RETURN_ARM_CHUTES TO 1.

// Chute / decoupler tags are airframe-specific — set DESCENT_CHUTES_TAG
// (and any DESCENT_* drop tags) here once the FTSV's parts are tagged
// in the VAB, or leave to craft/FTSV.ks hardware defaults.
