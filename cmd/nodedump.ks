// cmd/nodedump.ks - Print current maneuver node components.
// Usage: RUNPATH("0:/cmd/nodedump.ks").

IF NOT HASNODE {
    PRINT "No maneuver node.".
    RETURN.
}

LOCAL nd IS NEXTNODE.
PRINT "NODE DUMP".
PRINT "  ETA      " + ROUND(nd:ETA,3) + " s".
PRINT "  TIME     " + ROUND(nd:TIME,3).
PRINT "  dV       " + ROUND(nd:DELTAV:MAG,6) + " m/s".
PRINT "  PRO      " + ROUND(nd:PROGRADE,6).
PRINT "  NORM     " + ROUND(nd:NORMAL,6).
PRINT "  RAD      " + ROUND(nd:RADIALOUT,6).
PRINT "  BV mag   " + ROUND(nd:BURNVECTOR:MAG,6).
PRINT "  Pe/Ap    " + ROUND(SHIP:PERIAPSIS/1000,3)
    + " / " + ROUND(SHIP:APOAPSIS/1000,3) + " km".
