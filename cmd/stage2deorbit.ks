// cmd/stage2deorbit.ks — Manual stage2 deorbit override.
// Run on the second-stage vessel when the autonomous role did not
// fire (e.g. state loss, detection miss, or telescope end-of-life).
// Usage: RUNPATH("0:/cmd/stage2deorbit.ks").
// (Not auto-installed; run directly from archive while linked.)

mLog("stage2deorbit cmd: manual override triggered.").
HUDTEXT("Stage2 deorbit: starting...", 5, 2, 14, YELLOW, FALSE).

IF SHIP:PERIAPSIS < 30000 {
    mLog("stage2deorbit: Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + " km < 30 km. No burn needed.").
    HUDTEXT("Pe already < 30 km — no burn needed.", 5, 2, 14, GREEN, FALSE).
} ELSE IF SHIP:AVAILABLETHRUST <= 0 {
    mLog("stage2deorbit: no thrust available.").
    HUDTEXT("ERROR: no thrust available.", 8, 2, 14, RED, FALSE).
} ELSE {
    SET SAS TO FALSE.
    LOCK STEERING TO RETROGRADE.
    LOCAL startT IS TIME:SECONDS.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, SHIP:RETROGRADE:FOREVECTOR) < 5
            OR TIME:SECONDS - startT > 60 {
        WAIT 0.1.
    }
    mLog("stage2deorbit: aligned (" + ROUND(VANG(SHIP:FACING:FOREVECTOR, SHIP:RETROGRADE:FOREVECTOR),1) + " deg off). Burning.").
    LOCK THROTTLE TO 1.
    UNTIL SHIP:PERIAPSIS < 30000
            OR SHIP:AVAILABLETHRUST <= 0
            OR TIME:SECONDS - startT > 600 {
        LOCK STEERING TO RETROGRADE.
        WAIT 0.1.
    }
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    stateSet("stage2_deorbit_complete", "true").
    mLog("STATS stage2-manual result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " durationS=" + ROUND(TIME:SECONDS - startT,1)).
    HUDTEXT("Deorbit done. Pe=" + ROUND(SHIP:PERIAPSIS/1000,1) + " km", 8, 2, 14, GREEN, FALSE).
    mLog("stage2deorbit: complete.").
}
