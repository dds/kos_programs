// ============================================================
// hop.ks  -  Ballistic surface hop phase  (0:/lib/hop.ks)
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL HOP_TARGET_LAT IS 0.
GLOBAL HOP_TARGET_LNG IS 0.
GLOBAL HOP_TOLERANCE IS 750.
GLOBAL HOP_PITCH IS 45.
GLOBAL HOP_MAX_BURN_SECONDS IS 90.
GLOBAL HOP_MAX_AP_KM IS 5.
GLOBAL HOP_TWR IS 2.5.
GLOBAL HOP_MIN_THRUST_LIMIT IS 1.

GLOBAL HOP_RETURN_RESERVE_DV IS 700.
GLOBAL HOP_LANDING_RESERVE_DV IS 180.

GLOBAL FUNCTION hopReviewPhase {
    IF stateGet("hop_route_automatic",FALSE) { RETURN "HOP_AUTO_REVIEW". }
    RETURN "HOP_REVIEW".
}

GLOBAL FUNCTION hopRouteRestoreSettings {
    RETURN LEXICON("SEQUENCE",SEQUENCE,"TARGET_LAT",TARGET_LAT,"TARGET_LNG",TARGET_LNG,
        "TARGET_LOCK",TARGET_LOCK,"TARGET_WAYPOINT",TARGET_WAYPOINT,
        "LANDING_USE_WAYPOINTS",LANDING_USE_WAYPOINTS,"LANDING_FLEXIBLE_SITE",LANDING_FLEXIBLE_SITE,
        "LANDING_ECONOMY_BRAKE",LANDING_ECONOMY_BRAKE,"LANDING_STAGE_BRAKE_CREDIT",LANDING_STAGE_BRAKE_CREDIT,
        "LANDING_POWERED_LEAD",LANDING_POWERED_LEAD,"LANDING_STAGE_DISCARD_HSPEED",LANDING_STAGE_DISCARD_HSPEED,
        "RELOAD_AFTER_LAND_ASSIST",RELOAD_AFTER_LAND_ASSIST).
}

GLOBAL FUNCTION hopRouteBudget {
    PARAMETER distance.
    LOCAL gravAcc IS SHIP:BODY:MU/SHIP:BODY:RADIUS^2.
    LOCAL launchDv IS SQRT(MAX(0,gravAcc*distance)/MAX(0.1,SIN(2*HOP_PITCH))).
    RETURN HOP_RETURN_RESERVE_DV+HOP_LANDING_RESERVE_DV+3*launchDv.
}

GLOBAL FUNCTION hopRouteFuelOk {
    PARAMETER distance.
    LOCAL needed IS hopRouteBudget(distance).
    RETURN SHIP:DELTAV:VACUUM >= needed
        AND STAGE:DELTAV:VACUUM >= needed-HOP_RETURN_RESERVE_DV.
}

// Commit a selected next leg only after its HOP phase actually starts.
// Repeating either write after a reboot is idempotent; a partial review->HOP
// handoff cannot make review count an unflown site as already completed.
LOCAL FUNCTION _hopApplyPending {
    LOCAL pending IS stateGetNum("hop_route_pending",-1).
    IF pending < 0 { RETURN TRUE. }
    LOCAL sites IS stateGet("hop_route_sites",LIST()).
    IF pending >= sites:LENGTH { RETURN FALSE. }
    stateSet("hop_route_index",pending).
    stateRemove("hop_route_pending").
    RETURN TRUE.
}

// Explicit operator review is the exception to resident scheduled waits.
// Prompt actions run through a local script: kOS user functions cannot safely
// be called directly from the interpreter after the program context ends.
LOCAL FUNCTION _hopSurfaceReady {
    IF ABORT OR HASNODE OR NOT stateGet("hop_route_active",FALSE)
            OR (stateGet("phase","") <> "HOP_REVIEW" AND stateGet("phase","") <> "HOP_AUTO_REVIEW")
            OR SHIP:STATUS <> "LANDED" OR SHIP:BODY:ATM:EXISTS
            OR SHIP:BODY:NAME <> stateGet("hop_route_body","")
            OR SHIP:VELOCITY:SURFACE:MAG > 0.5 {
        PRINT "Hop action requires settled surface review, the original body, no node and Abort clear.".
        RETURN FALSE.
    }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    IF NOT thrustCutoffOk() { RETURN FALSE. }
    SET BRAKES TO TRUE.
    RETURN TRUE.
}

