// ============================================================
// FTSV1.ks — Falcon Tourist Service Vehicle, hull 1
// (0:/craft/FTSV1.ks)
//
// First crewed FTSV-class tourist Falcon. Single fixed solar panel;
// reaches LKO with ~1286 m/s spare on a low-TWR "pug" upper stage
// (0.38 -> 0.56 TWR) that flies the Mun flyby and is shed during
// reentry. Shares the Falcon-family rocket plumbing in
// lib/rocket_craft.ks — this file is just config + delegation.
// ============================================================

SET DESCENT_DROGUE_CUT_ALT TO -1.
SET DESCENT_RELEASE_ALT TO 10000.
SET LIBS_EXTRA TO LIST("solar").
SET PHASES_HAS_SOLAR TO TRUE.
SET AEROBRAKE_BRAKE_PE_FLOOR TO 51000.

GLOBAL BOOT_ARCHIVE_ONLY IS LIST(
    "xfer_plan",
    "maneuver_transfer",
    "maneuver_targeting",
    // Run solar from the archive only when linked — never synced to the
    // probe's tight volume (6.5KB). Offline coast-charging is something
    // we can live without when out of link; the maneuver/coast hooks gate
    // on PHASES_HAS_SOLAR, which solar.ks self-sets only when it loads.
).

applyKnownMissionState().

// Pull the shared rocket-craft plumbing (rocketBuildPhaseSequence,
// rocketBuildPhaseMap, rocketVehicleLibs). Loaded here, before boot
// calls bootVehicleLibs(); only rocket craft pay for it. It syncs on
// the first connected boot and is cached for offline reboots after.
bootLibLoad("rocket_craft").

GLOBAL BOOT_CLEANUP IS LEXICON(
    "vehicle", "FTSV1"
).

GLOBAL FUNCTION bootVehicleLibs {
    RETURN rocketVehicleLibs().
}

GLOBAL FUNCTION main {
    rocketMain(rocketBuildPhaseSequence@, rocketBuildPhaseMap@).
}
