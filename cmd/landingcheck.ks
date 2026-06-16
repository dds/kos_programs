// cmd/landingcheck.ks - Print landing readiness from the active vessel.
// Usage: RUNPATH("0:/cmd/landingcheck.ks").

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL radiusMag IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
LOCAL grav IS SHIP:BODY:MU / (radiusMag * radiusMag).
LOCAL maxAcc IS 0.
IF SHIP:MASS > 0 {
    SET maxAcc TO SHIP:AVAILABLETHRUST / SHIP:MASS.
}

PRINT "LANDING CHECK".
PRINT "  Vessel   " + SHIP:NAME.
PRINT "  Body     " + SHIP:BODY:NAME + "  status=" + SHIP:STATUS.
PRINT "  Orbit    Pe=" + ROUND(SHIP:PERIAPSIS/1000,2)
    + " Ap=" + ROUND(SHIP:APOAPSIS/1000,2)
    + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2).
PRINT "  Surface  radar=" + ROUND(ALT:RADAR,1)
    + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,2)
    + " v=" + ROUND(SHIP:VERTICALSPEED,2).
PRINT "  Thrust   mass=" + ROUND(SHIP:MASS,3)
    + "t avail=" + ROUND(SHIP:AVAILABLETHRUST,2)
    + "kN TWR=" + ROUND(maxAcc / grav,2).
PRINT "  Attitude pitch=" + ROUND(SHIP:FACING:PITCH,1)
    + " roll=" + ROUND(SHIP:FACING:ROLL,1).

LOCAL selected IS 0.
FOR wp IN ALLWAYPOINTS() {
    IF wp:ISSELECTED {
        IF wp:BODY:NAME = SHIP:BODY:NAME {
            SET selected TO wp.
            BREAK.
        }
    }
}
IF selected <> 0 {
    LOCAL reachInc IS SHIP:ORBIT:INCLINATION.
    IF reachInc > 90 { SET reachInc TO 180 - reachInc. }
    PRINT "  Target   selected waypoint: " + selected:NAME.
    PRINT "           lat=" + ROUND(selected:GEOPOSITION:LAT,4)
        + " lng=" + ROUND(selected:GEOPOSITION:LNG,4).
    PRINT "           reachableLat=" + (ABS(selected:GEOPOSITION:LAT) <= reachInc + 0.5)
        + " orbitLatLimit=" + ROUND(reachInc,2).
} ELSE {
    PRINT "  Target   no selected waypoint on " + SHIP:BODY:NAME + ".".
}

LOCAL assistTag IS "landing_assist_decoupler".
LOCAL decouplers IS SHIP:PARTSTAGGED(assistTag).
PRINT "  Assist   decouplers tagged " + assistTag + "=" + decouplers:LENGTH.
PRINT "  Addons   TR=" + ADDONS:TR:AVAILABLE
    + " KE=" + ADDONS:KE:AVAILABLE
    + " SCANsat=" + ADDONS:SCANSAT:AVAILABLE.

IF HASNODE {
    PRINT "  Node     dV=" + ROUND(NEXTNODE:DELTAV:MAG,2)
        + " ETA=" + ROUND(NEXTNODE:ETA,1).
} ELSE {
    PRINT "  Node     none".
}
