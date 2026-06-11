// ============================================================
// cmd/despin.ks  —  Kill rotation with the reaction wheels
// (0:/cmd/despin.ks)
//
// No SAS module needed: kOS's steering manager drives the
// reaction wheels directly. Snapshots the current facing (never
// lock to SHIP:FACING itself — that chases the spin) and raises
// the steering manager's stopping time so a small wheel can
// catch a fast spin without oscillating.
//
// Usage:
//   RUNPATH("1:/cmd/despin.ks").               // despin, hold here
//   RUNPATH("1:/cmd/despin.ks", "node").       // then aim at next node
//   RUNPATH("1:/cmd/despin.ks", "prograde").   // or retrograde
//
// Holds until any key is pressed: a craft WITHOUT a SAS-capable
// core cannot keep attitude after a program exits (the SAS flag
// does nothing), so the hold lives as long as this program does.
// ============================================================

PARAMETER aim IS "".

RUNPATH("1:/lib/boot_lib").
bootPreamble().

SAS OFF.
RCS OFF.
SET STEERINGMANAGER:MAXSTOPPINGTIME TO 5.
LOCAL hold IS SHIP:FACING.
LOCK STEERING TO hold.
PRINT "Despinning from " + ROUND(SHIP:ANGULARVEL:MAG, 3)
    + " rad/s (wheel torque + EC required)...".
LOCAL deadline IS TIME:SECONDS + 300.
UNTIL SHIP:ANGULARVEL:MAG < 0.03 OR TIME:SECONDS > deadline {
    WAIT 0.5.
}
PRINT "Rotation now " + ROUND(SHIP:ANGULARVEL:MAG, 4) + " rad/s.".

IF aim = "node" AND HASNODE {
    LOCK STEERING TO NEXTNODE:DELTAV.
    PRINT "Aiming at the next maneuver node.".
} ELSE IF aim = "prograde" {
    LOCK STEERING TO SHIP:PROGRADE.
    PRINT "Aiming prograde.".
} ELSE IF aim = "retrograde" {
    LOCK STEERING TO SHIP:RETROGRADE.
    PRINT "Aiming retrograde.".
}

PRINT "Holding with the reaction wheel. Press any key to release".
PRINT "(SAS-less cores drift again once released).".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().
UNLOCK STEERING.
SET SAS TO TRUE.
PRINT "Released.".
