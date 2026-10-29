// ============================================================
// Espoir.ks — Duna science probe flight computer (0:/craft/Espoir.ks)
// Hardware is a new build, not the RO9 staging/decoupler layout.
// ============================================================

applyKnownMissionState().
bootLibLoad("rocket_craft").

GLOBAL BOOT_CLEANUP IS LEXICON("vehicle", "Espoir").

GLOBAL FUNCTION bootVehicleLibs {
    RETURN rocketVehicleLibs().
}

GLOBAL FUNCTION main {
    rocketMain(rocketBuildPhaseSequence@, rocketBuildPhaseMap@).
}
