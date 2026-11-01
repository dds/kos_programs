// Manual same-body rendezvous, without replacing the survey mission.
@LAZYGLOBAL OFF.
PARAMETER action IS "preview", targetName IS "", cap IS 500, reserve IS 100.

LOCAL FUNCTION _cmdRendezvous {
    IF NOT LIST("preview","plan","match","reset"):CONTAINS(action)
            OR NOT cap:ISTYPE("Scalar") OR NOT reserve:ISTYPE("Scalar")
            OR NOT targetName:ISTYPE("String") {
        PRINT "Use preview/plan/match/reset, target vessel name (or selected target), dV cap, reserve.". RETURN.
    }
    IF NOT HOMECONNECTION:ISCONNECTED { PRINT "Rendezvous tools require an archive link.". RETURN. }
    RUNPATH("1:/lib/boot_lib"). bootPreamble().
    bootLibLoadList(LIST("maneuver","hohmann_transfer","lambert")).
    // Refresh function providers; no mission/profile/phase changes.
    RUNPATH("0:/lib/rendezvous_geometry.ks").
    RUNPATH("0:/lib/rdv_plan.ks").
    RUNPATH("0:/lib/maneuver_rendezvous.ks").
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    LOCAL other IS rendezvousTarget(targetName).
    IF other = 0 { PRINT "Select one uniquely named vessel, not this craft.". RETURN. }
    // Restore the selected profile's retained-fuel policy without replacing
    // mission intent or loading a different band. A supplied reserve may
    // tighten that policy, never silently spend an excursion's return fuel.
    LOCAL vehicle IS stateGet("vehicle",""). LOCAL mid IS stateGet("mission_id","").
    LOCAL script IS "missions/"+vehicle+"/"+bootMissionProfileId(vehicle,mid).
    LOCAL path_ IS bootArchivePath(script).
    IF path_ = "" OR NOT EXISTS(path_) { SET path_ TO bootLocalScriptPath(script). }
    IF vehicle = "" OR mid = "" OR path_ = "" OR NOT EXISTS(path_) {
        PRINT "Selected mission profile required to preserve its reserve.". RETURN.
    }
    RUNPATH(path_). bootMissionProfileIntent(vehicle,mid). applyMissionOverrides().
    IF DEFINED EXCURSION_RESERVE_DV { SET reserve TO MAX(reserve,EXCURSION_RESERVE_DV). }
    SET reserve TO MAX(reserve,MAX(RDV_RESERVE_DV,MATCH_RESERVE_DV)).
    IF action = "reset" {
        // An explicitly reviewed failed approach can be acknowledged only
        // from a stopped, separated, velocity-matched orbit. Never clears
        // the executor's burn_* evidence or a retained maneuver.
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR ABORT OR WARP <> 0 OR HASNODE
                OR NOT KUNIVERSE:TIMEWARP:ISSETTLED
                OR NOT rendezvousSafeOrbit(SHIP:ORBIT) OR NOT rendezvousSafeOrbit(other:ORBIT)
                OR (other:POSITION-SHIP:POSITION):MAG < 150
                OR (SHIP:VELOCITY:ORBIT-other:VELOCITY:ORBIT):MAG > 0.2
                OR NOT (SHIP:THRUST >= 0 AND SHIP:THRUST <= 0.001)
                OR NOT (SHIP:CONTROL:MAINTHROTTLE >= 0 AND SHIP:CONTROL:MAINTHROTTLE <= 0)
                OR NOT (SHIP:CONTROL:PILOTMAINTHROTTLE >= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0)
                OR stateGet("burn_pending","false") = "true"
                OR stateGet("burn_started","false") = "true" { PRINT "Approach reset requires a safe, separated and velocity-matched idle orbit.". RETURN. }
        stateRemove("rendezvous_active"). PRINT "Approach interruption acknowledged; mission and maneuver reports retained.". RETURN.
    }
    IF NOT LIST("DONE","SCIENCE_OPS","SCANSAT_OPS","RDV","MATCH"):CONTAINS(stateGet("phase",""))
            OR NOT rendezvousContext(SHIP,other) OR NOT (cap >= 1 AND cap < 1e6 AND reserve >= 0 AND reserve < 1e6) {
        PRINT "Use an idle orbital review prompt at1x: no node/interrupted burn, Abort clear and throttle zero.". RETURN.
    }
    LOCAL report IS diagnosticArchiveOpen("rendezvous").
    IF NOT report["READY"] { RETURN. }
    diagnosticArchiveLine(report,"STATS rendezvous setup action="+action+" target="+other:NAME
        +" cap="+cap+" reserve="+reserve+" ownInc="+SHIP:ORBIT:INCLINATION+" otherInc="+other:ORBIT:INCLINATION
        +" sep="+(other:POSITION-SHIP:POSITION):MAG
        +" relV="+(SHIP:VELOCITY:ORBIT-other:VELOCITY:ORBIT):MAG).
    IF action = "match" {
        PRINT "Matching velocity and closing to150m; this is a stand-off, not contact.".
        LOCAL success IS matchRendezvous(other,150,cap,reserve,report).
        // All exits verify physical cutoff, including context/Abort failures.
        LOCAL stopped IS thrustCutoffOk(). UNLOCK STEERING. SAS ON.
        IF other:ISDEAD {
            diagnosticArchiveLine(report,"STATS rendezvous peer unavailable cutoff="+stopped).
            diagnosticArchiveClose(report,"Rendezvous match"). RETURN.
        }
        diagnosticArchiveLine(report,"STATS rendezvous matched="+success+" cutoff="+stopped
            +" sep="+(other:POSITION-SHIP:POSITION):MAG
            +" relV="+(SHIP:VELOCITY:ORBIT-other:VELOCITY:ORBIT):MAG).
        diagnosticArchiveClose(report,"Rendezvous match"). RETURN.
    }
    LOCAL result IS rendezvousSearch(other,cap,reserve,report).
    diagnosticArchiveLine(report,"STATS rendezvous result ok="+result["OK"]+" reason="+result["REASON"]).
    IF NOT result["OK"] { diagnosticArchiveClose(report,"Rendezvous"). RETURN. }
    LOCAL nd IS result["NODE"]. LOCAL craftRef IS SHIP.
    diagnosticArchiveLine(report,"STATS rendezvous selected ut="+nd:TIME+" dv="+nd:DELTAV:MAG
        +" ca="+result["CA"]+" caUt="+result["CAUT"]+" matchDv="+result["BRAKE"]
        +" prograde="+nd:PROGRADE+" normal="+nd:NORMAL+" radial="+nd:RADIALOUT).
    IF action = "preview" {
        IF NOT rendezvousRelease(craftRef,nd,result["STAMP"]) { PRINT "Node changed; retained for inspection.". }
    } ELSE {
        PRINT "Inspect the rendezvous node, then RUNPATH('0:/cmd/exnode.ks').".
        PRINT "After that burn, run rendezvous with 'match' and the SAME target name to stop nearby.".
        PRINT "No automatic retask, contact, staging or deorbit has been armed.".
    }
    diagnosticArchiveClose(report,"Rendezvous").
}

_cmdRendezvous().
