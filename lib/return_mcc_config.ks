// Shared setup/runtime policy for acquiring Kerbin's entry corridor.
@LAZYGLOBAL OFF.

// Negative cap opts into the live available-fuel budget. Ordinary returns
// retain the historical150m/s per-correction cap unless explicitly selected.
GLOBAL MCC_RETURN_DV_CAP IS 150.
GLOBAL MCC_RETURN_RESERVE_DV IS 50.
GLOBAL MCC_RETURN_AT_APOAPSIS IS 0.
