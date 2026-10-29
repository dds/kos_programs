// Live Kerbin recovery inspection; default is read-only, with archive report.
// RUNPATH("0:/cmd/kerbinrecover.ks").
// RUNPATH("0:/cmd/kerbinrecover.ks", "apply").
// Apply writes a shallow KSC-return profile, then reboots into MCC. MCC
// waits for Kerbin SOI and measures the flown orbit before entry/trim burns.
// KSC targeting is best effort; this is not a pinpoint atmospheric solver.
@LAZYGLOBAL OFF.
PARAMETER action IS "check".

LOCAL FUNCTION _kerbinRecoverySnapshot {
    LOCAL patch IS returnKerbinPatch().
    LOCAL result IS LEXICON("FOUND",FALSE,"IDEAL_DV",-1).
    IF patch = 0 { RETURN result. }
    SET result["FOUND"] TO TRUE.
    SET result["CURRENT"] TO SHIP:BODY:NAME = "Kerbin".
    SET result["PE"] TO patch:PERIAPSIS.
    SET result["AP"] TO patch:APOAPSIS.
    SET result["INC"] TO patch:INCLINATION.
    SET result["LAN"] TO patch:LAN.
    SET result["AOP"] TO patch:ARGUMENTOFPERIAPSIS.
    SET result["AVAILABLE_DV"] TO SHIP:DELTAV:VACUUM.
    SET result["ACTIVE_DV"] TO STAGE:DELTAV:VACUUM.
    SET result["STAGE"] TO STAGE:NUMBER.
    SET result["UT"] TO TIME:SECONDS.
    // Vis-viva estimate only. Actual MCC is solved against the game's node
    // after SOI entry, at its chosen epoch, retaining the existing fuel cap.
    LOCAL apoRadius IS patch:BODY:RADIUS + patch:APOAPSIS.
    LOCAL periRadius IS patch:BODY:RADIUS + patch:PERIAPSIS.
    LOCAL entryRadius IS patch:BODY:RADIUS + 53000.
    IF patch:ECCENTRICITY >= 0 AND patch:ECCENTRICITY < 1
            AND periRadius > 0 AND apoRadius > entryRadius
            AND apoRadius >= periRadius AND patch:BODY:MU > 0 {
        LOCAL oldSpeed2 IS patch:BODY:MU * (2/apoRadius-2/(apoRadius+periRadius)).
        LOCAL newSpeed2 IS patch:BODY:MU * (2/apoRadius-2/(apoRadius+entryRadius)).
        IF oldSpeed2 >= 0 AND newSpeed2 >= 0 {
            SET result["IDEAL_DV"] TO ABS(SQRT(oldSpeed2)-SQRT(newSpeed2)).
        }
    }
    RETURN result.
}

LOCAL FUNCTION _kerbinRecoveryStageFloor {
    LOCAL floorStage IS MAX(0,CORE:PART:DECOUPLEDIN+1).
    FOR chute IN SHIP:PARTSTAGGED(RETURN_DESCENT_CHUTES_TAG) {
        SET floorStage TO MAX(floorStage,chute:DECOUPLEDIN+1).
    }
    RETURN floorStage.
}

LOCAL FUNCTION _cmdKerbinrecover {
    IF action <> "check" AND action <> "apply" {
        PRINT "Use kerbinrecover with check (default) or apply.". RETURN.
    }
    IF NOT HOMECONNECTION:ISCONNECTED {
        PRINT "Kerbin recovery command requires an archive link.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("return_mcc_config").
    bootLibLoad("return_setup").
    // The linked command may run at an old MCC prompt. Refresh this
    // function-only writer; RUNONCEPATH could retain its pre-upgrade body.
    RUNPATH("0:/lib/return_setup.ks").
    LOCAL snapshot IS _kerbinRecoverySnapshot().
    IF NOT snapshot["FOUND"] {
        PRINT "No unmodified Kerbin patch found. Inspect any existing node; no mission changes made.". RETURN.
    }
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    LOCAL reportState IS diagnosticArchiveOpen("kerbinrecover").
    IF NOT reportState["READY"] { RETURN. }
    diagnosticArchiveLine(reportState,"STATS kerbin-recovery ut=" + snapshot["UT"]
        + " currentBody=" + SHIP:BODY:NAME + " status=" + SHIP:STATUS
        + " currentPatch=" + snapshot["CURRENT"]
        + " Pe=" + snapshot["PE"] + " Ap=" + snapshot["AP"]
        + " inc=" + snapshot["INC"] + " lan=" + snapshot["LAN"]
        + " aop=" + snapshot["AOP"]).
    diagnosticArchiveLine(reportState,"STATS kerbin-recovery fuel available=" + snapshot["AVAILABLE_DV"]
        + " activeStage=" + snapshot["STAGE"] + " activeDv=" + snapshot["ACTIVE_DV"]
        + " idealApoDv=" + snapshot["IDEAL_DV"]
        + " targetPe=53000 estimateOnly=True nativeSolveAfterSoi=True").
    diagnosticArchiveLine(reportState,"KSC targeting is optional/best effort; the apoapsis estimate excludes site corrections and finite-burn losses.").
    IF NOT diagnosticArchiveClose(reportState,"KERBIN RECOVERY") { RETURN. }
    IF action = "check" {
        PRINT "Inspection only. To configure recovery, run RUNPATH('0:/cmd/kerbinrecover.ks','apply').".
        RETURN.
    }
    IF stateGet("vehicle","") = "" { PRINT "Recovery requires a saved vehicle identity.". RETURN. }
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.
    // Config libraries above initialize defaults. Restore the actual craft,
    // selected profile and overrides before carrying coast/assist policy to
    // the new leg; a command is not running inside the boot's config scope.
    LOCAL vehicle IS stateGet("vehicle","").
    bootLibLoad("craft/"+vehicle).
    IF NOT bootApplyMissionConfig(vehicle,stateGet("mission_id",""),TRUE) { RETURN. }
    SET RETURN_SEQUENCE TO LIST("MCC","RETURN_TRIM","AEROBRAKE","DESCENT","DONE").
    SET RETURN_PE TO 53000.
    SET RETURN_PE_TOLERANCE TO 1000.
    SET MCC_RETURN_AT_APOAPSIS TO 1.
    SET MCC_RETURN_DV_CAP TO -1.
    SET MCC_RETURN_RESERVE_DV TO 50.
    // Recovery explicitly includes powered aerobraking when useful. Preserve
    // the restored pressure/attitude limits, repair reserve and stage tags.
    SET AEROBRAKE_AP_BURN TO 1.
    SET RETURN_REENTRY_DIR TO "RETROGRADE".
    SET RETURN_KSC_TARGET TO 1.
    SET RETURN_KSC_TRIM_DV_CAP TO 20.
    SET RETURN_ARM_CHUTES TO 1.
    SET RETURN_DESCENT_FAIRING_TAG TO "none".
    SET RETURN_DESCENT_DECOUPLER_TAG TO "descent_decoupler".
    SET RETURN_DESCENT_CHUTES_TAG TO "descent_chutes".
    SET RETURN_DESCENT_DECOUPLE_ALT TO 6000.
    SET RETURN_BURN_STAGE_LIMIT TO _kerbinRecoveryStageFloor().
    // Revalidate the native patch and stopped controls immediately before
    // changing state/profile. Existing moon-return callers still use ESCAPE.
    phaseReturnSetup("MCC").
}

_cmdKerbinrecover().
