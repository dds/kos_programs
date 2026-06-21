// ============================================================
// FBIJ mission profile — KA120 KSC <-> Desert Airfield turn
// (0:/missions/FBIJ/ka120_ksc_dessert_turn.ks)
//
// A regular out-and-back: KSC -> Desert Airfield, turn the jet
// around, Desert Airfield -> KSC. Each leg is a normal full-stop
// PREFLIGHT/FLIGHT/POSTFLIGHT cycle; chain them with
// restartflightplan between legs (it keeps this profile selected
// and just rewinds the phase machine).
//
// Operating procedure (FBIJ reads the SELECTED Waypoint Manager
// waypoint, not coordinates baked into this profile):
//   Leg 1 (outbound):
//     1. Select "Desert Airfield" in Waypoint Manager.
//     2. Take off, climb out, press AG8 to fly the waypoint
//        (AG7 = autopilot only, no nav).
//     3. Land full-stop at the desert strip.
//   Turn:
//     4. RUNPATH("0:/cmd/restartflightplan.ks").  (reboots to PREFLIGHT)
//   Leg 2 (return):
//     5. Select "KSC Runway" in Waypoint Manager, fly it back, land.
//
// Both fields have approach data in PLANE_APPROACHES once Desert is
// added to the runway database; until then the approach brief just
// reports "no known runway data" and the rest of the flight is
// unaffected.
// ============================================================

SET MISSION_ID TO "ka120_ksc_dessert_turn".
SET MISSION_NAME TO "FBIJ KA120 KSC-Desert Turn".
SET TARGET_ TO "KERBIN".
SET PAYLOADS TO LIST().
SET SEQUENCE TO LIST("PREFLIGHT", "FLIGHT", "POSTFLIGHT", "DONE").
