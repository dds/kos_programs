// ============================================================
// RO9.ks
// ============================================================

SET DESCENT_DROGUE_CUT_ALT TO -1.
SET DESCENT_RELEASE_ALT TO 10000.
SET LIBS_EXTRA TO LIST("solar").
SET AEROBRAKE_BRAKE_PE_FLOOR TO 51000.

GLOBAL BOOT_ARCHIVE_ONLY IS LIST(
    "xfer_plan",
    "maneuver_transfer",
    "maneuver_targeting"
).

applyKnownMissionState().

// Pull the shared rocket-craft plumbing (rocketBuildPhaseSequence,
// rocketBuildPhaseMap, rocketVehicleLibs). Loaded here, before boot
// calls bootVehicleLibs(); only rocket craft pay for it. It syncs on
// the first connected boot and is cached for offline reboots after.
bootLibLoad("rocket_craft").

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "RO9"
).

GLOBAL FUNCTION bootVehicleLibs {
    RETURN rocketVehicleLibs().
}

GLOBAL FUNCTION main {
    rocketMain(rocketBuildPhaseSequence@, rocketBuildPhaseMap@).
}
