// prep for reentry

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL profilePath IS missionProfileBegin(stateGet("vehicle", ""), "kerbin_return").
missionOverrideClear().
LOG "SET MISSION_ID TO " + configLiteral("kerbin_return") + "." TO profilePath.
LOG "SET MISSION_NAME TO " + configLiteral("Return to Kerbin") + "." TO profilePath.
LOG "SET MISSION_TYPE TO " + configLiteral("kerbin_return") + "." TO profilePath.
LOG "SET TARGET_ TO " + configLiteral("KERBIN") + "." TO profilePath.
LOG "SET PAYLOADS TO " + configLiteral(LIST("RETURN")) + "." TO profilePath.
LOG "SET SEQUENCE TO " + configLiteral(LIST("AEROBRAKE", "DESCENT", "DONE")) + "." TO profilePath.
LOG "SET AEROBRAKE_REENTRY_DIR TO " + configLiteral("RETROGRADE") + "." TO profilePath.
LOG "SET AEROBRAKE_ARM_CHUTES TO " + configLiteral(1) + "." TO profilePath.
stateSet("mission_id", "kerbin_return").

stateSet("phase", "AEROBRAKE").
stateSet("lib_band", "AEROBRAKE").
stateSet("reload_required", "false").
stateRemove("lib_band_libs").
stateRemove("lib_band_phase").
