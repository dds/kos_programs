// ============================================================
// Plan an explicit mapper apoapsis raise to change ground-track spacing.
// RUNPATH("0:/cmd/scanraise.ks",130). Altitude in km; inspect, then exnode.
// Current Pe/plane retained. No execution, scanner or mission-goal changes.
// ============================================================
@LAZYGLOBAL OFF.
PARAMETER apoapsisKm.
PARAMETER cap IS 50.

LOCAL FUNCTION _cmdScanraise {
    IF NOT HOMECONNECTION:ISCONNECTED { PRINT "Mapper orbit planning requires an archive link.". RETURN. }
    IF NOT apoapsisKm:ISTYPE("Scalar") OR NOT cap:ISTYPE("Scalar") {
        PRINT "Supply target apoapsis in km and an optional dV cap in m/s.". RETURN.
    }
    IF NOT (apoapsisKm > 0 AND apoapsisKm < 1e26 AND cap >= 0.3 AND cap <= 500) { RETURN. }
    RUNPATH("1:/lib/boot_lib"). bootPreamble().
    bootLibLoad("orbit_shape").
    RUNPATH("0:/lib/survey_orbit.ks"). RUNONCEPATH("0:/lib/diagnostic_log.ks").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,TRUE) { RETURN. }
    LOCAL craftRef IS SHIP.
    LOCAL bodyRef IS SHIP:BODY.
    LOCAL phase_ IS stateGet("phase","").
    LOCAL launch_ IS stateGetNum("launch_time",0).
    LOCAL reserve IS MAX(0,SHAPE_RESERVE_DV).
    IF DEFINED EXCURSION_RESERVE_DV { SET reserve TO MAX(reserve,EXCURSION_RESERVE_DV). }
    IF NOT surveyOrbitIdle(craftRef,FALSE) OR NOT surveyOrbitSafe(SHIP:ORBIT,surveyOrbitFloor(),1e29) {
        PRINT "Use an idle SCANSAT_OPS/SCIENCE_OPS/DONE near-polar orbit, no node/pending burn, Abort/throttle clear at1x.". RETURN.
    }
    LOCAL scanner IS FALSE.
    FOR part IN SHIP:PARTS { IF part:HASMODULE("SCANsat") { SET scanner TO TRUE. } }
    IF NOT scanner { PRINT "No attached SCANsat scanner.". RETURN. }
    LOCAL pe IS SHIP:PERIAPSIS.
    LOCAL ap IS SHIP:APOAPSIS.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    LOCAL lan IS SHIP:ORBIT:LAN.
    LOCAL targetAlt IS apoapsisKm*1000.
    IF NOT (targetAlt > ap+500 AND targetAlt < SHIP:BODY:SOIRADIUS-SHIP:BODY:RADIUS
            AND (targetAlt-pe)/(targetAlt+pe+2*SHIP:BODY:RADIUS) < 0.1) {
        PRINT "Select a higher, bound apoapsis retaining eccentricity<0.1; check the installed scanner's altitude range.". RETURN.
    }
    LOCAL report IS diagnosticArchiveOpen("scanraise").
    IF NOT report["READY"] { RETURN. }
    LOCAL nd IS surveyOrbitDriftNode(TRUE,targetAlt-ap).
    LOCAL FUNCTION validNode {
        IF NOT surveyOrbitOwned(craftRef,nd) { RETURN FALSE. }
        RETURN surveyOrbitIdle(craftRef,TRUE) AND stateGet("phase","") = phase_
            AND SHIP:BODY = bodyRef
            AND stateGet("vehicle","") = vehicle AND stateGet("mission_id","") = mid
            AND stateGetNum("launch_time",0) = launch_
            AND surveyOrbitSafe(nd:ORBIT,pe-500,targetAlt+500)
            AND ABS(nd:ORBIT:PERIAPSIS-pe) <= 500 AND ABS(nd:ORBIT:APOAPSIS-targetAlt) <= 500
            AND ABS(nd:ORBIT:INCLINATION-inc) <= 0.1
            AND ABS(MOD(nd:ORBIT:LAN-lan+540,360)-180) <= 0.1
            AND surveyOrbitAffordable(nd:DELTAV:MAG,cap,reserve) AND nd:ETA >= 180.
    }
    IF NOT validNode() {
        IF surveyOrbitOwned(craftRef,nd) { surveyOrbitRelease(craftRef,nd). }
        diagnosticArchiveLine(report,"STATS scanraise result=rejected targetAp="+targetAlt+" cap="+cap+" reserve="+reserve).
        diagnosticArchiveClose(report,"Scan raise"). RETURN.
    }
    diagnosticArchiveLine(report,"STATS scanraise plan mission="+mid+" phase="+phase_
        +" body="+SHIP:BODY:NAME+" dv="+nd:DELTAV:MAG+" nodeUt="+nd:TIME
        +" beforePe="+pe+" beforeAp="+ap+" afterPe="+nd:ORBIT:PERIAPSIS+" afterAp="+nd:ORBIT:APOAPSIS
        +" beforeInc="+inc+" afterInc="+nd:ORBIT:INCLINATION
        +" beforePeriod="+SHIP:ORBIT:PERIOD+" afterPeriod="+nd:ORBIT:PERIOD
        +" cap="+cap+" reserve="+reserve+" coverageGain=operator-experiment").
    diagnosticArchiveClose(report,"Scan raise").
    // Archive writes yield: recheck ownership, controls, native orbit, timing
    // and all mission/active-stage allowances before reserving the plan.
    IF NOT validNode() {
        IF surveyOrbitOwned(craftRef,nd) { surveyOrbitRelease(craftRef,nd). }
        PRINT "Context or native orbit changed; no plan reserved.". RETURN.
    }
    IF NOT shapeReserveBurn(nd) { RETURN. }
    PRINT "Mapper apoapsis raise planned: "+ROUND(nd:DELTAV:MAG,2)+"m/s; Pe/Ap="
        +ROUND(nd:ORBIT:PERIAPSIS/1000,2)+"/"+ROUND(nd:ORBIT:APOAPSIS/1000,2)+"km.".
    PRINT "Verify scanner altitude/daylight; coverage gain is an experiment. Plan dV is reserved even if later cancelled.".
    PRINT "Inspect, then RUNPATH('0:/cmd/exnode.ks'). After a successful burn, REBOOT. resumes "+phase_+".".
}

_cmdScanraise().
