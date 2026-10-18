// Bounded solar turn recorder. Sampling has no file I/O or control writes.
@LAZYGLOBAL OFF.
GLOBAL SOLAR_DIAGNOSTICS IS 1.
LOCAL solarTrace IS LEXICON().

LOCAL FUNCTION _solarTraceRow {
    PARAMETER row.
    solarTrace["ROWS"]:ADD(row).
    SET solarTrace["BYTES"] TO solarTrace["BYTES"] + row:LENGTH.
    UNTIL solarTrace["ROWS"]:LENGTH <= 64 AND solarTrace["BYTES"] <= 24000 {
        SET solarTrace["BYTES"] TO solarTrace["BYTES"] - solarTrace["ROWS"][0]:LENGTH.
        solarTrace["ROWS"]:REMOVE(0).
        SET solarTrace["DROPPED"] TO solarTrace["DROPPED"] + 1.
    }
}

LOCAL FUNCTION _solarVectorText {
    PARAMETER vec.
    RETURN "" + ROUND(vec:X,4) + "," + ROUND(vec:Y,4) + "," + ROUND(vec:Z,4).
}

GLOBAL FUNCTION solarDiagnosticBegin {
    PARAMETER forceSearch.
    PARAMETER deadlineUt.
    PARAMETER priorIpu.
    SET solarTrace TO LEXICON("ROWS",LIST(),"BYTES",0,"DROPPED",0,"PENDING",FALSE,"MEASUREMENTS",LIST(),
        "NAME","solardiag_" + slug() + "_" + ROUND(TIME:SECONDS*1000,0) + ".log",
        "LAST", "no turn sampled",
        "HEADER","STATS solar-diag schema=2 algorithm=anchored-six-axis-refine code=" + codeVersion()
            + " ut=" + TIME:SECONDS + " vessel=" + SHIP:NAME + " body=" + SHIP:BODY:NAME
            + " phase=" + stateGet("phase","") + " force=" + forceSearch
            + " deadline=" + deadlineUt + " priorIpu=" + priorIpu + " ipu=" + CONFIG:IPU
            + " aimTimeout=" + SOLAR_AIM_TIMEOUT + " searchTimeout=" + SOLAR_SEARCH_TIMEOUT
            + " aimTol=" + SOLAR_AIM_TOLERANCE + " holdTol=" + SOLAR_HOLD_TOLERANCE
            + " refineStep=" + SOLAR_REFINE_STEP + " refineTol=" + SOLAR_REFINE_TOLERANCE
            + " refineTimeout=" + SOLAR_REFINE_TIMEOUT + " refineMinGain=" + SOLAR_REFINE_MIN_GAIN
            + " peak=" + stateGetNum("solar_axis_peak",-1)
            + " cachedAxis=" + stateGet("solar_axis",LIST())
            + " cachedDistance=" + stateGetNum("solar_axis_distance",0)
            + " sunDistance=" + SUN:POSITION:MAG
            + " cachedPanels=" + stateGetNum("solar_axis_panels",-1)
            + " cachedScaled=" + stateGetNum("solar_axis_scaled",-1)
            + " cachedTolerance=" + stateGetNum("solar_axis_tolerance",SOLAR_AIM_TOLERANCE)
            + " maxStoppingTime=" + STEERINGMANAGER:MAXSTOPPINGTIME
            + " rollRange=" + STEERINGMANAGER:ROLLCONTROLANGLERANGE
            + " settling=" + STEERINGMANAGER:PITCHTS + "," + STEERINGMANAGER:YAWTS
                + "," + STEERINGMANAGER:ROLLTS).
    IF SOLAR_DIAGNOSTICS <= 0 { RETURN. }
    LOCAL processors IS LIST().
    LIST PROCESSORS IN processors.
    FOR processor_ IN processors {
        _solarTraceRow("CPU tag=" + processor_:TAG + " mode=" + processor_:MODE
            + " part=" + processor_:PART:NAME).
    }
    FOR part IN SHIP:PARTS {
        FOR moduleName IN LIST("ModuleReactionWheel","ModuleDeployableSolarPanel") {
            IF part:HASMODULE(moduleName) {
                _solarTraceRow("PART name=" + part:NAME + " module=" + moduleName
                    + " fields=" + part:GETMODULE(moduleName):ALLFIELDS).
            }
        }
    }
}

