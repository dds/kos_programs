// Optional safe stock-chute deployment during SCIENCE_ENTRY, no staging.
// RUNPATH("0:/cmd/entrychutes.ks",1). REBOOT. Use0 to disable.
@LAZYGLOBAL OFF.
PARAMETER enabled IS 1.

LOCAL FUNCTION _cmdEntrychutes {
    IF enabled <> 0 AND enabled <> 1 { PRINT "Use1 to enable safe entry chutes or0 to disable.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF stateGet("mission_id","") = "" { PRINT "No selected mission. Nothing changed.". RETURN. }
    missionOverrideUpdate(LEXICON("SCIENCE_ENTRY_CHUTES",enabled)).
    PRINT "Safe stock entry chutes saved: enabled=" + enabled + ". REBOOT. to apply.".
    PRINT "Entry trajectory and science retained; no engine burn, staging or landing guarantee.".
}

_cmdEntrychutes().
