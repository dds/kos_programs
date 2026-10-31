// Read-only arrival-frame snapshot, directly archived. No node/control edits.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdBplanecheck {
    IF WARP <> 0 OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR SHIP:THRUST > 0.001
            OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Pause warp and stop thrust before taking an arrival snapshot.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("lib_bplane_math").
    bootLibLoad("diagnostic_log").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
    IF NOT BODYEXISTS(getTarget()) { PRINT "No arrival body selected.". RETURN. }
    LOCAL bdy IS BODY(getTarget()).
    LOCAL report IS diagnosticArchiveOpen("bplanecheck").
    IF NOT report["READY"] { RETURN. }
    diagnosticArchiveLine(report,"BPLANE SNAPSHOT schema=1 craft=" + SHIP:NAME
        + " ut=" + TIME:SECONDS + " phase=" + stateGet("phase","") + " target=" + bdy:NAME
        + " hasNode=" + HASNODE + " interrupted=" + stateGet("burn_abort_reason","none")).
    LOCAL hit IS findArrivalPatch(0,bdy).
    IF hit = 0 {
        diagnosticArchiveLine(report,"No unburned arrival patch; no maneuver changed.").
    } ELSE {
        LOCAL p IS hit["patch"].
        diagnosticArchiveLine(report,"native entryUt=" + hit["entryUt"] + " Pe=" + p:PERIAPSIS
            + " inc=" + p:INCLINATION + " lan=" + p:LAN + " sma=" + p:SEMIMAJORAXIS
            + " ecc=" + p:ECCENTRICITY + " bodyPosition=" + bdy:POSITION
            + " patchPosition=" + p:POSITION + " patchVelocity=" + p:VELOCITY:ORBIT).
        LOCAL measured IS measureArrival(0,bdy).
        diagnosticArchiveLine(report,"measurement valid=" + (measured <> 0) + " frame=patch-current").
        IF measured <> 0 {
            diagnosticArchiveLine(report,"geometry vinf2=" + measured["vinf2"] + " bMag=" + measured["bMag"]
                + " bt=" + measured["bt"] + " br=" + measured["br"]
                + " S=" + measured["S"] + " hHat=" + measured["hHat"] + " eHat=" + measured["eHat"]).
        }
    }
    diagnosticArchiveLine(report,"executor " + stateGet("last_burn_report","none")).
    diagnosticArchiveClose(report,"BPLANE SNAPSHOT").
}

_cmdBplanecheck().
