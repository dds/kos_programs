// Select a surface ascent -> specified orbit -> review -> Kerbin return.
// Metres ASL/degrees. Reads the live body/position; no landing-site coordinates.
// RUNPATH("0:/cmd/surfaceorbit.ks",659734,554472,0,0.4). then REBOOT.
@LAZYGLOBAL OFF.
PARAMETER apoapsis.
PARAMETER periapsis.
PARAMETER inclination IS 0.
PARAMETER argumentOfPe IS -1.
PARAMETER longitudeOfAN IS -1.

LOCAL FUNCTION _cmdSurfaceorbit {
    IF ABORT OR HASNODE OR SHIP:STATUS <> "LANDED" OR SHIP:BODY:ATM:EXISTS
            OR (SHIP:BODY:NAME <> "Mun" AND SHIP:BODY:NAME <> "Minmus")
            OR SHIP:VELOCITY:SURFACE:MAG > 0.5 OR SHIP:THRUST > 0.001
            OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Surface orbit requires a settled Mun/Minmus landing, idle controls, no node and Abort clear.".
        RETURN.
    }
    IF NOT (periapsis >= 10000 AND apoapsis >= periapsis
            AND apoapsis < SHIP:BODY:SOIRADIUS-SHIP:BODY:RADIUS
            AND inclination >= 0 AND inclination <= 180
            AND (argumentOfPe = -1 OR (argumentOfPe >= 0 AND argumentOfPe < 360))
            AND (longitudeOfAN = -1 OR (longitudeOfAN >= 0 AND longitudeOfAN < 360))) {
        PRINT "Invalid bound orbit: use Ap>=Pe>=10000m inside this body's SOI, inclination0..180, angles0..<360 or-1.".
        RETURN.
    }
    IF HOMECONNECTION:ISCONNECTED AND EXISTS("0:/lib/boot_lib.ks") {
        RUNPATH("0:/lib/boot_lib.ks").
    } ELSE { RUNPATH("1:/lib/boot_lib"). }
    bootPruneLandedHopCache().
    bootPreamble().
    // RUNONCEPATH can retain the previous serializer at a live prompt.
    // Refresh its function-only source before persisting the orbit lexicon.
    IF HOMECONNECTION:ISCONNECTED AND EXISTS("0:/lib/config.ks") {
        RUNPATH("0:/lib/config.ks").
    }
    // Only the route/settings helpers are needed now. The next reboot
    // loads return_setup by band, rather than crowding this surface boot.
    bootLibLoad("hop").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mission IS stateGet("mission_id","").
    IF vehicle = "" OR mission = "" {
        PRINT "Original craft/mission unavailable; no ascent selected.". RETURN.
    }
    bootLibLoad("craft/"+vehicle).
    IF NOT bootApplyMissionConfig(vehicle,mission,HOMECONNECTION:ISCONNECTED) { RETURN. }
    IF NOT vesselLandingPrepareRoles() { RETURN. }
    IF stateGet("hop_route_active",FALSE) {
        IF stateGet("hop_route_body","") <> SHIP:BODY:NAME
                OR stateGet("hop_route_restore",LEXICON()):LENGTH = 0 {
            PRINT "Saved route body/settings mismatch; route retained.". RETURN.
        }
        stateSet("phase",hopReviewPhase()).
        hopFinishRoute(FALSE).
        IF stateGet("hop_route_active",FALSE) { RETURN. }
    }
    _hopRestoreSavedLimits().
    LOCAL orbit IS LEXICON(
        "AP",apoapsis,"PE",periapsis,"INC",inclination,"LAN",longitudeOfAN,"AOP",argumentOfPe,
        "ALT_TOL",100,"ANG_TOL",0.1,"AOP_TOL",0.2,
        "MIN_BURN_DV",0.002,"BURN_TOLERANCE",0.001,"MIN_PE",10000,
        "DV_CAP",150,"TOTAL_DV_CAP",250,"RESERVE_DV",300).
    // Preserve the mission's configured caps, reserve and precision.
    IF DEFINED SURFACE_RETURN_ORBIT {
        FOR key IN SURFACE_RETURN_ORBIT:KEYS {
            IF key <> "AP" AND key <> "PE" AND key <> "INC" AND key <> "LAN" AND key <> "AOP" {
                SET orbit[key] TO SURFACE_RETURN_ORBIT[key].
            }
        }
    }
    missionOverrideUpdate(LEXICON("SURFACE_RETURN_ORBIT",orbit,
        "SURFACE_RETURN_INCLINATION",inclination,"SURFACE_RETURN_REVIEW",1,
        "SURFACE_RETURN_SEQUENCE",LIST("PRELAUNCH","LAUNCH","PARK","SHAPE","SCIENCE_OPS","RETURN_SETUP"))).
    stateSaveReloadState("SURFACE_ORBIT_SELECTED","SURFACE_RETURN_SETUP","RETURN_SETUP").
    PRINT "Surface orbit selected: Ap="+apoapsis+" Pe="+periapsis+" Inc="+inclination+" AoP="+argumentOfPe+" LAN="+longitudeOfAN+".".
    PRINT "REBOOT. when ready: ascent, orbital shaping, then manual SCIENCE_OPS review before Kerbin departure.".
}

_cmdSurfaceorbit().
