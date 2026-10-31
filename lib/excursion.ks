// Command-selected local operations. Reuse flight phases; never burn here.
@LAZYGLOBAL OFF.

GLOBAL EXCURSION_RESERVE_DV IS 300.

GLOBAL FUNCTION excursionIdle {
    RETURN MISSION_EXCURSIONS > 0 AND SHIP = KUNIVERSE:ACTIVEVESSEL AND NOT ABORT
        AND WARP = 0 AND NOT HASNODE AND SHIP:BODY:NAME = getTarget()
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0
        AND stateGet("burn_pending","false") <> "true"
        AND stateGet("burn_started","false") <> "true"
        AND stateGet("deorbit_burn_started","false") <> "true"
        AND NOT stateGet("hop_route_active",FALSE)
        AND LIST("DONE","SCIENCE_OPS","SCANSAT_OPS","LANDING_REVIEW","SURFACE_REVIEW"):CONTAINS(stateGet("phase","")).
}

GLOBAL FUNCTION excursionOrbitSafe {
    RETURN SHIP:STATUS = "ORBITING" AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND SHIP:PERIAPSIS > 0 AND SHIP:PERIAPSIS < 1e30
        AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1.
}

// opts: ap/pe/inc/lan/aop (metres/degrees), after=review|scan; visit uses lat/lng.
GLOBAL FUNCTION excursionSelect {
    PARAMETER opts.
    PARAMETER visit.
    IF NOT opts:ISTYPE("Lexicon") { RETURN FALSE. }
    IF NOT excursionIdle() OR SHIP:BODY:ATM:EXISTS {
        PRINT "Local excursions require an enabled airless mission at an idle review/DONE prompt, no node or interrupted burn, Abort clear.".
        RETURN FALSE.
    }
    LOCAL surface IS SHIP:STATUS = "LANDED" AND SHIP:VELOCITY:SURFACE:MAG <= 0.5.
    IF NOT surface AND NOT excursionOrbitSafe() { PRINT "A settled landing or safe bound orbit is required.". RETURN FALSE. }
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { RETURN FALSE. }
    FOR key IN opts:KEYS {
        IF (visit AND key <> "lat" AND key <> "lng")
                OR (NOT visit AND NOT LIST("ap","pe","inc","lan","aop","after"):CONTAINS(key)) {
            PRINT "Unknown excursion option: " + key + ". Nothing changed.". RETURN FALSE.
        }
    }
    LOCAL ap IS 70000.
    LOCAL pe IS 70000.
    LOCAL inc IS 90.
    LOCAL lan IS -1.
    LOCAL aop IS -1.
    LOCAL after IS "review".
    LOCAL lat IS 999.
    LOCAL lng IS 999.
    IF visit {
        IF opts:HASKEY("lat") AND opts:HASKEY("lng") {
            SET lat TO opts["lat"]. SET lng TO opts["lng"].
        } ELSE IF opts:LENGTH = 0 {
            LOCAL wp IS selectedWaypoint().
            IF wp <> 0 { SET lat TO wp:GEOPOSITION:LAT. SET lng TO wp:GEOPOSITION:LNG. }
        }
        IF NOT lat:ISTYPE("Scalar") OR NOT lng:ISTYPE("Scalar") { RETURN FALSE. }
        IF NOT (ABS(lat) <= 90 AND ABS(lng) <= 180) {
            PRINT "Select a waypoint on this body, or supply both lat/lng in degrees.". RETURN FALSE.
        }
        SET ap TO 15000. SET pe TO 15000.
    } ELSE {
        FOR key IN opts:KEYS {
            IF key <> "after" AND NOT opts[key]:ISTYPE("Scalar") { PRINT "Orbit elements must be numbers.". RETURN FALSE. }
        }
        IF opts:HASKEY("ap") { SET ap TO opts["ap"]. }
        IF opts:HASKEY("pe") { SET pe TO opts["pe"]. }
        IF opts:HASKEY("inc") { SET inc TO opts["inc"]. }
        IF opts:HASKEY("lan") { SET lan TO opts["lan"]. }
        IF opts:HASKEY("aop") { SET aop TO opts["aop"]. }
        IF opts:HASKEY("after") { SET after TO opts["after"]. }
    }
    IF NOT (pe >= 10000 AND ap >= pe AND ap < SHIP:BODY:SOIRADIUS-SHIP:BODY:RADIUS
            AND inc >= 0 AND inc <= 180 AND (lan = -1 OR (lan >= 0 AND lan < 360))
            AND (aop = -1 OR (aop >= 0 AND aop < 360))
            AND (after = "review" OR after = "scan")
            AND EXCURSION_RESERVE_DV >= 0 AND EXCURSION_RESERVE_DV < 1e30) {
        PRINT "Invalid bound orbit or reserve. Use Ap>=Pe>=10000m, inc0..180 and angles0..<360 (-1 unconstrained).". RETURN FALSE.
    }
    // No future engine/fuel credit. Ascent guidance and each later planner
    // still validate live authority, terrain, budgets and target reachability.
    IF surface {
        IF NOT (SHIP:MASS > 0 AND SHIP:MASS < 1e30 AND SHIP:ALTITUDE > -SHIP:BODY:RADIUS
                AND SHIP:ALTITUDE < 1e30 AND SHIP:BODY:MU > 0 AND SHIP:BODY:MU < 1e30) { RETURN FALSE. }
        LOCAL ascentNeed IS SQRT(SHIP:BODY:MU/(SHIP:BODY:RADIUS+15000))+200.
        LOCAL grav IS SHIP:BODY:MU/(SHIP:BODY:RADIUS+SHIP:ALTITUDE)^2.
        IF NOT (SHIP:AVAILABLETHRUST/SHIP:MASS > 1.2*grav
                AND STAGE:DELTAV:VACUUM >= ascentNeed+EXCURSION_RESERVE_DV) {
            PRINT "Current propulsion cannot cover ascent plus the excursion reserve. No launch selected.". RETURN FALSE.
        }
    }
    IF NOT (SHIP:DELTAV:VACUUM > EXCURSION_RESERVE_DV) { RETURN FALSE. }
    LOCAL seq IS LIST("EXCURSION_READY","SHAPE","SCIENCE_OPS","DONE").
    IF after = "scan" { SET seq TO LIST("EXCURSION_READY","SHAPE","SCANSAT_OPS","DONE"). }
    IF visit { SET seq TO LIST("EXCURSION_READY","SHAPE","LAND_DEORBIT","LAND_ASSIST","SURFACE_SCIENCE","DONE"). }
    // A return-capable surface campaign keeps its original return policy.
    // Selecting another site must not silently replace that tail with DONE.
    LOCAL returnMission IS SEQUENCE:CONTAINS("SURFACE_RETURN_SETUP") OR SEQUENCE:CONTAINS("RETURN_SETUP").
    IF visit AND returnMission {
        SET seq TO LIST("EXCURSION_READY","SHAPE","LAND_DEORBIT","LAND_ASSIST",
            "SURFACE_SCIENCE","SURFACE_REVIEW","SURFACE_RETURN_SETUP").
    }
    IF NOT visit AND returnMission {
        SET seq TO LIST("EXCURSION_READY","SHAPE","SCIENCE_OPS","RETURN_SETUP").
        IF after = "scan" { SET seq TO LIST("EXCURSION_READY","SHAPE","SCANSAT_OPS","RETURN_SETUP"). }
    }
    IF surface {
        LOCAL ascentSeq IS LIST("PRELAUNCH","LAUNCH","PARK").
        FOR phaseName IN seq { ascentSeq:ADD(phaseName). }
        SET seq TO ascentSeq.
    }
    LOCAL values IS LEXICON("SEQUENCE",seq,"MISSION_CACHE_NEXT_BAND",1,
        "SHAPE_AP",ap,"SHAPE_PE",pe,"SHAPE_INC",inc,"SHAPE_LAN",lan,"SHAPE_AOP",aop,
        "SCIENCE_OPS_HOLD",1,"SCIENCE_OPS_RUN_ALL",0,
        "SCANSAT_DECOUPLER_TAG","","SCANSAT_DISPOSE_CARRIER",0,"SCANSAT_AUTO_DEORBIT",0,
        "SCANSAT_DISPOSE_BEFORE_RELEASE",0,"SCANSAT_STAGE_AFTER_RELEASE",0).
    IF after = "scan" {
        SET values["SCANSAT_POWER_GUARD"] TO 1.
        SET values["SCANSAT_POWER_LOW"] TO 0.3.
        SET values["SCANSAT_POWER_RESUME"] TO 0.6.
    }
    IF surface {
        SET values["PARKING_ALT"] TO 15000.
        SET values["LAUNCH_INCLINATION"] TO inc.
        SET values["LAUNCH_PLANE_MODE"] TO "".
        SET values["CAPTURE_LAN"] TO -1.
        SET values["ASCENT_STAGED"] TO FALSE.
    }
    LOCAL visitId IS stateGetNum("surface_visit",0).
    IF visit {
        SET visitId TO visitId+1.
        SET values["TARGET_LAT"] TO lat. SET values["TARGET_LNG"] TO lng.
        SET values["TARGET_LOCK"] TO 1. SET values["TARGET_WAYPOINT"] TO "".
        SET values["LANDING_USE_WAYPOINTS"] TO 0. SET values["LANDING_AUTO_TARGET"] TO 0.
        SET values["LANDING_FLEXIBLE_SITE"] TO 0. SET values["LANDING_ECONOMY_TERMINAL_RETARGET"] TO 0.
    }
    // Recheck immediately before persistence. Existing mission identity,
    // science records, fuel ledgers and unrelated overrides are retained.
    IF NOT excursionIdle() OR stateGet("vehicle","") <> vehicle OR stateGet("mission_id","") <> mid
            OR (surface AND (SHIP:STATUS <> "LANDED" OR NOT (SHIP:VELOCITY:SURFACE:MAG <= 0.5)))
            OR (NOT surface AND NOT excursionOrbitSafe()) { RETURN FALSE. }
    LOCAL context IS LEXICON("BODY",SHIP:BODY:NAME,"MISSION",mid,"VEHICLE",vehicle,
        "LAUNCH_TIME",stateGetNum("launch_time",0),"VISIT",visit,"SITE",visitId,"READY",FALSE).
    missionOverrideUpdate(values).
    stateSet("excursion",context).
    stateSaveReloadState("LOCAL_EXCURSION_SELECTED",seq[0],phaseBandForPhase(seq[0])).
    PRINT "Excursion saved; REBOOT. to run existing flight phases. No node created or burn started.".
    RETURN TRUE.
}

