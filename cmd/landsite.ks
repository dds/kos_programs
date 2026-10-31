// Choose a surveyed site from LANDING_REVIEW; no node or burn is created here.
// RUNPATH("0:/cmd/landsite.ks").  // selected waypoint
// RUNPATH("0:/cmd/landsite.ks",LEXICON("lat",12.3,"lng",45.6)).
@LAZYGLOBAL OFF.
PARAMETER opts IS LEXICON().

LOCAL FUNCTION _cmdLandsite {
    IF NOT opts:ISTYPE("Lexicon") { PRINT "Use a lat/lng lexicon, or no arguments for a selected waypoint.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("landing_review").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mid IS stateGet("mission_id","").
    IF vehicle = "" OR mid = "" { PRINT "No selected mission; nothing changed.". RETURN. }
    IF NOT bootApplyMissionConfig(vehicle,mid,HOMECONNECTION:ISCONNECTED) { RETURN. }
    IF stateGet("phase","") <> "LANDING_REVIEW" OR NOT landingReviewOrbitSafe() OR HASNODE {
        PRINT "Choose the site from safe idle LANDING_REVIEW with no existing/interrupted maneuver.". RETURN.
    }
    FOR key IN opts:KEYS {
        IF key <> "lat" AND key <> "lng" { PRINT "Use only lat/lng keys, or no arguments for a selected waypoint.". RETURN. }
    }
    LOCAL lat IS 999.
    LOCAL lng IS 999.
    IF opts:HASKEY("lat") AND opts:HASKEY("lng") {
        SET lat TO opts["lat"]. SET lng TO opts["lng"].
    } ELSE IF NOT opts:HASKEY("lat") AND NOT opts:HASKEY("lng") {
        LOCAL wp IS selectedWaypoint().
        IF wp <> 0 {
            SET lat TO wp:GEOPOSITION:LAT. SET lng TO wp:GEOPOSITION:LNG.
        }
    }
    IF NOT lat:ISTYPE("Scalar") OR NOT lng:ISTYPE("Scalar") {
        PRINT "Coordinates must be numeric degrees; nothing changed.". RETURN.
    }
    IF NOT (ABS(lat) <= 90 AND ABS(lng) <= 180) {
        PRINT "Supply both lat/lng in degrees, or select a waypoint on the current body. Nothing changed.". RETURN.
    }
    IF ABS(lat) > MIN(SHIP:ORBIT:INCLINATION,180-SHIP:ORBIT:INCLINATION)+0.5 {
        PRINT "Target latitude is outside this orbit's reach. Adjust the plane or select another site.". RETURN.
    }
    LOCAL next IS "LAND_DEORBIT".
    IF SHIP:BODY:ATM:EXISTS {
        SET next TO "ATMO_DEORBIT".
        LOCAL ready IS entryLandingPreflight().
        IF NOT ready["OK"] { PRINT "Powered landing hardware/fuel check failed: " + ready["REASON"]. RETURN. }
    }
    IF NOT SEQUENCE:CONTAINS(next) { PRINT "This mission has no matching landing phase; nothing changed.". RETURN. }
    IF NOT landingReviewOrbitSafe() OR HASNODE { PRINT "Vehicle state changed; nothing applied.". RETURN. }
    missionOverrideUpdate(LEXICON("TARGET_LAT",lat,"TARGET_LNG",lng,"TARGET_LOCK",1,
        "TARGET_WAYPOINT","","LANDING_USE_WAYPOINTS",0,"LANDING_AUTO_TARGET",0,
        "LANDING_FLEXIBLE_SITE",0,"LANDING_ECONOMY_TERMINAL_RETARGET",0)).
    stateSet("landing_site_context",landingOrbitContext()).
    stateSet("phase",next).
    PRINT "Landing site saved: " + lat + "," + lng + "; next=" + next + ". No burn started.".
    PRINT "REBOOT. to plan the targeted deorbit; light/radio/fuel checks remain in force.".
}

_cmdLandsite().
