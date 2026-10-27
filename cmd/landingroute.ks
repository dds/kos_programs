// Read-only route comparison; archive the report while linked and coasting.
// RUNPATH("0:/cmd/landingroute.ks").
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdLandingroute {
    IF NOT HOMECONNECTION:ISCONNECTED {
        PRINT "Landing route report needs an archive link.". RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" OR SHIP:THRUST > 0.001
            OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Run the landing route comparison while coasting in a stable orbit at zero throttle.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("landing_route").
    IF NOT bootApplyMissionConfig(stateGet("vehicle",""),stateGet("mission_id",""),HOMECONNECTION:ISCONNECTED) {
        PRINT "Mission profile unavailable; route report canceled.". RETURN.
    }
    vesselLandingPrepareRoles().
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    LOCAL reportState IS diagnosticArchiveOpen("landingroute").
    IF NOT reportState["READY"] { RETURN. }
    LOCAL targets IS landingPrepTargets().
    LOCAL result IS landingRouteSnapshot(targets).
    FOR row IN landingRouteLines(result) { diagnosticArchiveLine(reportState,row). }
    diagnosticArchiveClose(reportState,"STATS landing-route").
}

_cmdLandingroute().
