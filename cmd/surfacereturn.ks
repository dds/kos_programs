// ============================================================
// cmd/surfacereturn.ks  -  Configure landed Mun/Minmus return
// (0:/cmd/surfacereturn.ks)
//
// Run this after a moon landing when you are ready to leave the
// surface. It switches the vessel into the surface-return sequence
// (PRELAUNCH, LAUNCH, PARK, RETURN_SETUP), then reboots into
// PRELAUNCH. Once parked in orbit, RETURN_SETUP configures the
// Kerbin return leg.
//
// Usage:
//   RUNPATH("0:/cmd/surfacereturn.ks").
//   RUNPATH("0:/cmd/surfacereturn.ks", LEX("parking_km", 25)).
//   RUNPATH("0:/cmd/surfacereturn.ks", LEX(
//       "parking_km", 25,
//       "inclination", 6,
//       "pe", 43000,
//       "ksc_target", TRUE,
//       "arm_chutes", 1
//   )).
//
// Options (all optional, with return_setup defaults):
//   parking_km          - moon parking orbit altitude in km
//   parking_alt         - moon parking orbit altitude in meters
//   inclination         - moon launch inclination in degrees
//   launch_inclination  - alias for inclination
//   azimuth             - moon launch azimuth in degrees
//   launch_azimuth      - alias for azimuth
//   pe / reentry_pe     - Kerbin return periapsis in meters
//   reentry_dir         - "retrograde" or "prograde"
//   ksc_target          - true/1 to enable KSC targeting
//   arm_chutes          - 1 to arm parachutes in aerobrake phase
//   descent_fairing     - descent fairing tag
//   descent_decoupler   - descent decoupler tag
//   descent_chutes      - descent parachute tag
// ============================================================

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("return_setup").

IF opts:HASKEY("parking_km") {
    SET SURFACE_RETURN_PARKING_ALT TO opts["parking_km"] * 1000.
}
IF opts:HASKEY("parking_alt") {
    SET SURFACE_RETURN_PARKING_ALT TO opts["parking_alt"].
}
IF opts:HASKEY("inclination") {
    SET SURFACE_RETURN_INCLINATION TO opts["inclination"].
}
IF opts:HASKEY("launch_inclination") {
    SET SURFACE_RETURN_INCLINATION TO opts["launch_inclination"].
}
IF opts:HASKEY("azimuth") {
    SET SURFACE_RETURN_AZIMUTH TO opts["azimuth"].
}
IF opts:HASKEY("launch_azimuth") {
    SET SURFACE_RETURN_AZIMUTH TO opts["launch_azimuth"].
}

IF opts:HASKEY("pe") {
    SET RETURN_PE TO opts["pe"].
}
IF opts:HASKEY("reentry_pe") {
    SET RETURN_PE TO opts["reentry_pe"].
}
IF opts:HASKEY("reentry_dir") {
    SET RETURN_REENTRY_DIR TO opts["reentry_dir"]:TOUPPER.
}
IF opts:HASKEY("ksc_target") {
    SET RETURN_KSC_TARGET TO opts["ksc_target"].
}
IF opts:HASKEY("arm_chutes") {
    SET RETURN_ARM_CHUTES TO opts["arm_chutes"].
}
IF opts:HASKEY("descent_fairing") {
    SET RETURN_DESCENT_FAIRING_TAG TO opts["descent_fairing"].
}
IF opts:HASKEY("descent_decoupler") {
    SET RETURN_DESCENT_DECOUPLER_TAG TO opts["descent_decoupler"].
}
IF opts:HASKEY("descent_chutes") {
    SET RETURN_DESCENT_CHUTES_TAG TO opts["descent_chutes"].
}

phaseSurfaceReturnSetup().
