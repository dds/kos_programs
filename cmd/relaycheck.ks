// Read-only inventory/geometry snapshot. Never deploys, burns or clears nodes.
@LAZYGLOBAL OFF.
LOCAL FUNCTION _cmdRelaycheck {
    IF WARP <> 0 OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR SHIP:THRUST > 0.001
            OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Use relaycheck at1x with the active craft's engines stopped.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("relay_hardware").
    bootLibLoad("diagnostic_log").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
    IF NOT BODYEXISTS(getTarget()) { PRINT "Select a relay mission first.". RETURN. }
    LOCAL bdy IS BODY(getTarget()).
    LOCAL report IS diagnosticArchiveOpen("relaycheck").
    IF NOT report["READY"] { RETURN. }
    LOCAL geometry IS relayGeometry(RELAY_COUNT,RELAY_ALT,bdy).
    diagnosticArchiveLine(report,"RELAY CHECK craft="+SHIP:NAME+" body="+bdy:NAME
        +" count="+RELAY_COUNT+" altitude="+RELAY_ALT+" geometry="+geometry).
    LOCAL i IS 1.
    UNTIL i > RELAY_COUNT {
        LOCAL info IS relayPayloadInfo(i).
        diagnosticArchiveLine(report,"payload="+i+" ok="+info["OK"]+" reason="+info["REASON"]
            +" command="+info["COMMAND"]+" relays="+info["RELAYS"]+" panels="+info["PANELS"]
            +" battery="+info["EC"]+"/"+info["CAPACITY"]+" ejectionForce="+info["FORCE"]+" partUids="+info["UIDS"]).
        SET i TO i+1.
    }
    diagnosticArchiveLine(report,"stageDv="+STAGE:DELTAV:VACUUM+" totalDv="+SHIP:DELTAV:VACUUM
        +" hasNode="+HASNODE+" abort="+ABORT+" campaign="+stateGet("relay_campaign_id","none")).
    diagnosticArchiveClose(report,"RELAY CHECK").
}
_cmdRelaycheck().
