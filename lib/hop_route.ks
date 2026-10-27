// Profile-programmed airless sites, with resident surface science stops.
// Manual cmd/hoproute routes keep their explicit prompt after each landing.
@LAZYGLOBAL OFF.

GLOBAL HOP_ROUTE_SITES IS LIST().
GLOBAL HOP_SITE_DWELL_SECONDS IS 0.
GLOBAL HOP_SITE_RADIUS IS 100.
GLOBAL HOP_SITE_RUN_SCIENCE IS 1.

GLOBAL FUNCTION phaseHopRouteSetup {
    IF NOT thrustCutoffOk() OR ABORT OR HASNODE OR SHIP:STATUS <> "LANDED"
            OR SHIP:BODY:ATM:EXISTS OR SHIP:VELOCITY:SURFACE:MAG > 0.5
            OR NOT vesselLandingPrepareRoles() {
        mLogError("Hop route setup requires settled airless touchdown, idle controls and valid stage roles.").
        yieldToPrompt(). RETURN.
    }
    IF HOP_ROUTE_SITES:LENGTH < 2 OR HOP_ROUTE_SITES:LENGTH > 16
            OR NOT (HOP_SITE_DWELL_SECONDS > 0 AND HOP_SITE_DWELL_SECONDS < 1e9)
            OR NOT (HOP_SITE_RADIUS >= 10 AND HOP_SITE_RADIUS < 10000) {
        mLogError("Hop route setup: invalid sites, dwell or site radius.").
        yieldToPrompt(). RETURN.
    }
    LOCAL previous IS HOP_ROUTE_SITES[0].
    FOR site IN HOP_ROUTE_SITES {
        IF site:LENGTH <> 2 OR NOT (ABS(site[0]) <= 90 AND ABS(site[1]) <= 180)
                OR geoDistance(previous[0],previous[1],site[0],site[1]) > SHIP:BODY:RADIUS*0.25 {
            mLogError("Hop route setup: invalid coordinate or excessive leg range.").
            yieldToPrompt(). RETURN.
        }
        SET previous TO site.
    }
    LOCAL first IS HOP_ROUTE_SITES[0].
    IF geoDistance(SHIP:LATITUDE,SHIP:LONGITUDE,first[0],first[1]) > HOP_SITE_RADIUS {
        mLogError("Hop route setup: first landing outside programmed site radius; staying landed.").
        yieldToPrompt(). RETURN.
    }
    IF stateGet("hop_route_active",FALSE) {
        IF NOT stateGet("hop_route_automatic",FALSE)
                OR stateGet("hop_route_body","") <> SHIP:BODY:NAME
                OR configLiteral(stateGet("hop_route_sites",LIST())) <> configLiteral(HOP_ROUTE_SITES) {
            mLogError("Hop route setup: another saved route is active; not replacing it.").
            yieldToPrompt(). RETURN.
        }
    } ELSE {
        IF NOT SEQUENCE:CONTAINS("SURFACE_RETURN_SETUP") {
            mLogError("Hop route setup: no surface return phase to restore.").
            yieldToPrompt(). RETURN.
        }
        stateSet("hop_route_restore",hopRouteRestoreSettings()).
        stateSet("hop_route_sites",HOP_ROUTE_SITES).
        stateSet("hop_route_index",0).
        stateRemove("hop_route_pending").
        stateRemove("hop_site_dwell").
        stateSet("hop_route_body",SHIP:BODY:NAME).
        stateSet("hop_inflight",FALSE).
        stateSet("hop_route_automatic",TRUE).
        stateSet("hop_route_active",TRUE).
    }
    // State is committed before replacing the sequence. Re-entering setup
    // after an interrupted write does not snapshot the temporary hop chain.
    missionOverrideUpdate(LEXICON("SEQUENCE",LIST("HOP","LAND_ASSIST","HOP_AUTO_REVIEW"))).
    stateSaveReloadState("HOP_ROUTE_READY","HOP_AUTO_REVIEW","HOP_ROUTE").
    REBOOT.
}