LOCAL FUNCTION _hopDestinationAllowed {
    PARAMETER site.
    IF ABS(site[0]) > 90 OR ABS(site[1]) > 180 { RETURN FALSE. }
    IF NOT vesselLandingPrepareRoles() { RETURN FALSE. }
    LOCAL distance IS geoDistance(SHIP:LATITUDE,SHIP:LONGITUDE,site[0],site[1]).
    IF distance > SHIP:BODY:RADIUS*0.25 OR NOT hopRouteFuelOk(distance) {
        PRINT "Hop exceeds local range or launch/landing budget plus return reserve; staying landed.".
        RETURN FALSE.
    }
    LOCAL grade IS landingTerrainGrade(site[0],site[1],20).
    IF grade < 0 OR grade > TAN(LANDING_TERRAIN_MAX_SLOPE) {
        PRINT "Hop destination terrain is unknown or exceeds the normal slope limit; staying landed.".
        RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _hopScheduleSite {
    PARAMETER siteIndex.
    PARAMETER site.
    PARAMETER rebootNow IS TRUE.
    missionOverrideUpdate(LEXICON("HOP_TARGET_LAT",site[0],"HOP_TARGET_LNG",site[1])).
    stateSet("hop_route_pending",siteIndex).
    stateSaveReloadState("HOP_NEXT_SITE","HOP","HOP").
    IF rebootNow { REBOOT. }
}

GLOBAL FUNCTION hopSelectSite {
    PARAMETER siteNumber.
    PARAMETER rebootNow IS TRUE.
    IF NOT _hopSurfaceReady() { RETURN FALSE. }
    LOCAL sites IS stateGet("hop_route_sites",LIST()).
    LOCAL index IS siteNumber-1.
    IF index < 0 OR index >= sites:LENGTH OR index <> FLOOR(index) {
        PRINT "Choose a listed site number; no hop selected.". RETURN FALSE.
    }
    IF NOT _hopDestinationAllowed(sites[index]) { RETURN FALSE. }
    _hopScheduleSite(index,sites[index],rebootNow).
    RETURN TRUE.
}

GLOBAL FUNCTION hopFinishRoute {
    PARAMETER rebootNow IS TRUE.
    IF NOT _hopSurfaceReady() { RETURN. }
    _hopFinishRoute(FALSE,rebootNow).
}

LOCAL FUNCTION _hopFinishRoute {
    PARAMETER economyReturn IS FALSE.
    PARAMETER rebootNow IS TRUE.
    LOCAL previous IS stateGet("hop_route_restore",LEXICON()).
    IF previous:LENGTH = 0 { PRINT "Original mission settings unavailable; no return configured.". RETURN. }
    IF economyReturn AND SHIP:BODY:NAME <> "Mun" AND SHIP:BODY:NAME <> "Minmus" {
        PRINT "Economy Kerbin return requires Mun or Minmus surface.". RETURN.
    }
    missionOverrideUpdate(previous).
    SET SEQUENCE TO previous["SEQUENCE"].
    LOCAL nextName IS "DONE".
    IF SEQUENCE:CONTAINS("SURFACE_RETURN_SETUP") { SET nextName TO "SURFACE_RETURN_SETUP". }
    ELSE IF SEQUENCE:CONTAINS("RETURN_SETUP") AND SEQUENCE:CONTAINS("LAUNCH") {
        SET nextName TO "PRELAUNCH".
    }
    IF economyReturn {
        // Leave now through the normal ascent/departure safety gates, with
        // no KSC targeting or optional science detour. Keep chute/stage policy.
        missionOverrideUpdate(LEXICON("SEQUENCE",LIST("SURFACE_RETURN_SETUP"),
            "SURFACE_RETURN_SEQUENCE",LIST("PRELAUNCH","LAUNCH","PARK","RETURN_SETUP"),
            "SURFACE_RETURN_PARKING_ALT",10000,"SURFACE_RETURN_INCLINATION",0,
            "RETURN_SEQUENCE",LIST("ESCAPE","COAST","MCC","AEROBRAKE","DESCENT","DONE"),
            "RETURN_PE",53000,"RETURN_PE_TOLERANCE",1000,"RETURN_KSC_TARGET",0)).
        SET nextName TO "SURFACE_RETURN_SETUP".
    }
    stateSet("hop_route_active",FALSE).
    stateSet("hop_route_automatic",FALSE).
    stateRemove("hop_site_dwell").
    stateRemove("hop_route_pending").
    stateSaveReloadState("HOP_ROUTE_FINISHED",nextName,bootLibBandForPhase(nextName)).
    IF rebootNow { REBOOT. }
}

GLOBAL FUNCTION hopContinue {
    IF NOT _hopSurfaceReady() { RETURN. }
    LOCAL sites IS stateGet("hop_route_sites",LIST()).
    LOCAL nextIndex IS stateGetNum("hop_route_index",0)+1.
    IF nextIndex >= sites:LENGTH { _hopFinishRoute(). RETURN. }
    IF NOT _hopDestinationAllowed(sites[nextIndex]) { RETURN. }
    _hopScheduleSite(nextIndex,sites[nextIndex]).
}

GLOBAL FUNCTION hopWaypoint {
    IF NOT _hopSurfaceReady() { RETURN. }
    LOCAL wp IS selectedWaypoint().
    IF wp = 0 { PRINT "Select a navigation waypoint on this body first.". RETURN. }
    LOCAL site IS LIST(wp:LATITUDE,wp:LONGITUDE).
    IF NOT _hopDestinationAllowed(site) { RETURN. }
    // Only the outer list changes; existing coordinate pairs are read-only.
    LOCAL sites IS stateGet("hop_route_sites",LIST()):COPY.
    LOCAL nextIndex IS stateGetNum("hop_route_index",0)+1.
    IF nextIndex < sites:LENGTH { SET sites[nextIndex] TO site. }
    ELSE { sites:ADD(site). }
    stateSet("hop_route_sites",sites).
    _hopScheduleSite(nextIndex,site).
}

GLOBAL FUNCTION hopReturn {
    IF NOT _hopSurfaceReady() { RETURN. }
    _hopFinishRoute(TRUE).
}

LOCAL FUNCTION _hopWritePromptCommand {
    LOCAL wrapperPath IS "1:/run/hop.ks".
    LOCAL quote IS CHAR(34).
    IF EXISTS(wrapperPath) { DELETEPATH(wrapperPath). }
    LOG "PARAMETER action IS " + quote + "continue" + quote + "." TO wrapperPath.
    LOG "LOCAL FUNCTION _hopPrompt {" TO wrapperPath.
    LOG "IF ABORT OR SHIP:STATUS <> " + quote + "LANDED" + quote + " OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 { RETURN. }" TO wrapperPath.
    LOG "SET WARP TO 0. WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED." TO wrapperPath.
    LOG "RUNPATH(" + quote + "1:/lib/boot_lib" + quote + ")." TO wrapperPath.
    LOG "bootPreamble(). bootLibLoad(" + quote + "hop" + quote + ")." TO wrapperPath.
    LOG "bootLibLoad(" + quote + "craft/" + quote + " + stateGet(" + quote + "vehicle" + quote + "," + quote + quote + "))." TO wrapperPath.
    LOG "IF NOT bootApplyMissionConfig(stateGet(" + quote + "vehicle" + quote + "," + quote + quote + "),stateGet(" + quote + "mission_id" + quote + "," + quote + quote + "),HOMECONNECTION:ISCONNECTED) { RETURN. }" TO wrapperPath.
    LOG "IF action = " + quote + "continue" + quote + " { hopContinue(). }" TO wrapperPath.
    LOG "ELSE IF action = " + quote + "waypoint" + quote + " { hopWaypoint(). }" TO wrapperPath.
    LOG "ELSE IF action = " + quote + "return" + quote + " { hopReturn(). }" TO wrapperPath.
    LOG "ELSE { PRINT " + quote + "Use continue, waypoint or return." + quote + ". }" TO wrapperPath.
    LOG "} _hopPrompt()." TO wrapperPath.
}

GLOBAL FUNCTION phaseHopReview {
    IF NOT thrustCutoffOk() { yieldToPrompt(). RETURN. }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    _hopRestoreSavedLimits().
    UNLOCK STEERING.
    SET BRAKES TO TRUE.
    // A loaded surface save may be bouncing/sliding. Require two quiet
    // seconds, with a bounded timeout, before printing departure commands.
    LOCAL quietSince IS TIME:SECONDS.
    LOCAL settleDeadline IS TIME:SECONDS+10.
    UNTIL TIME:SECONDS-quietSince >= 2 OR TIME:SECONDS >= settleDeadline OR ABORT {
        IF SHIP:STATUS <> "LANDED" OR SHIP:VELOCITY:SURFACE:MAG > 0.5 { SET quietSince TO TIME:SECONDS. }
        WAIT 0.2.
    }
    IF TIME:SECONDS-quietSince < 2 OR NOT _hopSurfaceReady() {
        PRINT "Surface review held: settle the craft and REBOOT. when ready.".
        yieldToPrompt(). RETURN.
    }
    stateSet("hop_inflight",FALSE).
    LOCAL completed IS stateGetNum("hop_route_index",0)+1.
    LOCAL sites IS stateGet("hop_route_sites",LIST()).
    PRINT "Hop landed and settled; brakes set, throttle off. Science/review at the prompt.".
    PRINT "Finished leg "+completed+"/"+sites:LENGTH+"; remaining dV="+ROUND(SHIP:DELTAV:VACUUM,0)+"m/s.".
    PRINT "Miss to programmed site="+ROUND(geoDistance(SHIP:LATITUDE,SHIP:LONGITUDE,
        sites[completed-1][0],sites[completed-1][1]),0)+"m.".
    _hopWritePromptCommand().
    LOCAL quote IS CHAR(34).
    LOCAL runCommand IS "RUNPATH(" + quote + "1:/run/hop" + quote.
    PRINT "Continue next route site / original return: " + runCommand + ").".
    PRINT "Hop to selected navigation waypoint: " + runCommand + "," + quote + "waypoint" + quote + ").".
    PRINT "End hops; economy return to Kerbin now: " + runCommand + "," + quote + "return" + quote + ").".
    yieldToPrompt().
}

LOCAL FUNCTION _hopPrepLandingAssist {
    LOCAL nextSequence IS LIST("HOP","LAND_ASSIST","DONE").
    IF stateGet("hop_route_active",FALSE) {
        SET nextSequence TO LIST("HOP","LAND_ASSIST",hopReviewPhase()).
    }
    missionOverrideUpdate(LEXICON("TARGET_LAT",HOP_TARGET_LAT,"TARGET_LNG",HOP_TARGET_LNG,
        "TARGET_LOCK",1,"TARGET_WAYPOINT","",
        "LANDING_USE_WAYPOINTS",0,"LANDING_FLEXIBLE_SITE",0,"LANDING_ECONOMY_BRAKE",1,
        "LANDING_STAGE_BRAKE_CREDIT",1,"LANDING_POWERED_LEAD",1,"LANDING_STAGE_DISCARD_HSPEED",0,
        "SEQUENCE",nextSequence,"RELOAD_AFTER_LAND_ASSIST",0)).
    stateSaveReloadState("HOP_COMPLETE", "LAND_ASSIST", "LANDING").
}

LOCAL FUNCTION _hopDirectionToTarget {
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL targetVec IS VXCL(upVec,
        LATLNG(HOP_TARGET_LAT, HOP_TARGET_LNG):POSITION - SHIP:POSITION).
    IF targetVec:MAG < 0.01 {
        LOCAL fallback IS VXCL(upVec, SHIP:FACING:FOREVECTOR).
        IF fallback:MAG < 0.01 { SET fallback TO VCRS(upVec, V(0,0,1)). }
        IF fallback:MAG < 0.01 { SET fallback TO VCRS(upVec, V(1,0,0)). }
        RETURN fallback:NORMALIZED.
    }
    RETURN targetVec:NORMALIZED.
}

LOCAL FUNCTION _hopLivePitch {
    LOCAL surfaceAlt IS stateGetNum("hop_surface_alt",SHIP:ALTITUDE).
    LOCAL tiltFraction IS MAX(0,MIN(1,(SHIP:ALTITUDE-surfaceAlt-5)/50)).
    RETURN 90-(90-HOP_PITCH)*tiltFraction.
}

LOCAL FUNCTION _hopSteer {
    LOCAL pitchDeg IS _hopLivePitch().
    RETURN (SHIP:UP:VECTOR * SIN(pitchDeg)
        + _hopDirectionToTarget() * COS(pitchDeg)):NORMALIZED.
}

LOCAL FUNCTION _hopCaptureThrustLimits {
    LOCAL limits IS LIST().
    FOR eng IN SHIP:ENGINES {
        limits:ADD(LEXICON("UID", eng:UID, "LIMIT", eng:THRUSTLIMIT)).
    }
    RETURN limits.
}

LOCAL FUNCTION _hopRestoreThrustLimits {
    PARAMETER limits.
    FOR item IN limits {
        FOR eng IN SHIP:ENGINES {
            IF eng:UID = item["UID"] { SET eng:THRUSTLIMIT TO item["LIMIT"]. }
        }
    }
}

GLOBAL FUNCTION _hopRestoreSavedLimits {
    _hopRestoreThrustLimits(stateGet("hop_thrust_limits",LIST())).
    stateRemove("hop_thrust_limits").
}

LOCAL FUNCTION _hopAverageThrustLimit {
    LOCAL total IS 0.
    LOCAL count IS 0.
    FOR eng IN SHIP:ENGINES {
        SET total TO total + eng:THRUSTLIMIT.
        SET count TO count + 1.
    }
    IF count = 0 { RETURN 0. }
    RETURN total / count.
}

LOCAL FUNCTION _hopTuneThrustLimit {
    LOCAL targetTotalTwr IS HOP_TWR / MAX(0.2, SIN(_hopLivePitch())).
    LOCAL currentTwr IS shipTwr().
    IF currentTwr <= 0 { RETURN targetTotalTwr. }

    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION {
            SET eng:THRUSTLIMIT TO MAX(HOP_MIN_THRUST_LIMIT,
                MIN(100, eng:THRUSTLIMIT * targetTotalTwr / currentTwr)).
        }
    }
    RETURN targetTotalTwr.
}

GLOBAL FUNCTION phaseHop {
    IF NOT thrustCutoffOk() { yieldToPrompt(). RETURN. }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    _hopRestoreSavedLimits().
    IF NOT ADDONS:TR:AVAILABLE {
        PRINT "HOP requires Trajectories.".
        mLogError("HOP: Trajectories unavailable; refusing ballistic hop.").
        RETURN.
    }

    IF stateGet("hop_route_active",FALSE) AND SHIP:BODY:NAME <> stateGet("hop_route_body","") {
        PRINT "HOP held: route belongs to a different body.". yieldToPrompt(). RETURN.
    }
    IF HASNODE OR (SHIP:STATUS = "LANDED" AND SHIP:VELOCITY:SURFACE:MAG > 0.5) {
        PRINT "HOP held: clear the maneuver node and settle the craft first.".
        yieldToPrompt(). RETURN.
    }
    stateSet("phase", "HOP").
    stateSet("lib_band", "HOP").
    stateSet("reload_required", "false").
    IF stateGetNum("launch_time", 0) = 0 {
        stateSet("launch_time", ROUND(TIME:SECONDS)).
    }

    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND (eng:THROTTLELOCK OR eng:MULTIMODE) {
            PRINT "HOP held: an active engine cannot be safely controlled by this hop executor.".
            yieldToPrompt(). RETURN.
        }
    }
    IF SHIP:STATUS = "LANDED" AND NOT stateGet("hop_inflight",FALSE) {
        IF NOT _hopApplyPending() {
            PRINT "HOP held: invalid pending route site.". yieldToPrompt(). RETURN.
        }
    }
    LOCAL startDist IS geoDistance(SHIP:LATITUDE, SHIP:LONGITUDE,
        HOP_TARGET_LAT, HOP_TARGET_LNG).
    LOCAL configMaxAp IS HOP_MAX_AP_KM * 1000.
    IF HOP_MAX_AP_KM > 1000 { SET configMaxAp TO HOP_MAX_AP_KM. }
    LOCAL maxAp IS SHIP:ALTITUDE+MIN(configMaxAp, MAX(500, startDist * 0.25)).
    ADDONS:TR:SETTARGET(LATLNG(HOP_TARGET_LAT, HOP_TARGET_LNG)).

    IF ABORT {
        PRINT "HOP held: Abort is set; clear it deliberately before resuming.".
        yieldToPrompt(). RETURN.
    }
    IF SHIP:STATUS <> "LANDED" {
        // Power loss/reboot cannot repeat the launch burn on a flown arc.
        IF stateGet("hop_inflight",FALSE) {
            _hopPrepLandingAssist(). REBOOT.
        }
        mLogError("HOP held: not landed and no recorded launch to recover.").
        yieldToPrompt(). RETURN.
    }
    IF stateGet("hop_inflight",FALSE) {
        LOCAL reviewPhase IS hopReviewPhase().
        stateSaveReloadState("HOP_SURFACE_RECOVERY",reviewPhase,bootLibBandForPhase(reviewPhase)).
        REBOOT.
    }
    IF SHIP:BODY:ATM:EXISTS OR NOT vesselLandingPrepareRoles()
            OR NOT hopRouteFuelOk(startDist) {
        PRINT "HOP held: airless body, valid stage roles and launch/landing/return fuel budget required.".
        yieldToPrompt(). RETURN.
    }
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND eng:STAGE < vesselLandingStageFloor() {
            PRINT "HOP held: a reserved return engine is enabled.". yieldToPrompt(). RETURN.
        }
    }
    // A hop may not stage into the reserved return engine. Require an
    // already enabled throttleable engine; activation/staging is deliberate.
    IF vesselLandingThrust() <= 0 OR STAGE:NUMBER < vesselLandingStageFloor() {
        PRINT "HOP held: enable the permitted landing engine before resuming.".
        yieldToPrompt(). RETURN.
    }

    PRINT " ".
    PRINT "  BALLISTIC HOP".
    PRINT "  Target lat/lng: " + ROUND(HOP_TARGET_LAT, 5)
        + ", " + ROUND(HOP_TARGET_LNG, 5).
    PRINT "  Range: " + ROUND(startDist, 0) + " m"
        + "  pitch=" + ROUND(HOP_PITCH, 1)
        + " deg  tolerance=" + ROUND(HOP_TOLERANCE, 0) + " m.".
    PRINT "  Limits: burn " + ROUND(HOP_MAX_BURN_SECONDS, 0)
        + "s, Ap " + ROUND(maxAp / 1000, 1) + " km"
        + " (cfg " + ROUND(configMaxAp / 1000, 1) + " km).".

    mLog("HOP setup: target=" + ROUND(HOP_TARGET_LAT, 5)
        + "," + ROUND(HOP_TARGET_LNG, 5)
        + " range=" + ROUND(startDist, 0)
        + "m pitch=" + ROUND(HOP_PITCH, 1)
        + " tolerance=" + ROUND(HOP_TOLERANCE, 0)
        + "m maxBurn=" + ROUND(HOP_MAX_BURN_SECONDS, 0)
        + "s maxApKm=" + ROUND(maxAp / 1000, 1)
        + " cfgMaxApKm=" + ROUND(configMaxAp / 1000, 1)
        + " rangeMaxApKm=" + ROUND(MAX(500, startDist * 0.25) / 1000, 1) + ".").

    IF startDist <= HOP_TOLERANCE {
        IF stateGet("hop_route_active",FALSE) {
            LOCAL reviewPhase IS hopReviewPhase().
            stateSaveReloadState("HOP_ALREADY_AT_SITE",reviewPhase,bootLibBandForPhase(reviewPhase)). REBOOT.
        }
        PRINT "Already inside hop tolerance; rebooting into LAND_ASSIST.".
        mLog("HOP skipped: already inside tolerance.").
        _hopPrepLandingAssist().
        REBOOT.
    }

    stateSet("hop_surface_alt",SHIP:ALTITUDE).
    SAS OFF.
    RCS OFF.

    LOCAL steeringTarget IS _hopSteer().
    LOCK STEERING TO steeringTarget.
    LOCAL alignDeadline IS TIME:SECONDS + 12.
    WAIT UNTIL VANG(SHIP:FACING:FOREVECTOR, steeringTarget) < 8
        OR TIME:SECONDS > alignDeadline OR ABORT.

    IF ABORT OR HASNODE OR SHIP:VELOCITY:SURFACE:MAG > 0.5
            OR VANG(SHIP:FACING:FOREVECTOR,steeringTarget) >= 8 {
        thrustCutoffOk(). UNLOCK STEERING.
        PRINT "HOP held: ignition alignment not achieved.".
        yieldToPrompt(). RETURN.
    }
    IF SHIP:MAXTHRUST <= 0 {
        PRINT "HOP failed: no thrust available.".
        mLogError("HOP failed: no thrust available.").
        IF NOT thrustCutoffOk() { RETURN FALSE. }
        UNLOCK STEERING.
        RETURN.
    }

    LOCAL burnStart IS TIME:SECONDS.
    LOCAL nextLog IS TIME:SECONDS.
    LOCAL bestDist IS 999999.
    LOCAL bestLat IS 0.
    LOCAL bestLng IS 0.
    LOCAL bestTime IS TIME:SECONDS.
    LOCAL reason IS "operator abort".
    LOCAL abortedHop IS FALSE.
    LOCAL done IS FALSE.
    LOCAL thrustLimits IS _hopCaptureThrustLimits().
    stateSet("hop_thrust_limits",thrustLimits).
    LOCAL targetTotalTwr IS _hopTuneThrustLimit().

    mLog("HOP thrust limiter: targetVerticalTwr=" + ROUND(HOP_TWR, 2)
        + " targetTotalTwr=" + ROUND(targetTotalTwr, 2)
        + " avgLimit=" + ROUND(_hopAverageThrustLimit(), 1)
        + "% twr=" + ROUND(shipTwr(), 2) + ".").

    stateSet("hop_inflight",TRUE).
    LOCAL hopThrottle IS 0.
    LOCK THROTTLE TO hopThrottle.

    UNTIL done {
        SET steeringTarget TO _hopSteer().
        _hopTuneThrustLimit().
        SET hopThrottle TO 0.
        IF NOT ABORT AND VANG(SHIP:FACING:FOREVECTOR,steeringTarget) < 8
                AND VDOT(SHIP:FACING:FOREVECTOR,SHIP:UP:VECTOR) > 0 {
            SET hopThrottle TO 1.
        }
        LOCAL landingBudget IS HOP_LANDING_RESERVE_DV
            + 1.5*SHIP:VELOCITY:SURFACE:MAG.
        IF SHIP:DELTAV:VACUUM <= HOP_RETURN_RESERVE_DV+landingBudget {
            SET reason TO "return and landing reserve". SET done TO TRUE. SET hopThrottle TO 0.
        }
        IF vesselLandingThrust() <= 0 {
            SET reason TO "no permitted thrust". SET done TO TRUE. SET hopThrottle TO 0.
        }

        IF ABORT {
            SET reason TO "operator abort".
            SET abortedHop TO TRUE.
            SET done TO TRUE.
        }

        LOCAL impactDist IS 999999.
        IF ADDONS:TR:HASIMPACT {
            LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
            SET impactDist TO geoDistance(impactPos:LAT, impactPos:LNG,
                HOP_TARGET_LAT, HOP_TARGET_LNG).
            IF impactDist < bestDist {
                SET bestDist TO impactDist.
                SET bestLat TO impactPos:LAT.
                SET bestLng TO impactPos:LNG.
                SET bestTime TO TIME:SECONDS.
            }

            IF impactDist <= HOP_TOLERANCE AND TIME:SECONDS - burnStart > 1 {
                SET reason TO "impact within tolerance".
                SET done TO TRUE.
            } ELSE IF bestDist < startDist
                    AND impactDist > bestDist + MAX(250, HOP_TOLERANCE)
                    AND TIME:SECONDS - bestTime > 0.5
                    AND TIME:SECONDS - burnStart > 2 {
                SET reason TO "impact diverging after best".
                SET done TO TRUE.
            } ELSE IF bestDist <= HOP_TOLERANCE * 2
                    AND impactDist > bestDist * 1.25
                    AND TIME:SECONDS - burnStart > 5 {
                SET reason TO "passed best impact".
                SET done TO TRUE.
            }
        }

        IF SHIP:APOAPSIS >= maxAp {
            SET reason TO "max apoapsis".
            SET done TO TRUE.
        } ELSE IF TIME:SECONDS - burnStart >= HOP_MAX_BURN_SECONDS {
            SET reason TO "max burn time".
            SET done TO TRUE.
        }

        IF TIME:SECONDS >= nextLog {
            SET nextLog TO TIME:SECONDS + 2.
            mLog("HOP burn: t=" + ROUND(TIME:SECONDS - burnStart, 1)
                + "s Ap=" + ROUND(SHIP:APOAPSIS / 1000, 1)
                + "km impact=" + ROUND(impactDist, 0)
                + "m best=" + ROUND(bestDist, 0)
                + "m twr=" + ROUND(shipTwr(), 2)
                + " lim=" + ROUND(_hopAverageThrustLimit(), 1)
                + "% align=" + ROUND(VANG(SHIP:FACING:FOREVECTOR,
                    steeringTarget), 1) + "deg.").
        }

        WAIT 0.1.
    }

    LOCAL stopped IS thrustCutoffOk().
    IF NOT stopped { RETURN. }
    _hopRestoreSavedLimits().

    mLog("STATS hop cutoff reason=" + reason
        + " burn=" + ROUND(TIME:SECONDS - burnStart, 1)
        + " bestDist=" + ROUND(bestDist, 0)
        + " best=" + ROUND(bestLat, 5) + "," + ROUND(bestLng, 5)
        + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)
        + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)).

    IF abortedHop {
        IF stateGet("hop_route_active",FALSE) AND SHIP:BODY:NAME <> stateGet("hop_route_body","") {
        PRINT "HOP held: route belongs to a different body.". yieldToPrompt(). RETURN.
    }
    stateSet("phase", "HOP").
        stateSet("lib_band", "HOP").
        stateSet("reload_required", "false").
        PRINT "HOP aborted; holding HOP phase.".
        mLogError("HOP aborted by operator; holding HOP phase. Clear ABORT before resuming.").
        RETURN.
    }

    PRINT "HOP cutoff: " + reason + ".".
    PRINT "Best impact miss: " + ROUND(bestDist, 0) + " m.".
    PRINT "Rebooting into LAND_ASSIST.".

    _hopPrepLandingAssist().
    REBOOT.
}
