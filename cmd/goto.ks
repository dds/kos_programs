// ============================================================
// cmd/goto.ks  —  Go to any destination  (0:/cmd/goto.ks)
//
// Operator override for the universal router (lib/goto_plan.ks).
// Point the ship at any body or vessel — parent, sibling, child,
// or another planetary system — with an optional target orbit,
// and the route is flown hop by hop with progressive library
// loading. Most missions should do this via config files; this
// command is for ad-hoc retasking and banging around.
//
// Usage:
//   RUNPATH("0:/cmd/goto.ks", "Minmus").
//   RUNPATH("0:/cmd/goto.ks", LEX("dest", "Mun",
//       "pe", 30000, "ap", 100000,
//       "inc", 90, "lan", 78, "aop", 270)).
//   RUNPATH("0:/cmd/goto.ks", LEX("dest", "FR2-MUN-RELAY-01")).
//   RUNPATH("0:/cmd/goto.ks", LEX("dest", "Duna", "reboot", TRUE)).
//
// Options (all optional except dest):
//   dest    — body or vessel name (required)
//   ap, pe  — final orbit apsides in meters
//   inc     — final inclination (deg)
//   lan     — final longitude of ascending node (deg)
//   aop     — final argument of periapsis (deg)
//   reboot  — reboot immediately after planning (default FALSE)
//
// Requires archive access (KSC link or relay) and a stable orbit.
// ============================================================

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("goto_plan").

// Accept a bare destination string for quick use.
IF opts:ISTYPE("String") {
    SET opts TO LEXICON("dest", opts).
}

LOCAL dest IS "".
LOCAL doReboot IS FALSE.
LOCAL err IS FALSE.

IF opts:HASKEY("dest")   { SET dest TO opts["dest"]. }
IF opts:HASKEY("target") { SET dest TO opts["target"]. }
IF opts:HASKEY("reboot") { SET doReboot TO opts["reboot"]. }

IF dest = "" {
    PRINT "ERROR: no destination. Usage:".
    PRINT "  RUNPATH(" + CHAR(34) + "0:/cmd/goto.ks" + CHAR(34) + ", "
        + CHAR(34) + "Minmus" + CHAR(34) + ").".
    SET err TO TRUE.
}
IF SHIP:STATUS <> "ORBITING" {
    PRINT "ERROR: must be in a stable orbit (status: " + SHIP:STATUS + ").".
    SET err TO TRUE.
}

IF NOT err {

    // Final orbit spec -> SHAPE_* mission config. Clear stale keys
    // first so an omitted element really means "don't care".
    FOR key IN LIST("AP", "PE", "INC", "LAN", "AOP") {
        stateRemove("mission_cfg_SHAPE_" + key).
    }
    FOR key IN LIST("ap", "pe", "inc", "lan", "aop") {
        IF opts:HASKEY(key) {
            stateSet("mission_cfg_SHAPE_" + key:TOUPPER, opts[key]).
        }
    }

    stateSet("goto_dest", dest).
    LOCAL plan IS gotoBuildPlan(dest).

    IF plan = 0 {
        PRINT "ERROR: could not plan a route to '" + dest + "'.".
        stateRemove("goto_dest").
    } ELSE {
        // Archive the current leg's log, then take over the mission.
        archiveLog().

        // mission_id with no matching .ks file: boot skips the
        // selector and leaves our state untouched (same trick as
        // cmd/returntokerbin.ks).
        stateSet("mission_id", "goto").
        stateSet("mission_name", "GOTO " + dest).
        stateSet("mission_type", "").
        gotoCommitPlan(plan).
        stateSet("launch_time", ROUND(TIME:SECONDS)).

        PRINT " ".
        PRINT "GOTO configured: " + dest.
        PRINT "  Next leg:  " + plan["summary"].
        LOCAL specPrinted IS FALSE.
        FOR key IN LIST("ap", "pe", "inc", "lan", "aop") {
            IF opts:HASKEY(key) {
                PRINT "  Final " + key:TOUPPER + ": " + opts[key].
                SET specPrinted TO TRUE.
            }
        }
        IF NOT specPrinted {
            PRINT "  Final orbit: capture defaults (no SHAPE spec).".
        }
        PRINT " ".
        IF doReboot {
            PRINT "Rebooting in 3s to fly the route...".
            WAIT 3.
            REBOOT.
        } ELSE {
            PRINT "Reboot to fly the route.".
        }
    }
}