GLOBAL FUNCTION solarDiagnosticSample {
    PARAMETER label.
    PARAMETER status.
    PARAMETER aShip.
    PARAMETER desired.
    IF SOLAR_DIAGNOSTICS <= 0 { RETURN. }
    LOCAL facing IS SHIP:FACING.
    LOCAL angularVel IS SHIP:ANGULARVEL.
    LOCAL managerFace IS "inactive".
    LOCAL managerTop IS "inactive".
    IF STEERINGMANAGER:ENABLED {
        LOCAL managerAim IS STEERINGMANAGER:TARGET.
        SET managerFace TO _solarVectorText(managerAim:FOREVECTOR).
        SET managerTop TO _solarVectorText(managerAim:TOPVECTOR).
    }
    LOCAL error IS VANG(facing*aShip,SUN:POSITION).
    LOCAL flow IS shipSolarFlow().
    LOCAL row IS "STATS solar-diag ut=" + ROUND(TIME:SECONDS,3)
        + " label=" + label + " status=" + status
        + " err=" + ROUND(error,3)
        + " rate=" + _solarVectorText(angularVel)
        + " axis=" + _solarVectorText(aShip)
        + " face=" + _solarVectorText(facing:FOREVECTOR)
        + " top=" + _solarVectorText(facing:TOPVECTOR)
        + " want=" + _solarVectorText(desired:FOREVECTOR)
        + " wantTop=" + _solarVectorText(desired:TOPVECTOR)
        + " manager=" + STEERINGMANAGER:ENABLED
        + " managerAim=" + managerFace + " managerTop=" + managerTop
        + " errors=" + STEERINGMANAGER:PITCHERROR + "," + STEERINGMANAGER:YAWERROR
            + "," + STEERINGMANAGER:ROLLERROR
        + " rawCommand=" + SHIP:CONTROL:PITCH + "," + SHIP:CONTROL:YAW + "," + SHIP:CONTROL:ROLL
        + " sas=" + SAS + " rcs=" + RCS + " suppress=" + CONFIG:SUPPRESSAUTOPILOT
        + " ipu=" + CONFIG:IPU + " warp=" + WARP + " warpSettled=" + KUNIVERSE:TIMEWARP:ISSETTLED
        + " flow=" + flow + " charge=" + shipPowerFraction()
        + " thrust=" + SHIP:THRUST + " rawThrottle=" + SHIP:CONTROL:MAINTHROTTLE
        + " pilotThrottle=" + SHIP:CONTROL:PILOTMAINTHROTTLE.
    _solarTraceRow(row).
    SET solarTrace["LAST"] TO row.
    IF status = "settled" {
        solarTrace["MEASUREMENTS"]:ADD("STATS solar-diag measured ut=" + ROUND(TIME:SECONDS,3)
            + " label=" + label + " axis=" + _solarVectorText(aShip)
            + " actualSunAxis=" + _solarVectorText(facing:INVERSE * SUN:POSITION:NORMALIZED)
            + " flow=" + flow + " err=" + ROUND(error,3)).
        IF solarTrace["MEASUREMENTS"]:LENGTH > 24 { solarTrace["MEASUREMENTS"]:REMOVE(0). }
    }
    PRINT "SOLAR " + label + " " + status + " err="
        + ROUND(error,1) + " rate=" + ROUND(angularVel:MAG,3) + " flow=" + ROUND(flow,3).
}

GLOBAL FUNCTION solarDiagnosticFinish {
    PARAMETER success.
    PARAMETER deadlineUt.
    IF SOLAR_DIAGNOSTICS <= 0 { RETURN. }
    SET solarTrace["SUMMARY"] TO "STATS solar-diag complete ut=" + TIME:SECONDS
        + " success=" + success + " dropped=" + solarTrace["DROPPED"]
        + " flow=" + shipSolarFlow() + " charge=" + shipPowerFraction()
        + " file=" + solarTrace["NAME"].
    stateSet("last_solar_summary",solarTrace["SUMMARY"] + CHAR(10) + solarTrace["LAST"]).
    SET solarTrace["PENDING"] TO TRUE.
    solarDiagnosticExport(deadlineUt).
}

GLOBAL FUNCTION solarDiagnosticExport {
    PARAMETER deadlineUt IS 0.
    IF NOT solarTrace:HASKEY("PENDING") { RETURN FALSE. }
    IF NOT solarTrace["PENDING"] OR ABORT { RETURN FALSE. }
    IF deadlineUt > 0 AND TIME:SECONDS + 15 >= deadlineUt { RETURN FALSE. }
    IF NOT (SHIP:THRUST <= 0.001) OR NOT (SHIP:CONTROL:MAINTHROTTLE <= 0)
            OR NOT (SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) { RETURN FALSE. }
    LOCAL payload IS solarTrace["HEADER"] + CHAR(10).
    FOR row IN solarTrace["MEASUREMENTS"] { SET payload TO payload + row + CHAR(10). }
    FOR row IN solarTrace["ROWS"] { SET payload TO payload + row + CHAR(10). }
    SET payload TO payload + solarTrace["SUMMARY"].
    LOCAL dest IS "".
    IF HOMECONNECTION:ISCONNECTED {
        FOR dir_ IN LIST("0:/logs","0:/logs/archive","0:/logs/archive/_diagnostics") {
            IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
            IF NOT EXISTS(dir_) { CREATEDIR(dir_). }
        }
        SET dest TO "0:/logs/archive/_diagnostics/" + solarTrace["NAME"].
        IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    } ELSE {
        IF CORE:VOLUME:FREESPACE <= payload:LENGTH + MAX(1024,LOG_FILE_RESERVE_BYTES) { RETURN FALSE. }
        // The existing recursive boot sweep collects this directory on reconnect.
        SET dest TO localFlightLogDir() + "/" + solarTrace["NAME"].
    }
    LOG payload TO dest.
    IF dest:STARTSWITH("0:/") AND NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    IF NOT EXISTS(dest) { RETURN FALSE. }
    IF dest:STARTSWITH("0:/") AND NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    IF NOT OPEN(dest):READALL:STRING:CONTAINS(solarTrace["SUMMARY"]) { RETURN FALSE. }
    stateSet("last_solar_report",dest).
    SET solarTrace["PENDING"] TO FALSE.
    PRINT "Solar diagnostic verified: " + dest.
    RETURN TRUE.
}
