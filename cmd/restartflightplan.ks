// ============================================================
// cmd/restartflightplan.ks  —  Restart the mission flight plan
// (0:/cmd/restartflightplan.ks)
//
// For multi-leg aircraft missions (airline GAP contracts):
// land, let passengers change, run this, and the vessel reboots
// back into the first phase of the current mission sequence so
// you can taxi, take off, fly, and land the next leg.
//
// Unlike cmd/resetmission.ks this KEEPS the selected mission
// profile and runtime mission_cfg_* overrides — it only rewinds the
// phase, archives the previous leg's flight log, and stamps a
// fresh launch_time so the next leg logs to its own file.
//
// Usage:
//   RUNPATH("0:/cmd/restartflightplan.ks").
//   RUNPATH("0:/cmd/restartflightplan.ks", LEX("reboot", FALSE)).
//   RUNPATH("0:/cmd/restartflightplan.ks", LEX("phase", "FLIGHT")).
//
// Options (all optional, with defaults):
//   phase   — phase to restart at (default: first phase of the
//             mission SEQUENCE, e.g. PREFLIGHT)
//   reboot  — reboot automatically after configuring (default TRUE)
//   force   — skip the landed/prelaunch safety check (default FALSE)
//
// Requires archive access (KSC link or relay).
// ============================================================

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().

// --- Read options with defaults ---
LOCAL restartPhase IS "".
LOCAL doReboot IS TRUE.
LOCAL force IS FALSE.
LOCAL err IS FALSE.

IF opts:HASKEY("phase")  { SET restartPhase TO opts["phase"]:TOUPPER. }
IF opts:HASKEY("reboot") { SET doReboot TO opts["reboot"]. }
IF opts:HASKEY("force")  { SET force TO opts["force"]. }

// Default restart phase: first phase of the current mission sequence
LOCAL rawSeq IS SEQUENCE.
IF restartPhase = "" {
    IF rawSeq <> "" {
        SET restartPhase TO phaseListFromString(rawSeq)[0].
    } ELSE {
        SET restartPhase TO "PREFLIGHT".
    }
}

// Safety: only restart while parked on the ground
IF NOT force
        AND SHIP:STATUS <> "LANDED"
        AND SHIP:STATUS <> "PRELAUNCH" {
    PRINT "ERROR: Must be landed to restart the flight plan.".
    PRINT "Current status: " + SHIP:STATUS + ".".
    PRINT "Pass LEX(" + CHAR(34) + "force" + CHAR(34) + ", TRUE) to override.".
    SET err TO TRUE.
}

IF NOT err {

    // Archive the completed leg's flight log before rewinding
    archiveLog().

    // Count legs for the operator's benefit
    LOCAL leg IS stateGetNum("flight_leg", 1) + 1.
    stateSet("flight_leg", leg).

    // Rewind the phase machine to the start of the sequence.
    // Mission identity and runtime config overrides stay untouched,
    // so boot skips the selector and reloads the same profile.
    stateSet("phase", restartPhase).

    // Clear any pending band-reload request from the previous leg
    FOR key IN LIST("reload_required", "reload_reason",
                    "reload_next_phase", "reload_next_band") {
        stateRemove(key).
    }

    // Fresh launch_time so the next leg's log gets its own id
    // (also keeps boot's prelaunch mission-reset check satisfied)
    stateSet("launch_time", ROUND(TIME:SECONDS)).

    PRINT " ".
    PRINT "Flight plan restarted:".
    PRINT "  Mission:  " + stateGet("mission_name", stateGet("mission_id", "(none)")).
    PRINT "  Sequence: " + rawSeq.
    PRINT "  Phase:    " + restartPhase.
    PRINT "  Leg:      " + leg.
    PRINT " ".
    mLog("Flight plan restarted at " + restartPhase + " (leg " + leg + ").").

    IF doReboot {
        PRINT "Rebooting in 3s to begin next leg...".
        WAIT 3.
        REBOOT.
    } ELSE {
        PRINT "Reboot to begin the next leg.".
    }
}
