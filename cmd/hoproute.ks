// Plan a local airless rocket-hop route, retaining the current return mission.
// Stops after EVERY touchdown for operator science/review. No ignition here.
// RUNPATH("0:/cmd/hoproute.ks", LIST(LIST(lat1,lng1),LIST(lat2,lng2)), 700).
@LAZYGLOBAL OFF.
PARAMETER sites.
PARAMETER returnReserveDv IS 700.
PARAMETER toleranceM IS 750.
PARAMETER pitchDeg IS 45.
PARAMETER maxBurnSeconds IS 90.
PARAMETER maxApKm IS 5.
PARAMETER hopTwr IS 2.5.

LOCAL FUNCTION _cmdHoproute {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF ABORT OR SHIP:STATUS <> "LANDED" OR SHIP:BODY:ATM:EXISTS OR HASNODE
            OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Hop route requires airless surface contact, no node, Abort clear and all throttles off.".
        RETURN.
    }
    IF sites:LENGTH = 0 OR sites:LENGTH > 16 OR returnReserveDv < 0
            OR toleranceM < 50 OR pitchDeg < 20 OR pitchDeg > 80
            OR maxBurnSeconds <= 0 OR maxApKm <= 0 OR hopTwr <= 1 {
        PRINT "Invalid route or limits; use 1-16 sites, positive limits, pitch 20-80 and vertical TWR >1.".
        RETURN.
    }
    FOR site IN sites {
        IF site:LENGTH <> 2 { PRINT "Each site must be LIST(latitude,longitude).". RETURN. }
        IF ABS(site[0]) > 90 OR ABS(site[1]) > 180 { PRINT "Invalid latitude/longitude.". RETURN. }
    }
    bootLibLoad("hop").
    // Load defaults before applying the selected mission so its floor,
    // return settings and unrelated overrides win. Do not replace its ID.
    IF NOT bootApplyMissionConfig(stateGet("vehicle",""),stateGet("mission_id",""),HOMECONNECTION:ISCONNECTED) {
        PRINT "Current mission unavailable; no hop route saved.". RETURN.
    }
    IF stateGet("hop_route_active",FALSE) {
        PRINT "A route is already active; finish it with R at landing review before replacing it.". RETURN.
    }
    IF SEQUENCE:LENGTH = 0 { PRINT "Current mission has no return/finish sequence to preserve.". RETURN. }
    IF NOT vesselLandingPrepareRoles() { PRINT "Invalid landing/return stage roles.". RETURN. }
    LOCAL distance IS geoDistance(SHIP:LATITUDE,SHIP:LONGITUDE,sites[0][0],sites[0][1]).
    SET HOP_PITCH TO pitchDeg.
    SET HOP_RETURN_RESERVE_DV TO returnReserveDv.
    IF distance > SHIP:BODY:RADIUS*0.25 OR NOT hopRouteFuelOk(distance) {
        PRINT "First hop exceeds the local range or launch/landing/return fuel budget; nothing saved.". RETURN.
    }
    LOCAL previousLat IS SHIP:LATITUDE.
    LOCAL previousLng IS SHIP:LONGITUDE.
    FOR site IN sites {
        LOCAL legRange IS geoDistance(previousLat,previousLng,site[0],site[1]).
        IF legRange > SHIP:BODY:RADIUS*0.25 {
            PRINT "Route contains a leg beyond the local hop range; nothing saved.". RETURN.
        }
        LOCAL grade IS landingTerrainGrade(site[0],site[1],20).
        IF grade > TAN(LANDING_TERRAIN_MAX_SLOPE) {
            PRINT "Route site exceeds the normal landing slope limit; nothing saved.". RETURN.
        }
        SET previousLat TO site[0]. SET previousLng TO site[1].
    }
    LOCAL restore IS LEXICON("SEQUENCE",SEQUENCE,"TARGET_LAT",TARGET_LAT,"TARGET_LNG",TARGET_LNG,
        "TARGET_LOCK",TARGET_LOCK,"TARGET_WAYPOINT",TARGET_WAYPOINT,
        "LANDING_USE_WAYPOINTS",LANDING_USE_WAYPOINTS,"LANDING_FLEXIBLE_SITE",LANDING_FLEXIBLE_SITE,
        "LANDING_ECONOMY_BRAKE",LANDING_ECONOMY_BRAKE,"LANDING_STAGE_BRAKE_CREDIT",LANDING_STAGE_BRAKE_CREDIT,
        "LANDING_POWERED_LEAD",LANDING_POWERED_LEAD,"LANDING_STAGE_DISCARD_HSPEED",LANDING_STAGE_DISCARD_HSPEED,
        "RELOAD_AFTER_LAND_ASSIST",RELOAD_AFTER_LAND_ASSIST).
    stateSet("hop_route_restore",restore).
    stateSet("hop_route_sites",sites).
    stateSet("hop_route_index",0).
    stateRemove("hop_route_pending").
    stateSet("hop_route_body",SHIP:BODY:NAME).
    stateSet("hop_route_active",TRUE).
    stateSet("hop_inflight",FALSE).
    missionOverrideUpdate(LEXICON("SEQUENCE",LIST("HOP","LAND_ASSIST","HOP_REVIEW"),
        "HOP_TARGET_LAT",sites[0][0],"HOP_TARGET_LNG",sites[0][1],"HOP_TOLERANCE",toleranceM,
        "HOP_PITCH",pitchDeg,"HOP_MAX_BURN_SECONDS",maxBurnSeconds,"HOP_MAX_AP_KM",maxApKm,
        "HOP_TWR",hopTwr,"HOP_RETURN_RESERVE_DV",returnReserveDv)).
    stateSaveReloadState("HOP_ROUTE_ARMED","HOP","HOP").
    PRINT "Route saved; return mission retained. Review sites/limits before REBOOT. to launch.".
    PRINT "Every landing waits for N (next hop) or R (finish hops/resume return).".
}

_cmdHoproute().
