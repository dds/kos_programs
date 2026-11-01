// ============================================================
// scanorbit.ks - Compare economical scan orbits from a manual prompt.
// RUNPATH("0:/cmd/scanorbit.ks"). Preview; leaves no node.
// RUNPATH("0:/cmd/scanorbit.ks","plan"). Re-search and retain best node.
// Optional mode auto|drift|polar|mirror, scan type, dV cap, retained reserve.
// Quicksave first: a native runtime error can leave a temporary preview node.
// ============================================================
@LAZYGLOBAL OFF.
PARAMETER action IS "preview".
PARAMETER mode IS "auto".
PARAMETER scanType IS "".
PARAMETER cap IS 50.
PARAMETER reserve IS 100.

LOCAL FUNCTION _cmdScanorbit {
    IF NOT HOMECONNECTION:ISCONNECTED { PRINT "Scan-orbit comparison requires an archive link.". RETURN. }
    IF NOT cap:ISTYPE("Scalar") OR NOT reserve:ISTYPE("Scalar") {
        PRINT "dV cap and reserve must be numbers.". RETURN.
    }
    IF NOT LIST("preview","plan"):CONTAINS(action) OR NOT LIST("auto","drift","polar","mirror"):CONTAINS(mode)
            OR NOT (cap >= 0.3 AND cap <= 500 AND reserve >= 0 AND reserve < 1e30) {
        PRINT "Use preview/plan, auto/drift/polar/mirror, scan type, cap(0.3..500m/s), reserve(m/s).". RETURN.
    }
    RUNPATH("1:/lib/boot_lib"). bootPreamble().
    bootLibLoad("orbit_shape"). bootLibLoad("landing_math").
    RUNPATH("0:/lib/survey_orbit.ks").
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    IF NOT surveyOrbitIdle(SHIP,FALSE) OR NOT surveyOrbitSafe(SHIP:ORBIT,surveyOrbitFloor(),1e29) {
        PRINT "Use a stopped SCANSAT_OPS/SCIENCE_OPS/DONE prompt: safe near-polar orbit, no node or pending burn, throttle/Abort off at1x.". RETURN.
    }
    // Replay selected profile/overrides without selecting a mission or band.
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    LOCAL script IS "missions/"+vehicle+"/"+bootMissionProfileId(vehicle,mid).
    LOCAL path_ IS bootArchivePath(script).
    IF path_ = "" OR NOT EXISTS(path_) { SET path_ TO bootLocalScriptPath(script). }
    IF path_ = "" { SET path_ TO bootLocalScriptPath("missions/"+vehicle+"/"+mid). }
    IF vehicle = "" OR mid = "" OR path_ = "" OR NOT EXISTS(path_) {
        PRINT "Selected mission profile required to preserve its fuel/budget limits.". RETURN.
    }
    RUNPATH(path_). bootMissionProfileIntent(vehicle,mid). applyMissionOverrides().
    IF DEFINED EXCURSION_RESERVE_DV { SET reserve TO MAX(reserve,EXCURSION_RESERVE_DV). }
    IF NOT ADDONS:AVAILABLE("SCANSAT") OR NOT ADDONS:SCANSAT:AVAILABLE { PRINT "kOS-SCANsat addon unavailable.". RETURN. }
    LOCAL types IS ADDONS:SCANSAT:ALLSCANTYPES.
    IF NOT types:ISTYPE("List") { PRINT "Scan type list unavailable.". RETURN. }
    LOCAL cov IS -1.
    LOCAL chooseType IS scanType = "".
    FOR kind IN types {
        LOCAL pct IS ADDONS:SCANSAT:GETCOVERAGE(SHIP:BODY,kind).
        IF chooseType AND pct > 0 AND pct < 99.9 AND pct > cov { SET cov TO pct. SET scanType TO kind. }
    }
    // Explicit scan types also permit starting a map at zero coverage.
    IF NOT types:CONTAINS(scanType) { PRINT "Supply a partially mapped scan type from: "+types. RETURN. }
    LOCAL scanner IS FALSE.
    FOR part IN SHIP:PARTS { IF part:HASMODULE("SCANsat") { SET scanner TO TRUE. } }
    IF NOT scanner { PRINT "No attached SCANsat scanner; nothing planned.". RETURN. }
    LOCAL craftRef IS SHIP.
    IF NOT surveyOrbitIdle(craftRef,FALSE) OR NOT surveyOrbitSafe(SHIP:ORBIT,surveyOrbitFloor(),1e29) {
        PRINT "Selected mission limits or flight context reject this orbit; nothing planned.". RETURN.
    }
    LOCAL report IS diagnosticArchiveOpen("scanorbit").
    IF NOT report["READY"] { RETURN. }
    diagnosticArchiveLine(report,"STATS scanorbit setup schema=2 ut="+TIME:SECONDS
        +" mission="+mid+" phase="+stateGet("phase","")+" action="+action+" mode="+mode+" type="+scanType
        +" coverage="+ADDONS:SCANSAT:GETCOVERAGE(SHIP:BODY,scanType)+" cap="+cap+" reserve="+reserve
        +" body="+SHIP:BODY:NAME+" Pe="+SHIP:PERIAPSIS+" Ap="+SHIP:APOAPSIS
        +" inc="+SHIP:ORBIT:INCLINATION+" lan="+SHIP:ORBIT:LAN).
    PRINT "Comparing several period changes with paired ground-track samples; verify scan type and altitude in SCANsat.".
    LOCAL searchUt IS TIME:SECONDS.
    LOCAL searchWall IS KUNIVERSE:REALTIME.
    LOCAL result IS surveyOrbitSearch(scanType,mode,cap,reserve,report).
    diagnosticArchiveLine(report,"STATS scanorbit result reason="+result["REASON"]+" ok="+result["OK"]
        +" elapsed="+(TIME:SECONDS-searchUt)+" wall="+(KUNIVERSE:REALTIME-searchWall)).
    IF NOT result["OK"] {
        PRINT "No new scan maneuver: "+result["REASON"]+". See the archived comparison.".
        diagnosticArchiveClose(report,"Scan orbit"). RETURN.
    }
    LOCAL nd IS result["NODE"].
    IF NOT surveyOrbitOwned(craftRef,nd) { PRINT "Vessel/node changed; preview retained for inspection.". RETURN. }
    LOCAL best IS result["BEST"].
    diagnosticArchiveLine(report,"STATS scanorbit selected mode="+best["MODE"]+" dv="+nd:DELTAV:MAG
        +" score="+best["SCORE"]+" nodeUt="+nd:TIME+" prograde="+nd:PROGRADE
        +" normal="+nd:NORMAL+" radial="+nd:RADIALOUT).
    PRINT "Suggested "+best["MODE"]+": "+ROUND(nd:DELTAV:MAG,2)+"m/s, inc="+ROUND(nd:ORBIT:INCLINATION,2)
        +" Pe/Ap="+ROUND(nd:ORBIT:PERIAPSIS/1000,2)+"/"+ROUND(nd:ORBIT:APOAPSIS/1000,2)+"km.".
    IF action = "preview" {
        IF NOT surveyOrbitRelease(craftRef,nd) {
            PRINT "Preview cleanup context changed; inspect any remaining node.". RETURN.
        }
        PRINT "Preview finished. Use the plan action to re-evaluate and create a node; mission goals remain unchanged.".
        diagnosticArchiveClose(report,"Scan orbit"). RETURN.
    }
    // Recheck after diagnostic I/O; planning never burns or stages.
    IF NOT surveyOrbitIdle(craftRef,TRUE) OR NEXTNODE <> nd
            OR NOT surveyOrbitAffordable(nd:DELTAV:MAG,cap,reserve) OR nd:ETA < 180 {
        PRINT "Flight context changed; maneuver retained for inspection, no burn.". RETURN.
    }
    diagnosticArchiveClose(report,"Scan orbit").
    IF NOT surveyOrbitIdle(craftRef,TRUE) OR NEXTNODE <> nd OR nd:ETA < 180 { RETURN. }
    IF NOT shapeReserveBurn(nd) { RETURN. }
    PRINT "Node retained; its dV is reserved in the existing SHAPE allowance (also if later cancelled).".
    PRINT "Inspect it, then RUNPATH('0:/cmd/exnode.ks'). to fly with the normal KAC/burn safeguards.".
    PRINT "After a successful burn, REBOOT. resumes the existing scan/review phase.".
}

_cmdScanorbit().
