// cmd/setphase.ks - Force phase, optionally switching mission profile too.
// Usage: RUNPATH("0:/cmd/setphase.ks", "DROP_FOR_IMPACT_AND_RAISE_PE").
//        RUNPATH("0:/cmd/setphase.ks", "DROP_FOR_IMPACT_AND_RAISE_PE", "mun_sat_delivery_2").
PARAMETER phaseName.
PARAMETER missionId IS "".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL phase_ IS phaseName:TRIM:TOUPPER.
LOCAL mission_ IS missionId:TRIM.
IF mission_ = "" {
    SET mission_ TO stateGet("mission_id", "").
}

IF mission_ <> "" {
    stateSet("mission_id", mission_).
}
stateSet("phase", phase_).
stateSet("reload_required", "false").
stateSet("reload_reason", "").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").

IF mission_ = "" {
    PRINT "Mission -> unchanged (none in state)".
} ELSE {
    PRINT "Mission -> " + mission_.
}
PRINT "Phase   -> " + phase_.
PRINT "Reboot to resume.".
