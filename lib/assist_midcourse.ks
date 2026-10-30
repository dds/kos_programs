// Opt-in diagnostic preview; never installs a candidate or executes a burn.
@LAZYGLOBAL OFF.
GLOBAL ASSIST_HAS_MIDCOURSE_PREVIEW IS TRUE.

LOCAL FUNCTION _assistMidcourseBound {
    PARAMETER record.
    PARAMETER targetBody.
    IF NOT record:HASKEY("status") { RETURN FALSE. }
    RETURN record["mission"] = stateGet("mission_id","")
        AND record["launch"] = stateGetNum("launch_time",0)
        AND record["vehicle"] = stateGet("vehicle","")
        AND record["target"] = targetBody:NAME.
}

LOCAL FUNCTION _assistMidcourseHold {
    PARAMETER reason.
    LOCAL pending IS stateGet("assist_mcc_preview",LEXICON()):COPY.
    IF pending:HASKEY("status") {
        IF pending["status"] = "done" {
            SET pending["status"] TO "started".
            stateSet("assist_mcc_preview",pending).
        }
    }
    mLogError("STATS assist-mcc decision=hold reason=" + reason).
    PRINT "Assist preview needs review: " + reason + "; no correction authorized.".
    PRINT "Inspect the archived original vector; arrival action replan discards the retained node and retries.".
    yieldToPrompt().
    RETURN FALSE.
}

