// Local orbital excursion to a waypoint (default) or numeric lat/lng.
// RUNPATH("0:/cmd/visit.ks",LEXICON("lat",12.3,"lng",45.6)). then REBOOT.
@LAZYGLOBAL OFF.
PARAMETER opts IS LEXICON().

LOCAL FUNCTION _cmdVisit {
    IF NOT opts:ISTYPE("Lexicon") { PRINT "Use a lat/lng lexicon, or select a waypoint and pass no arguments.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("excursion").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
    excursionSelect(opts,TRUE).
}

_cmdVisit().
