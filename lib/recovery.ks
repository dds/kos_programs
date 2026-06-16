// ============================================================
// recovery.ks  —  Post-abort recovery assists  (0:/lib/recovery.ks)
// ============================================================

GLOBAL FUNCTION archiveFlightLog {
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    archiveLog().
    mLog("Flight log archived and local spool rotated.").
    RETURN TRUE.
}

GLOBAL FUNCTION safeDeployAntennas {
    LOCAL safe IS SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED"
        OR SHIP:VELOCITY:SURFACE:MAG < 50.
    IF NOT safe { RETURN FALSE. }
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL am IS p:GETMODULE("ModuleDeployableAntenna").
            IF am:HASEVENT("Extend Antenna") { am:DOEVENT("Extend Antenna"). }
        }
    }
    mLog("Antennas deployed (recovery).").
    RETURN TRUE.
}

GLOBAL FUNCTION recoveryMode {
    LOCAL bootNum IS stateGetNum("boot_count", 0).
    mLogPhase("RECOVERY MODE").
    mLog("Post-abort recovery at boot #" + bootNum).
    HUDTEXT("RECOVERY MODE — post-abort", 8, 2, 16, YELLOW, FALSE).

    LOCAL antsOut IS safeDeployAntennas().
    IF NOT antsOut {
        mLog("Not safe for antennas — arming retry trigger.").
        WHEN TRUE THEN {
            IF safeDeployAntennas() {
                SET antsOut TO TRUE.
                IF HOMECONNECTION:ISCONNECTED { archiveFlightLog(). }
            } ELSE { PRESERVE. }
        }
    }

    IF antsOut AND HOMECONNECTION:ISCONNECTED {
        archiveFlightLog().
    }

    LOCAL dq IS CHAR(34).
    LOCAL antStatus IS "DEPLOYED".
    IF NOT antsOut { SET antStatus TO "PENDING". }
    LOCAL logStatus IS "NO LINK".
    IF HOMECONNECTION:ISCONNECTED { SET logStatus TO "ARCHIVED". }

    PRINT " ".
    PRINT "  RECOVERY MODE — ABORT at boot #" + bootNum.
    PRINT "  Antennas: " + antStatus + "   Logs: " + logStatus.
    PRINT " ".
    PRINT "  Commands:".
    PRINT "  stateSet(" + dq + "phase" + dq + "," + dq + "DONE" + dq + ").".
    PRINT "  resumeMission().".
    PRINT "  RUNPATH(" + dq + "0:/cmd/logs.ks" + dq + ").".
    PRINT " ".

    UNLOCK ALL.
    SET SAS TO TRUE.
    mLog("Recovery mode idle — operator control.").
}
