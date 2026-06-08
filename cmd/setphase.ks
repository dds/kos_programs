// cmd/setphase.ks - Force phase, optionally switching mission profile too.
// Usage: RUNPATH("0:/cmd/setphase.ks", "PAYLOAD_IMPACT_RELEASE").
//        RUNPATH("0:/cmd/setphase.ks", "PAYLOAD_IMPACT_RELEASE", "mun_sat_delivery_2").
PARAMETER phaseName.
PARAMETER missionId IS "".

IF EXISTS("1:/lib/state.ksm") {
    RUNONCEPATH("1:/lib/state.ksm").
} ELSE IF EXISTS("1:/lib/state.ks") {
    RUNONCEPATH("1:/lib/state.ks").
} ELSE {
    RUNONCEPATH("0:/lib/state.ks").
}

stateInit().

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
