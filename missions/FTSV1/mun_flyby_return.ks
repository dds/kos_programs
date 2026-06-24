// ============================================================
// FTSV1 mission profile — Mun Flyby & Return (near KSC)
// (0:/missions/FTSV1/mun_flyby_return.ks)
//
// Vehicle: single fixed solar panel (orientForSolar's fixed-panel
// search applies); reaches LKO with ~1286 m/s on a low-TWR pug upper
// stage (0.38 -> 0.56 TWR) — expect long, early-started burns. The pug
// stage flies the flyby and is decoupled during reentry (~49 km), flung
// aside, leaving the capsule + chutes.
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
SET MISSION_NAME TO "FTSV1 Mun Flyby & Return".
SET TARGET_ TO "MUN".
SET PAYLOADS TO LIST("TOURIST").
SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "FREE_RT_BPLANE", "COAST_1HALF", "COAST_2HALF",
    "FLYBY", "MCC", "AEROBRAKE", "DESCENT", "DONE").
// Free return: FREE_RT_BPLANE shapes the encounter so the post-flyby
// Kerbin periapsis lands in the reentry corridor with NO return burn —
// passive abort safety. FLYBY then just coasts through; MCC becomes a
// small KSC-longitude trim (not the load-bearing return burn it was).
SET FREE_RETURN TO TRUE.

// --- Ascent + 85 km parking orbit (the smooth ride / weightless time) ---
SET PARKING_ALT TO 85000.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "BODY_ORBIT".   // align to the Mun's plane
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.

// --- Mun flyby (no capture / no landing) ---
// CAPTURE_PE is the flyby periapsis altitude over the Mun. 50 km is a
// safe, scenic standoff (well clear of Mun terrain) for a tourist pass.
SET CAPTURE_PE TO 50000.
SET FLYBY_POST_PE_HOLD TO 900.           // ~15 min viewing hold at Pe
SET FLYBY_EXIT_SOI TO 1.                 // continue out of the Mun SOI

// --- Return to Kerbin, as close to KSC as the geometry allows ---
// The free return already puts the post-flyby Kerbin periapsis at the
// reentry corridor (REENTRY_PE is FREE_RT_BPLANE's target Pe), so MCC
// only trims the reentry longitude toward KSC, then AEROBRAKE flies the
// entry and DESCENT brings the chutes.
SET REENTRY_PE TO 29000.                 // free-return target Pe — flight-found
                                         // that ~29km is deep enough to capture
                                         // and give Trajectories an impact on a
                                         // fast lunar return (steeper/hotter,
                                         // but a single-pass capture for crew)
// Let the solver fly a closer Mun pass for more bending authority, so
// the return Pe can actually reach the 30km target instead of stalling
// shallow (~40km grazes and Trajectories sees no impact). 15km still
// clears Mun terrain (max ~7.5km) comfortably — and a closer flyby is
// the more thrilling view anyway.
SET FREE_RETURN_MUN_PE_FLOOR TO 15000.
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