GLOBAL FUNCTION phaseExcursionReady {
    LOCAL context IS stateGet("excursion",LEXICON()).
    FOR key IN LIST("BODY","MISSION","VEHICLE","LAUNCH_TIME","VISIT","SITE","READY") {
        IF NOT context:HASKEY(key) { mLogError("Missing excursion checkpoint; mission retained."). yieldToPrompt(). RETURN. }
    }
    IF MISSION_EXCURSIONS <= 0 OR context["BODY"] <> SHIP:BODY:NAME OR SHIP:BODY:ATM:EXISTS
            OR context["MISSION"] <> stateGet("mission_id","")
            OR context["VEHICLE"] <> stateGet("vehicle","") OR NOT excursionOrbitSafe()
            OR ABORT OR HASNODE OR WARP <> 0 OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0
            OR stateGet("burn_pending","false") = "true" OR stateGet("burn_started","false") = "true"
            OR stateGet("deorbit_burn_started","false") = "true" {
        mLogError("Excursion checkpoint requires the saved mission and safe idle orbit; intent retained.").
        yieldToPrompt(). RETURN.
    }
    IF NOT thrustCutoffOk() { RETURN. }
    IF NOT context["READY"] {
        stateSet("excursion_liftoff",stateGetNum("launch_time",0)).
        // Ascent uses its own actual liftoff clock. Restore the mission epoch
        // before SHAPE so a local relaunch cannot reset its fuel ledger.
        stateSet("launch_time",context["LAUNCH_TIME"]).
        IF context["VISIT"] { stateSet("surface_visit",context["SITE"]). }
        SET context TO context:COPY.
        SET context["READY"] TO TRUE.
        stateSet("excursion",context).
    }
    IF context["VISIT"] { stateSet("landing_site_context",landingOrbitContext()). }
    mLogSummary("STATS excursion ready visit=" + context["VISIT"] + " site=" + context["SITE"]
        + " remainingDv=" + SHIP:DELTAV:VACUUM + " missionEpoch=" + stateGetNum("launch_time",0)).
    nextPhase(launchSeq).
}
