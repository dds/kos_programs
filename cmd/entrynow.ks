// Resume a blocked AEROBRAKE in passive retrograde entry mode, without
// rebooting, accepting a burn, deleting nodes or changing return hardware.
// RUNPATH("0:/cmd/entrynow.ks"). Requires an archive link for fresh code.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdEntrynow {
    IF ABORT OR SHIP:BODY:NAME <> "Kerbin" OR NOT SHIP:BODY:ATM:EXISTS {
        PRINT "Requires Kerbin atmospheric approach and Abort clear.". RETURN.
    }
    SET WARP TO 0.
    SAS OFF.
    LOCK THROTTLE TO 0.
    SET SHIP:CONTROL:MAINTHROTTLE TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
    LOCK STEERING TO SHIP:SRFRETROGRADE.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF ABORT { RETURN. }
    IF NOT HOMECONNECTION:ISCONNECTED OR NOT EXISTS("0:/lib/aerobrake.ks") {
        PRINT "No archive link: holding surface retrograde at zero throttle until Abort or touchdown.".
        WAIT UNTIL ABORT OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
        RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF stateGet("phase","") <> "AEROBRAKE" {
        PRINT "Existing phase must be AEROBRAKE; mission unchanged.". RETURN.
    }
    bootLibLoad("aerobrake").
    // Old prompt may retain RUNONCEPATH's pre-update function definitions.
    RUNPATH("0:/lib/aerobrake.ks").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mission IS stateGet("mission_id","").
    IF vehicle = "" OR mission = "" {
        PRINT "Saved craft/mission identity unavailable; no mission replaced.". RETURN.
    }
    bootLibLoad("craft/"+vehicle).
    IF NOT bootApplyMissionConfig(vehicle,mission,TRUE) { RETURN. }
    IF NOT phaseList(SEQUENCE):CONTAINS("AEROBRAKE")
            OR NOT phaseList(SEQUENCE):CONTAINS("DESCENT") {
        PRINT "Current mission has no AEROBRAKE-to-DESCENT route; no rescue mode saved.". RETURN.
    }
    IF ABORT OR NOT thrustCutoffOk() { RETURN. }
    stateSet("aerobrake_entry_only",aerobrakeEntryOnlyId()).
    SET AEROBRAKE_REENTRY_DIR TO "RETROGRADE".
    PRINT "Resuming passive retrograde entry now; interrupted burn/node retained for review.".
    PRINT "Powered corrections deferred. Normal descent hardware and handoff retained.".
    main().
}

_cmdEntrynow().
