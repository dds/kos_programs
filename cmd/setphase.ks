// cmd/setphase.ks - Force mission profile and phase together.
// Usage: RUNPATH("0:/cmd/setphase.ks", "mun_sat_delivery_2", "PAYLOAD_IMPACT_RELEASE").
PARAMETER missionId.
PARAMETER phaseName.

IF EXISTS("1:/lib/state.ksm") {
    RUNONCEPATH("1:/lib/state.ksm").
} ELSE IF EXISTS("1:/lib/state.ks") {
    RUNONCEPATH("1:/lib/state.ks").
} ELSE {
    RUNONCEPATH("0:/lib/state.ks").
}

stateInit().

LOCAL mission_ IS missionId:TRIM.
LOCAL phase_ IS phaseName:TRIM:TOUPPER.

stateSet("mission_id", mission_).
stateSet("phase", phase_).
stateSet("reload_required", "false").
stateSet("reload_reason", "").
stateSet("reload_next_phase", "").
stateSet("reload_next_band", "").

PRINT "Mission -> " + mission_.
PRINT "Phase   -> " + phase_.
PRINT "Reboot to resume.".
