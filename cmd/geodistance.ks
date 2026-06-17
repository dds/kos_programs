// cmd/geodistance.ks - Surface great-circle distance on the current body.
//
// Usage:
//   RUNPATH("0:/cmd/geodistance.ks", lat1, lng1, lat2, lng2).
//   RUNPATH("0:/cmd/geodistance.ks", -0.10, -74.25, 12.5, -38.7).

PARAMETER lat1.
PARAMETER lng1.
PARAMETER lat2.
PARAMETER lng2.

RUNPATH("1:/lib/boot_lib").
bootLibLoad("utils").

LOCAL bodyName IS SHIP:BODY:NAME.
LOCAL distM IS geoDistance(lat1, lng1, lat2, lng2).

PRINT " ".
PRINT "  GEO DISTANCE".
PRINT "  Body   " + bodyName + "  radius=" + ROUND(SHIP:BODY:RADIUS / 1000, 1) + " km".
PRINT "  From   lat=" + ROUND(lat1, 5) + " lng=" + ROUND(lng1, 5).
PRINT "  To     lat=" + ROUND(lat2, 5) + " lng=" + ROUND(lng2, 5).
PRINT "  Dist   " + ROUND(distM, 1) + " m  (" + ROUND(distM / 1000, 3) + " km)".