GLOBAL FUNCTION previewMidcourseAssist {
    PARAMETER targetBody.
    PARAMETER nd.
    PARAMETER checkOnly IS FALSE.
    LOCAL previous IS stateGet("assist_mcc_preview",LEXICON()).
    IF _assistMidcourseBound(previous,targetBody) {
        IF previous["status"] = "started" { RETURN _assistMidcourseHold("interrupted-preview"). }
        RETURN TRUE.
    }
    IF checkOnly OR ASSIST_MIDCOURSE_PREVIEW <= 0 { RETURN TRUE. }
    IF stateGet("phase","") <> "REFINE_BPLANE" OR missionTypeDetect() <> "interplanetary"
            OR MISSION_ASSIST_ROUTE:LENGTH < 2 { RETURN TRUE. }
    IF stateGet("bplane_retry_wait",LEXICON()):LENGTH > 0 {
        mLog("STATS assist-mcc decision=skip reason=arrival-retry"). RETURN TRUE.
    }
    // Planetary cruise only, not a late moon-transfer refinement.
    IF NOT targetBody:HASBODY { RETURN TRUE. }
    IF targetBody:BODY:HASBODY OR SHIP:BODY <> targetBody:BODY { RETURN TRUE. }
    IF NOT HOMECONNECTION:ISCONNECTED {
        mLog("STATS assist-mcc decision=skip reason=no-archive-link"). RETURN TRUE.
    }
    IF WARP <> 0 {
        mLog("STATS assist-mcc decision=skip reason=timewarp-active"). RETURN TRUE.
    }
    IF ABORT { RETURN FALSE. }
    IF NOT assistSearchIdle() { RETURN _assistMidcourseHold("unsafe-controls"). }
    LOCAL seeded IS nd = 0.
    IF seeded { IF HASNODE { RETURN _assistMidcourseHold("unexpected-node"). } }
    ELSE {
        IF NOT HASNODE OR ALLNODES:LENGTH <> 1 { RETURN _assistMidcourseHold("node-count-changed"). }
        IF NEXTNODE <> nd { RETURN _assistMidcourseHold("node-changed"). }
    }
    LOCAL fallback IS assistPreviewMissionFallback().
    IF fallback:LENGTH = 0 {
        mLog("STATS assist-mcc decision=skip reason=unsupported-fallback"). RETURN TRUE.
    }
    LOCAL limits IS assistSearchLimits().
    SET limits["CHANGE_DV"] TO 50.
    IF DEFINED ASSIST_RESERVE_DV { SET limits["RESERVE_DV"] TO MAX(limits["RESERVE_DV"],ASSIST_RESERVE_DV). }
    IF DEFINED CAPTURE_RESERVE_DV { SET limits["RESERVE_DV"] TO MAX(limits["RESERVE_DV"],CAPTURE_RESERVE_DV). }
    LOCAL nodeDv IS 0.
    IF NOT seeded { SET nodeDv TO nd:DELTAV:MAG. }
    LOCAL duration IS arrivalBurnSeconds(nodeDv+limits["CHANGE_DV"]).
    IF NOT (duration >= 0 AND duration < 1e30) {
        mLog("STATS assist-mcc decision=skip reason=unavailable-burn-duration"). RETURN TRUE.
    }
    LOCAL epoch IS TIME:SECONDS+arrivalCorrectionLead(duration).
    IF NOT seeded { SET epoch TO nd:TIME. }
    SET limits["STOP_UT"] TO epoch-duration/2-180.
    // Do not consume final approach time or a nearly due correction.
    IF NOT SHIP:ORBIT:HASNEXTPATCH { RETURN TRUE. }
    IF NOT (limits["STOP_UT"] > TIME:SECONDS+limits["GAME_SECONDS"]+5
            AND epoch+duration/2+SOI_BUFFER_TIME < TIME:SECONDS+SHIP:ORBIT:NEXTPATCHETA) {
        mLog("STATS assist-mcc decision=skip reason=insufficient-time"). RETURN TRUE.
    }
    LOCAL owner IS assistSearchContext(nd,epoch).
    LOCAL reportState IS diagnosticArchiveOpen("assistmcc").
    IF NOT reportState["READY"] { RETURN TRUE. }
    diagnosticArchiveLine(reportState,"STATS assist-mcc schema=1 mode=preview-only ut=" + TIME:SECONDS
        + " phase=" + owner["PHASE"] + " mission=" + owner["MISSION"] + " target=" + targetBody:NAME
        + " seeded=" + seeded + " nodeUt=" + epoch + " originalAxes=" + configLiteral(owner["BASE"])
        + " referencePolicy=bounded-native-drift-v2").
    diagnosticArchiveLine(reportState,"STATS assist-mcc policy route=" + configLiteral(MISSION_ASSIST_ROUTE)
        + " fallback=" + configLiteral(fallback) + " reserve=" + limits["RESERVE_DV"]
        + " changeDv=" + limits["CHANGE_DV"] + " scienceExtraDv=0 stopUt=" + limits["STOP_UT"]
        + " maxTrials=" + limits["TRIALS"] + " maxPositions=" + limits["POSITIONS"]).
    IF NOT reportState["COMPLETE"] { RETURN TRUE. }
    LOCAL record IS LEXICON("mission",owner["MISSION"],"launch",owner["LAUNCH"],
        "vehicle",stateGet("vehicle",""),"target",targetBody:NAME,"status","started",
        "ut",epoch,"axes",owner["BASE"],"seeded",seeded,"report",reportState["PATH"]).
    // Save before the first mutation. A reboot cannot silently repeat an
    // interrupted experiment, even if its temporary node survived.
    stateSet("assist_mcc_preview",record).
    IF NOT assistSearchContextBound(owner) OR NOT assistSearchIdle() {
        RETURN _assistMidcourseHold("context-changed-before-search").
    }
    IF seeded {
        IF HASNODE { RETURN _assistMidcourseHold("node-appeared-before-seed"). }
        SET nd TO NODE(epoch,0,0,0).
        ADD nd.
        SET owner["NODE"] TO nd.
        WAIT 0.1.
    }
    IF NOT assistSearchOwns(owner) OR ALLNODES:LENGTH <> 1 { RETURN _assistMidcourseHold("node-changed-before-search"). }
    assistPreviewPatchRows(nd,reportState).
    LOCAL startedGame IS TIME:SECONDS.
    LOCAL startedWall IS KUNIVERSE:REALTIME.
    LOCAL FUNCTION direct {
        PARAMETER originalNode.
        PARAMETER terminal.
        PARAMETER budget.
        RETURN assistPreviewDirect(originalNode,terminal,budget,fallback).
    }
    LOCAL result IS searchAssistNode(nd,MISSION_ASSIST_ROUTE,assistPreviewSeekIndex(nd,MISSION_ASSIST_ROUTE),direct@,limits).
    assistPreviewResult(result,reportState).
    diagnosticArchiveLine(reportState,"STATS assist-mcc elapsed gameSeconds=" + (TIME:SECONDS-startedGame)
        + " wallSeconds=" + (KUNIVERSE:REALTIME-startedWall) + " candidateInstalled=False").
    diagnosticArchiveClose(reportState,"ASSIST MCC").
    // Report I/O can itself span a takeover; recheck ownership after it.
    IF NOT result["RESTORED"] OR NOT assistSearchOwns(owner) OR ALLNODES:LENGTH <> 1
            OR maneuverBurnInterrupted() OR NOT (SHIP:THRUST <= 0.001
                AND SHIP:CONTROL:MAINTHROTTLE <= 0 AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
        RETURN _assistMidcourseHold("restoration-unverified").
    }
    IF seeded { REMOVE nd. WAIT 0.1. }
    // A compute-budget expiry is an ordinary no-result when ownership and
    // idle controls are verified. It must not hold an otherwise safe MCC.
    SET record TO record:COPY.
    SET record["status"] TO "done". SET record["candidate"] TO result["OK"].
    stateSet("assist_mcc_preview",record).
    IF NOT assistSearchContextBound(owner) OR NOT assistSearchIdle() {
        RETURN _assistMidcourseHold("context-changed-after-preview").
    }
    IF seeded { IF HASNODE { RETURN _assistMidcourseHold("node-appeared-after-cleanup"). } }
    ELSE { IF NOT assistSearchOwns(owner) OR ALLNODES:LENGTH <> 1 { RETURN _assistMidcourseHold("node-changed-after-report"). } }
    mLogSummary("STATS assist-mcc decision=continue-direct candidate=" + result["OK"]
        + " seeded=" + seeded + " report=" + reportState["PATH"]).
    RETURN TRUE.
}
