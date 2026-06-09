// cmd/airnav.ks - Load selected waypoint and start aircraft waypoint nav.
// Usage: select a waypoint in Waypoint Manager, then RUNPATH("1:/cmd/airnav.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("airplane").

IF waypointUseSelected(CFG["CRUISE_ALT"]) {
    wptNavOn().
    planeStatus().
} ELSE {
    PRINT "No selected waypoint on " + SHIP:BODY:NAME + ".".
}
