// Minmus powered landing defaults.
//
// Mission profiles load this before their site/contract-specific landing
// overrides. Keep terrain scan radii and target tolerances in the mission.

SET BRAKE_ACCEL_FRACTION TO 0.85.
SET BRAKE_MARGIN TO 500.
SET BURN_MARGIN TO 1.1.

SET LANDING_TARGET_REFINE_IMPACT_SCALE TO 500.
SET LANDING_TARGET_REFINE_IMPACT_WEIGHT TO 0.9.
SET LANDING_TARGET_REFINE_THR_MAX TO 0.5.
