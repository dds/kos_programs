// ============================================================
// aerobrake_config.ks - Optional periapsis assist / return-profile policy.
// (0:/lib/aerobrake_config.ks)
// ============================================================
@LAZYGLOBAL OFF.
GLOBAL AEROBRAKE_AP_BURN IS 0.
GLOBAL AEROBRAKE_AP_RESERVE_DV IS 0.
GLOBAL AEROBRAKE_AP_PLAN_LEAD IS 180.
// kOS dynamic pressure is in atmospheres; 0.1 atm is about 10.1 kPa.
GLOBAL AEROBRAKE_AP_MAX_Q IS 0.1.
GLOBAL AEROBRAKE_AP_MAX_OFF_RETRO IS 10.
