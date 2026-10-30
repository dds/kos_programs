// Ike leg setup; independent of Duna atmospheric operations.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION phaseIkeSetup {
    mLogPhase("IKE_SETUP").
    IF dunaIkeBodyName() <> "DUNA" {
        dunaIkeHold("IKE SETUP HOLD",
            "expected Duna orbit, current body=" + SHIP:BODY:NAME + ".").
        RETURN.
    }
    IF SHIP:STATUS <> "ORBITING" {
        dunaIkeHold("IKE SETUP HOLD",
            "requires stable Duna orbit; status=" + SHIP:STATUS + ".").
        RETURN.
    }

    LOCAL legId IS "duna_ike_flyby".
    LOCAL legName IS "Duna/Ike Flyby".
    LOCAL legType IS "duna_ike_flyby".
    LOCAL legPayloads IS LIST("SCISAT").
    IF IKE_MISSION_SETTINGS:LENGTH > 0 {
        // Operations profiles commit only from an idle, safe bound orbit.
        // Preserve foreign nodes and interrupted burns for operator review.
        IF ABORT OR HASNODE OR SHIP:ORBIT:HASNEXTPATCH
                OR stateGet("vehicle", "") = ""
                OR NOT (SHIP:PERIAPSIS > dunaIkeAtmHeight() AND SHIP:ORBIT:ECCENTRICITY < 1)
                OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                    AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0)
                OR (stateGet("burn_pending","false") = "true"
                    AND stateGet("burn_started","false") = "true") {
            dunaIkeHold("IKE SETUP HOLD", "operations handoff requires safe idle Duna orbit, no node or interrupted burn").
            RETURN.
        }
        IF NOT IKE_MISSION_SETTINGS:HASKEY("MISSION_ID")
                OR NOT IKE_MISSION_SETTINGS:HASKEY("MISSION_NAME")
                OR NOT IKE_MISSION_SETTINGS:HASKEY("MISSION_TYPE")
                OR NOT IKE_MISSION_SETTINGS:HASKEY("PAYLOADS") {
            dunaIkeHold("IKE SETUP HOLD", "operations identity/payload settings missing").
            RETURN.
        }
        IF IKE_FLYBY_SEQUENCE:LENGTH = 0 OR IKE_FLYBY_SEQUENCE[0] <> "XING"
                OR NOT IKE_FLYBY_SEQUENCE:CONTAINS("CAPTURE") {
            dunaIkeHold("IKE SETUP HOLD", "operations leg must transfer to and capture at Ike").
            RETURN.
        }
        SET legId TO IKE_MISSION_SETTINGS["MISSION_ID"].
        SET legName TO IKE_MISSION_SETTINGS["MISSION_NAME"].
        SET legType TO IKE_MISSION_SETTINGS["MISSION_TYPE"].
        SET legPayloads TO IKE_MISSION_SETTINGS["PAYLOADS"].
    }

    dunaIkeArchiveLog().
    stateSet("target", "IKE").
    stateSet("mission_type", legType).
    stateSet("mission_id", legId).
    stateSet("mission_name", legName).
    stateSet("payloads", legPayloads).
    missionOverrideClear().
    SET DI_PROFILE_PATH TO missionProfileBegin(stateGet("vehicle", ""), legId).

    LOG "SET MISSION_ID TO " + configLiteral(legId) + "." TO DI_PROFILE_PATH.
    LOG "SET MISSION_NAME TO " + configLiteral(legName) + "." TO DI_PROFILE_PATH.
    LOG "SET MISSION_TYPE TO " + configLiteral(legType) + "." TO DI_PROFILE_PATH.
    LOG "SET TARGET_ TO " + configLiteral("IKE") + "." TO DI_PROFILE_PATH.
    LOG "SET PAYLOADS TO " + configLiteral(legPayloads) + "." TO DI_PROFILE_PATH.
    LOG "SET SEQUENCE TO " + configLiteral(IKE_FLYBY_SEQUENCE) + "." TO DI_PROFILE_PATH.
    LOG "SET CAPTURE_PE TO " + configLiteral(IKE_FLYBY_PE) + "." TO DI_PROFILE_PATH.
    LOG "SET BPLANE_TARGET TO " + configLiteral("IKE") + "." TO DI_PROFILE_PATH.
    LOG "SET FLYBY_POST_PE_HOLD TO " + configLiteral(IKE_FLYBY_POST_PE_HOLD) + "." TO DI_PROFILE_PATH.
    LOG "SET FLYBY_EXIT_SOI TO " + configLiteral(IKE_FLYBY_EXIT_SOI) + "." TO DI_PROFILE_PATH.
    LOG "SET TRANSFER_SCAN_LOOKAHEAD_HOURS TO " + configLiteral(IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS) + "." TO DI_PROFILE_PATH.
    LOG "SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO " + configLiteral(IKE_TRANSFER_SCAN_SAMPLES_PER_ORBIT) + "." TO DI_PROFILE_PATH.
    LOG "SET BPLANE_DV_CAP TO " + configLiteral(IKE_BPLANE_DV_CAP) + "." TO DI_PROFILE_PATH.
    LOG "SET REFINE_BPLANE_DV_CAP TO " + configLiteral(IKE_REFINE_BPLANE_DV_CAP) + "." TO DI_PROFILE_PATH.
    LOG "SET REFINE_BPLANE_MAX_BURNS TO " + configLiteral(IKE_REFINE_BPLANE_MAX_BURNS) + "." TO DI_PROFILE_PATH.
    IF IKE_FLYBY_INC >= 0 {
        LOG "SET CAPTURE_INC TO " + configLiteral(IKE_FLYBY_INC) + "." TO DI_PROFILE_PATH.
    }
    dunaIkeWriteCoast().
    IF IKE_MISSION_SETTINGS:LENGTH = 0 {
        dunaIkeWriteEntry().
    } ELSE {
        // Literal settings survive offline reboots and supersede initial Duna
        // capture/SHAPE defaults. The generated id differs from archive launch
        // profiles, so a connected reboot cannot restart the Duna leg.
        FOR key IN IKE_MISSION_SETTINGS:KEYS {
            LOG "SET " + key + " TO " + configLiteral(IKE_MISSION_SETTINGS[key]) + "." TO DI_PROFILE_PATH.
        }
    }

    stateSet("phase", "XING").
    stateSet("lib_band", "XFER_PLAN").
    dunaIkeClearCache().
    stateSet("launch_time", ROUND(TIME:SECONDS)).
    mLog("STATS ike-setup mission=" + legId + " sequence=" + IKE_FLYBY_SEQUENCE
        + " Pe=" + ROUND(IKE_FLYBY_PE/1000,1) + "km.").
    PRINT " ".
    PRINT legName + " configured.".
    PRINT "  Sequence: " + IKE_FLYBY_SEQUENCE.
    PRINT "  Ike Pe:   " + ROUND(IKE_FLYBY_PE/1000,1) + "km".
    PRINT "  Rebooting into XING.".
    WAIT 3.
    REBOOT.
}

