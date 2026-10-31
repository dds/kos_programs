// Local orbit excursion; no arguments selects70km polar, stopping for review.
// RUNPATH("0:/cmd/orbit.ks",LEXICON("after","scan")). then REBOOT.
@LAZYGLOBAL OFF.
PARAMETER opts IS LEXICON().

LOCAL FUNCTION _cmdOrbit {
    IF NOT opts:ISTYPE("Lexicon") { PRINT "Use an orbit options lexicon, or no arguments for70km polar.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("excursion").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
    excursionSelect(opts,FALSE).
}

_cmdOrbit().
