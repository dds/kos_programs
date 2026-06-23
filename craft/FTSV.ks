// ============================================================
// FTSV.ks — Falcon Tourist Service Vehicle flight computer
// (0:/craft/FTSV.ks)
//
// Crewed tourist Falcon: smooth ascent to a high parking orbit for
// time in weightlessness, then beyond. Shares the Falcon-family rocket
// plumbing in lib/rocket_craft.ks — this file is just config +
// delegation.
// ============================================================

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
    "vehicle", "FTSV"
).

GLOBAL FUNCTION bootVehicleLibs {
    RETURN rocketVehicleLibs().
}

GLOBAL FUNCTION main {
    rocketMain(rocketBuildPhaseSequence@, rocketBuildPhaseMap@).
}
