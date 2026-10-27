// ============================================================
// aerobrake_config.ks - Optional periapsis assist / return-profile policy.
// (0:/lib/aerobrake_config.ks)
// ============================================================
@LAZYGLOBAL OFF.
GLOBAL AEROBRAKE_AP_BURN IS 0.
// Retain at least 10 m/s for an apoapsis Pe repair; larger reserves win.
// An audited fueled successor can hold it while a disposable stage empties.
GLOBAL AEROBRAKE_AP_RESERVE_DV IS 10.
GLOBAL AEROBRAKE_AP_PLAN_LEAD IS 180.
// kOS dynamic pressure is in atmospheres; 0.1 atm is about 10.1 kPa.
GLOBAL AEROBRAKE_AP_MAX_Q IS 0.1.
GLOBAL AEROBRAKE_AP_MAX_OFF_RETRO IS 10.
// Only these named boundaries may be crossed, between atmospheric passes.
// Empty preserves active-engine-only behavior on other vehicles.
GLOBAL AEROBRAKE_AP_STAGE_TAGS IS LIST().
