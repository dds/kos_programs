// prep for reentry

RUNPATH("1:/lib/boot_lib").
bootPreamble().

stateSet("target", "KERBIN").
stateSet("mission_type", "kerbin_return").
stateSet("mission_id", "kerbin_return").
stateSet("mission_name", "Return to Kerbin").
stateSet("payloads", "RETURN").

stateSet("mission_cfg_SEQUENCE", "AEROBRAKE,DESCENT,DONE").
stateSet("mission_cfg_AEROBRAKE_REENTRY_DIR", "RETROGRADE").
stateSet("mission_cfg_AEROBRAKE_ARM_CHUTES", 1).

stateSet("phase", "AEROBRAKE").
stateSet("lib_band", "AEROBRAKE").
stateSet("reload_required", "false").
stateRemove("lib_band_libs").
stateRemove("lib_band_phase").