LOCAL FUNCTION _hopDwellSafe {
    PARAMETER siteIndex.
    RETURN NOT ABORT AND NOT phaseShouldYield AND NOT HASNODE AND stateGet("hop_route_active",FALSE)
        AND stateGet("hop_route_automatic",FALSE) AND stateGet("phase","") = "HOP_AUTO_REVIEW"
        AND stateGetNum("hop_route_index",-1) = siteIndex
        AND SHIP:BODY:NAME = stateGet("hop_route_body","")
        AND SHIP:STATUS = "LANDED" AND SHIP:VELOCITY:SURFACE:MAG <= 0.5
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0.
}

GLOBAL FUNCTION phaseHopAutoReview {
    IF NOT thrustCutoffOk() { yieldToPrompt(). RETURN. }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    _hopRestoreSavedLimits().
    LOCAL index IS stateGetNum("hop_route_index",-1).
    LOCAL sites IS stateGet("hop_route_sites",LIST()).
    IF index < 0 OR index >= sites:LENGTH OR NOT _hopDwellSafe(index) {
        mLogError("Timed hop science requires the saved route and settled surface controls.").
        yieldToPrompt(). RETURN.
    }
    LOCAL site IS sites[index].
    IF geoDistance(SHIP:LATITUDE,SHIP:LONGITUDE,site[0],site[1]) > HOP_SITE_RADIUS {
        mLogError("Timed hop science: landing missed programmed site; no automatic departure.").
        yieldToPrompt(). RETURN.
    }
    UNLOCK STEERING.
    SET SAS TO TRUE.
    SET BRAKES TO TRUE.
    LOCAL settledAt IS TIME:SECONDS.
    UNTIL TIME:SECONDS-settledAt >= 2 OR NOT _hopDwellSafe(index) { WAIT 0.2. }
    IF NOT _hopDwellSafe(index) { yieldToPrompt(). RETURN. }
    stateSet("hop_inflight",FALSE).
    LOCAL siteKey IS configLiteral(LIST(SHIP:BODY:NAME,index,site[0],site[1])).
    LOCAL dwell IS stateGet("hop_site_dwell",LEXICON()).
    IF NOT dwell:HASKEY("KEY") OR dwell["KEY"] <> siteKey {
        SET dwell TO LEXICON("KEY",siteKey,"UNTIL",TIME:SECONDS+HOP_SITE_DWELL_SECONDS,"SCIENCE_STARTED",FALSE).
        stateSet("hop_site_dwell",dwell).
    }
    LOCAL alarmId IS "".
    IF dwell["UNTIL"] > TIME:SECONDS {
        SET alarmId TO kacEnsureAlarm("Hop science stop",dwell["UNTIL"],
            "Surface science stop ends; automatic hop or configured return follows if safe.",1).
    }
    mLog("STATS hop science site=" + (index+1) + "/" + sites:LENGTH
        + " wakeUt=" + dwell["UNTIL"] + " remaining=" + MAX(0,dwell["UNTIL"]-TIME:SECONDS)
        + " alarm=" + alarmId + " resident=True warp=0").
    PRINT "Surface science stop: " + ROUND(MAX(0,dwell["UNTIL"]-TIME:SECONDS),0)
        + "s remaining; automatic continuation when safe. Abort stops departure.".
    // Install the wake alarm before experiment events. Persist the attempt
    // before calling them so a reboot cannot repeatedly deploy an experiment.
    IF NOT dwell["SCIENCE_STARTED"] {
        SET dwell TO dwell:COPY.
        SET dwell["SCIENCE_STARTED"] TO TRUE.
        stateSet("hop_site_dwell",dwell).
        IF HOP_SITE_RUN_SCIENCE > 0 { scienceRunAll(). }
    }
    // A landed craft keeps its attitude and brakes. Orbital solar turning /
    // auto-warp would be inappropriate here; no KAC still has a clock wake.
    UNTIL TIME:SECONDS >= dwell["UNTIL"] OR NOT _hopDwellSafe(index) { WAIT 1. }
    IF alarmId <> "" AND ADDONS:KAC:AVAILABLE { DELETEALARM(alarmId). }
    IF NOT _hopDwellSafe(index)
            OR geoDistance(SHIP:LATITUDE,SHIP:LONGITUDE,site[0],site[1]) > HOP_SITE_RADIUS {
        mLogWarn("Timed hop science interrupted; no automatic departure.").
        yieldToPrompt(). RETURN.
    }
    hopContinue().
    // A rejected terrain/fuel/staging check returns without a reboot.
    yieldToPrompt().
}
