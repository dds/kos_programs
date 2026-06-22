// ============================================================
// abort.ks - post-abort descent handling
// ============================================================

LOCAL FUNCTION _abortChuteParts {
    LOCAL parts IS SHIP:PARTSTAGGED("chute_main").
    IF parts:LENGTH > 0 { RETURN parts. }
    SET parts TO LIST().
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleParachute") OR p:HASMODULE("RealChuteModule") {
            parts:ADD(p).
        }
    }
    RETURN parts.
}

// Arm every chute (deploy-when-safe), then VERIFY the arm took:
// once armed/deployed the arm event disappears. Returns
// LIST(found, armed).
LOCAL FUNCTION _abortArmChutes {
    LOCAL found IS 0.
    FOR p IN _abortChuteParts() {
        LOCAL moduleName IS "".
        IF p:HASMODULE("ModuleParachute") { SET moduleName TO "ModuleParachute". }
        ELSE IF p:HASMODULE("RealChuteModule") { SET moduleName TO "RealChuteModule". }
        IF moduleName <> "" {
            SET found TO found + 1.
            LOCAL m IS p:GETMODULE(moduleName).
            IF m:HASEVENT("arm parachute") { m:DOEVENT("arm parachute"). }
            ELSE IF m:HASEVENT("deploy chute") { m:DOEVENT("deploy chute"). }
            ELSE IF m:HASEVENT("deploy") { m:DOEVENT("deploy"). }
        }
    }
    IF found = 0 { RETURN LIST(0, 0). }
    WAIT 0.5.

    LOCAL armed IS 0.
    FOR p IN _abortChuteParts() {
        LOCAL moduleName IS "".
        IF p:HASMODULE("ModuleParachute") { SET moduleName TO "ModuleParachute". }
        ELSE IF p:HASMODULE("RealChuteModule") { SET moduleName TO "RealChuteModule". }
        IF moduleName <> "" {
            LOCAL m IS p:GETMODULE(moduleName).
            IF NOT m:HASEVENT("arm parachute") AND NOT m:HASEVENT("deploy") {
                SET armed TO armed + 1.
            } ELSE {
                mLogWarn("Chute NOT armed: " + p:TITLE
                    + " events: " + m:ALLEVENTNAMES:JOIN(", ")).
            }
        }
    }
    RETURN LIST(found, armed).
}

// ABORT phase: post-abort descent to touchdown.
GLOBAL FUNCTION phaseAbort {
    IF ADDONS:MJ:AVAILABLE { SET ADDONS:MJ:ASCENT:ENABLED TO FALSE. }
    UNLOCK ALL.
    SET SAS TO TRUE.

    mLog("STATS abort entry alt=" + ROUND(SHIP:ALTITUDE, 0)
        + " vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)
        + " vs=" + ROUND(SHIP:VERTICALSPEED, 1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000, 1)).
    IF HOMECONNECTION:ISCONNECTED { archiveLog(). }

    IF SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "SPLASHED" {
        // Give the escape motor / separation a beat before chutes.
        WAIT 1.5.
        LOCAL chuteState IS _abortArmChutes().
        IF chuteState[0] = 0 {
            mLogError("NO PARACHUTES FOUND - firing AG6 backup.").
            HUDTEXT("ABORT: NO CHUTES - AG6 FIRED", 8, 2, 18, RED, FALSE).
            AG6 ON.
        } ELSE {
            IF chuteState[1] < chuteState[0] {
                mLogWarn("CHUTES: only " + chuteState[1] + "/" + chuteState[0]
                    + " armed - re-arming during descent.").
            } ELSE {
                mLog("CHUTES: " + chuteState[1] + "/" + chuteState[0]
                    + " armed and ready.").
            }
            HUDTEXT("ABORT: chutes " + chuteState[1] + "/" + chuteState[0]
                + " armed", 8, 2, 16, YELLOW, FALSE).
        }

        LOCAL nextCheck IS TIME:SECONDS + 20.
        UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            IF TIME:SECONDS >= nextCheck {
                SET nextCheck TO TIME:SECONDS + 20.
                IF chuteState[0] > 0 AND chuteState[1] < chuteState[0] {
                    SET chuteState TO _abortArmChutes().
                    mLog("Chute re-arm: " + chuteState[1] + "/"
                        + chuteState[0] + " armed.").
                }
                mLog("Abort descent: alt=" + ROUND(SHIP:ALTITUDE/1000, 1)
                    + "km vSurf=" + ROUND(SHIP:VELOCITY:SURFACE:MAG, 0)
                    + "m/s vs=" + ROUND(SHIP:VERTICALSPEED, 0) + "m/s.").
            }
            WAIT 1.
        }
    }

    mLog("STATS abort landed status=" + SHIP:STATUS
        + " lat=" + ROUND(SHIP:GEOPOSITION:LAT, 4)
        + " lng=" + ROUND(SHIP:GEOPOSITION:LNG, 4)).

    // Antennas back out so the log archive has a link.
    FOR p IN SHIP:PARTS {
        IF p:HASMODULE("ModuleDeployableAntenna") {
            LOCAL am IS p:GETMODULE("ModuleDeployableAntenna").
            IF am:HASEVENT("Extend Antenna") { am:DOEVENT("Extend Antenna"). }
        }
    }
    WAIT 3.
    IF HOMECONNECTION:ISCONNECTED {
        archiveLog().
        mLog("Abort log archived.").
    } ELSE {
        mLogWarn("No KSC link - log NOT archived; reboot when linked.").
    }

    PRINT " ".
    PRINT "  ABORT COMPLETE - " + SHIP:STATUS.
    PRINT "  ---------------------------------------------".
    PRINT "  Clear abort:    SET ABORT TO FALSE.".
    PRINT "  Refly:          RUNPATH('0:/cmd/setphase.ks', 'LAUNCH'). + reboot".
    PRINT "  Other mission:  RUNPATH('0:/cmd/setphase.ks', 'LAUNCH', '<id>').".
    PRINT "  State dump:     RUNPATH('0:/cmd/dump.ks').".
    PRINT "  Backup chutes:  AG6 ON.".
    yieldToPrompt().
}
