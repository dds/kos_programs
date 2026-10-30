// Manual acquisition preview around ONE existing, unflown maneuver.
// RUNPATH("0:/cmd/assistsearch.ks").  Uses the selected Espoir profile.
// Optional: route, mandatory fallback capture goal, reserve dV, vector radius,
// science extra dV, seek index (-1 selects the first missing route leg).
// Temporarily probes the node; restores it. Never burns or changes mission.
@LAZYGLOBAL OFF.
PARAMETER route IS LIST().
PARAMETER fallbackGoal IS LEXICON().
PARAMETER reserveDv IS -1.
// Must exceed the25m/s minimum gain for an already-priced capture node.
PARAMETER changeDv IS 50.
PARAMETER scienceExtraDv IS 0.
PARAMETER seekIndex IS -1.

LOCAL FUNCTION _cmdAssistsearch {
    IF NOT HOMECONNECTION:ISCONNECTED {
        PRINT "Assist search requires an archive link.". RETURN.
    }
    IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR WARP <> 0 OR ABORT
            OR NOT HASNODE OR ALLNODES:LENGTH <> 1
            OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
        PRINT "Use a linked manual prompt at 1x, throttle off, Abort off, with one unflown node.". RETURN.
    }
    IF NOT (NEXTNODE:ETA > 300 AND NEXTNODE:ETA < 1e30) {
        PRINT "Assist preview needs more than five minutes before the node; current node retained.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("maneuver").
    bootLibLoad("assist_route").
    // Function-only archive helpers stay off the onboard disk. Refresh the
    // shared validator too: old RUNONCEPATH bodies may predate its new args.
    RUNPATH("0:/lib/assist_route.ks").
    RUNPATH("0:/lib/assist_search.ks").
    RUNPATH("0:/lib/assist_search_native.ks").
    RUNPATH("0:/lib/assist_preview.ks").
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    IF route:LENGTH = 0 OR fallbackGoal:LENGTH = 0 {
        LOCAL vehicle IS stateGet("vehicle","").
        LOCAL mid IS stateGet("mission_id","").
        IF vehicle = "" OR mid = "" {
            PRINT "No selected mission; supply both an assist route and a fallback capture goal.". RETURN.
        }
        LOCAL profileId IS mid.
        IF DEFINED BOOT_HAS_MISSION_PROFILE_ALIAS {
            SET profileId TO bootMissionProfileId(vehicle,mid).
        }
        LOCAL script IS "missions/" + vehicle + "/" + profileId.
        LOCAL profilePath IS bootArchivePath(script).
        IF NOT EXISTS(profilePath) { SET profilePath TO bootLocalScriptPath(script). }
        IF profilePath = "" {
            SET profilePath TO bootLocalScriptPath("missions/" + vehicle + "/" + mid).
        }
        IF profilePath = "" OR NOT EXISTS(profilePath) { PRINT "Selected mission profile unavailable: " + script. RETURN. }
        // Replay configuration only. Do not select a mission, save state,
        // load the vehicle's phase machine or run its main function.
        RUNPATH(profilePath).
        IF DEFINED BOOT_HAS_MISSION_PROFILE_ALIAS { bootMissionProfileIntent(vehicle,mid). }
        applyMissionOverrides().
        IF route:LENGTH = 0 { SET route TO MISSION_ASSIST_ROUTE. }
        IF route:LENGTH < 2 { PRINT "Mission has no assist route; supply one explicitly.". RETURN. }
        IF fallbackGoal:LENGTH = 0 { SET fallbackGoal TO assistPreviewMissionFallback(). }
    }
    IF fallbackGoal:LENGTH = 0 { PRINT "No supported fallback capture goal; no search performed.". RETURN. }
    IF reserveDv = -1 {
        SET reserveDv TO 100.
        IF DEFINED ASSIST_RESERVE_DV { SET reserveDv TO MAX(reserveDv,ASSIST_RESERVE_DV). }
        IF DEFINED CAPTURE_RESERVE_DV { SET reserveDv TO MAX(reserveDv,CAPTURE_RESERVE_DV). }
    }
    LOCAL limits IS assistSearchLimits().
    SET limits["RESERVE_DV"] TO reserveDv.
    SET limits["CHANGE_DV"] TO changeDv.
    SET limits["SCIENCE_EXTRA_DV"] TO scienceExtraDv.
    IF NOT assistSearchIdle() OR NOT HASNODE OR ALLNODES:LENGTH <> 1 {
        PRINT "Planning context changed while loading; no search performed.". RETURN.
    }
    LOCAL nd IS NEXTNODE.
    IF NOT (changeDv > 0 AND changeDv < 1000) { PRINT "Invalid vector-change radius.". RETURN. }
    LOCAL duration IS arrivalBurnSeconds(nd:DELTAV:MAG+changeDv).
    IF NOT (duration >= 0 AND duration < 1e30) {
        PRINT "Cannot estimate the full burn duration with the current engines; node retained.". RETURN.
    }
    SET limits["STOP_UT"] TO nd:TIME-duration/2-180.
    IF limits["STOP_UT"] <= TIME:SECONDS+2 {
        PRINT "Insufficient preview time before normal alignment/burn preparation; node retained.". RETURN.
    }
    IF seekIndex = -1 { SET seekIndex TO assistPreviewSeekIndex(nd,route). }
    LOCAL reportState IS diagnosticArchiveOpen("assistsearch").
    IF NOT reportState["READY"] { RETURN. }
    diagnosticArchiveLine(reportState,"STATS assist-search schema=2 code=" + codeVersion()
        + " baselinePolicy=xing-arrival-lower"
        + " referencePolicy=bounded-native-drift-v2"
        + " ut=" + TIME:SECONDS + " phase=" + stateGet("phase","")
        + " mission=" + stateGet("mission_id","") + " vessel=" + SHIP:NAME
        + " body=" + SHIP:BODY:NAME + " ipu=" + CONFIG:IPU
        + " careerPatchesAhead=" + CAREER():PATCHLIMIT).
    // Original vector is archived BEFORE the first mutation, including if a
    // native runtime error interrupts the search before normal restoration.
    diagnosticArchiveLine(reportState,"STATS assist-search original-node ut=" + nd:TIME
        + " radial=" + nd:RADIALOUT + " normal=" + nd:NORMAL + " prograde=" + nd:PROGRADE
        + " dv=" + nd:DELTAV:MAG + " fuel=" + SHIP:DELTAV:VACUUM).
    diagnosticArchiveLine(reportState,"STATS assist-search policy route=" + configLiteral(route)
        + " fallback=" + configLiteral(fallbackGoal) + " reserve=" + reserveDv + " changeDv=" + changeDv
        + " scienceExtraDv=" + scienceExtraDv + " seek=" + seekIndex
        + " stopUt=" + limits["STOP_UT"] + " maxTrials=" + limits["TRIALS"]
        + " maxPositions=" + limits["POSITIONS"]).
    assistPreviewPatchRows(nd,reportState).
    IF NOT reportState["COMPLETE"] {
        PRINT "Original-node archive report is incomplete; no probes performed.". RETURN.
    }
    PRINT "Preview only: probing the node at its existing time, then restoring it.".
    PRINT "Comparison: original-node capture model; not a separately optimized direct route.".
    LOCAL startedGame IS TIME:SECONDS.
    LOCAL startedWall IS KUNIVERSE:REALTIME.
    LOCAL FUNCTION direct {
        PARAMETER originalNode.
        PARAMETER terminal.
        PARAMETER budget.
        RETURN assistPreviewDirect(originalNode,terminal,budget,fallbackGoal).
    }
    LOCAL result IS searchAssistNode(nd,route,seekIndex,direct@,limits).
    assistPreviewResult(result,reportState).
    diagnosticArchiveLine(reportState,"STATS assist-search elapsed gameSeconds=" + (TIME:SECONDS-startedGame)
        + " wallSeconds=" + (KUNIVERSE:REALTIME-startedWall)).
    diagnosticArchiveClose(reportState,"ASSIST SEARCH").
    IF NOT result["RESTORED"] {
        PRINT "NODE RESTORATION NOT VERIFIED. Do not execute the trial node; inspect the archived original vector.".
        RETURN.
    }
    PRINT "Original node retained. No burn, staging, phase change or alarm change.".
    IF result["OK"] { PRINT "Candidate is in the archive report only; it has not been installed or approved for execution.". }
}

_cmdAssistsearch().
