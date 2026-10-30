// Opt-in midpoint diagnostics; no assist candidate is installed or burned.
// RUNPATH("0:/cmd/assistmcc.ks",1). REBOOT. Use0 to disable.
@LAZYGLOBAL OFF.
PARAMETER enabled IS 1.

LOCAL FUNCTION _cmdAssistmcc {
    IF enabled <> 0 AND enabled <> 1 { PRINT "Use1 to enable midpoint previews or0 to disable.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF stateGet("mission_id","") = "" { PRINT "No selected mission. Nothing changed.". RETURN. }
    missionOverrideUpdate(LEXICON("ASSIST_MIDCOURSE_PREVIEW",enabled)).
    PRINT "Midcourse assist preview saved: enabled=" + enabled + ". REBOOT. to apply.".
    PRINT "One diagnostic search per mission leg; normal correction continues. Assist execution stays disabled.".
}

_cmdAssistmcc().
