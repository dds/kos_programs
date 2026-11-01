// One-site route using the same guarded configuration as programmed hops.
// RUNPATH("0:/cmd/hop.ks"). // selected waypoint; first hop arms, then REBOOT.
// RUNPATH("0:/cmd/hop.ks",lat,lng[,tolerance,pitch,maxBurn,maxApKm,verticalTwr]).
@LAZYGLOBAL OFF.
PARAMETER targetLat IS 999.
PARAMETER targetLng IS 999.
PARAMETER toleranceM IS 750.
PARAMETER pitchDeg IS 45.
PARAMETER maxBurnSeconds IS 90.
PARAMETER maxApKm IS 5.
PARAMETER hopTwr IS 2.5.

LOCAL FUNCTION _cmdHop {
    IF targetLat = 999 AND targetLng = 999 {
        IF ABORT OR HASNODE OR SHIP:STATUS <> "LANDED" OR SHIP:BODY:ATM:EXISTS
                OR SHIP:VELOCITY:SURFACE:MAG > 0.5 OR SHIP:THRUST > 0.001
                OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
            PRINT "Select a waypoint from a settled airless landing with idle controls, no node and Abort clear.".
            RETURN.
        }
        RUNPATH("1:/lib/boot_lib").
        bootPreamble().
        bootLibLoad("hop").
        LOCAL vehicle IS stateGet("vehicle","").
        LOCAL mid IS stateGet("mission_id","").
        IF vehicle = "" OR mid = "" { PRINT "No selected mission; nothing changed.". RETURN. }
        bootLibLoad("craft/"+vehicle).
        IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
        // Existing routes keep their original restore settings and reserve.
        // The shared review action validates the new leg and reboots to fly it.
        IF stateGet("hop_route_active",FALSE) { hopWaypoint(). RETURN. }
        LOCAL wp IS selectedWaypoint().
        IF wp = 0 { PRINT "Select a navigation waypoint on this body first.". RETURN. }
        SET targetLat TO wp:LATITUDE.
        SET targetLng TO wp:LONGITUDE.
    }
    RUNPATH("0:/cmd/hoproute.ks",LIST(LIST(targetLat,targetLng)),700,
        toleranceM,pitchDeg,maxBurnSeconds,maxApKm,hopTwr).
}

_cmdHop().
