// Save a boolean policy without changing the phase or maneuver node.
// RUNPATH("0:/cmd/aeroassist.ks",1). // enable; 0 disables
@LAZYGLOBAL OFF.
PARAMETER enabled IS 1.

LOCAL FUNCTION _cmdAeroassist {
    IF enabled <> 0 AND enabled <> 1 {
        PRINT "Use 1 to enable aerobrake assistance, or 0 to disable.".
        RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    missionOverrideUpdate(LEXICON("AEROBRAKE_AP_BURN",enabled)).
    PRINT "Aerobrake assistance saved: enabled=" + enabled + ".".
    PRINT "Applies at the next AEROBRAKE boot. This command does not take over active flight.".
}

_cmdAeroassist().
