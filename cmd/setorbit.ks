// cmd/setorbit.ks - Raise/lower into a circular orbit at target altitude.
// Usage: RUNPATH("0:/cmd/setorbit.ks", 72).  // km

PARAMETER targetKm IS 72.

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("maneuver").

LOCAL targetAlt IS targetKm * 1000.
IF targetKm > 1000 { SET targetAlt TO targetKm. }

LOCAL FUNCTION _planSetApAtPe {
    PARAMETER alt_.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL burnTime IS TIME:SECONDS + ETA:PERIAPSIS.
    LOCAL rBurn IS bodyR + SHIP:PERIAPSIS.
    LOCAL rTarget IS bodyR + alt_.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
    ADD nd.
    mLog("Set Ap node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetAp=" + ROUND(alt_/1000,1) + "km").
    maneuverUiArchiveLog("set-orbit-ap").
}

LOCAL FUNCTION _planSetPeAtAp {
    PARAMETER alt_.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL burnTime IS TIME:SECONDS + ETA:APOAPSIS.
    LOCAL rBurn IS bodyR + SHIP:APOAPSIS.
    LOCAL rTarget IS bodyR + alt_.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnTime):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnTime, 0, 0, vNew - vNow).
    ADD nd.
    mLog("Set Pe node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " targetPe=" + ROUND(alt_/1000,1) + "km").
    maneuverUiArchiveLog("set-orbit-pe").
}

LOCAL tol IS 500.
LOCAL iter IS 0.
LOCAL ok IS TRUE.

PRINT "SET ORBIT: " + ROUND(targetAlt/1000,1) + " km".
mLog("STATS set-orbit setup targetKm=" + ROUND(targetAlt/1000,1)
    + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
    + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)).

UNTIL iter >= 4 OR (ABS(SHIP:PERIAPSIS - targetAlt) <= tol
        AND ABS(SHIP:APOAPSIS - targetAlt) <= tol) {
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    IF ABS(SHIP:APOAPSIS - targetAlt) > tol {
        _planSetApAtPe(targetAlt).
    } ELSE IF ABS(SHIP:PERIAPSIS - targetAlt) > tol {
        _planSetPeAtAp(targetAlt).
    }
    SET ok TO executeManeuver().
    IF NOT ok {
        mLogError("Set orbit burn failed; holding for manual review.").
        BREAK.
    }
    SET iter TO iter + 1.
}

PRINT "Orbit: Pe=" + ROUND(SHIP:PERIAPSIS/1000,2)
    + " Ap=" + ROUND(SHIP:APOAPSIS/1000,2) + " km".
mLog("STATS set-orbit result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,2)
    + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,2)
    + " targetKm=" + ROUND(targetAlt/1000,1)).
