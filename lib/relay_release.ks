// Shared passive-payload separation: align, activate, persist intent, and prove
// physical departure plus the caller's actual native orbit. No carrier burns.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION relayAlignRelease {
    PARAMETER contextCheck.

    LOCAL deadline IS TIME:SECONDS+45.
    LOCAL quiet IS -1.
    SET SAS TO FALSE.
    LOCK STEERING TO SHIP:PROGRADE.
    UNTIL TIME:SECONDS >= deadline {
        IF NOT contextCheck:CALL() { UNLOCK STEERING. RETURN FALSE. }
        IF VANG(SHIP:FACING:FOREVECTOR,SHIP:PROGRADE:FOREVECTOR) < 2 AND SHIP:ANGULARVEL:MAG < 0.002 {
            IF quiet < 0 { SET quiet TO TIME:SECONDS. }
            IF TIME:SECONDS-quiet >= 1 { RETURN TRUE. }
        } ELSE { SET quiet TO -1. }
        WAIT 0.1.
    }
    UNLOCK STEERING.
    RETURN FALSE.
}

GLOBAL FUNCTION relayReleasePayload {

    PARAMETER idx, contextCheck, validateReleased.
    IF stateGet("relay_"+idx+"_record",LEXICON()):LENGTH > 0
            OR stateGet("relay_"+idx+"_intent",LEXICON()):LENGTH > 0 { RETURN FALSE. }
    LOCAL info IS relayPayloadInfo(idx).
    IF NOT info["OK"] OR NOT contextCheck:CALL() { RETURN FALSE. }
    IF NOT relayAlignRelease(contextCheck) { RETURN FALSE. }
    IF NOT thrustCutoffOk() { UNLOCK STEERING. RETURN FALSE. }
    relayActivatePayload(info).
    LOCAL deadline IS TIME:SECONDS+30.
    UNTIL relayAntennaReady(info) OR TIME:SECONDS >= deadline OR NOT contextCheck:CALL() { WAIT 0.1. }
    IF NOT relayAntennaReady(info) OR NOT contextCheck:CALL() { UNLOCK STEERING. RETURN FALSE. }
    // Recheck the complete branch after alignment/deployment waits.
    SET info TO relayPayloadInfo(idx).
    IF NOT info["OK"] { UNLOCK STEERING. RETURN FALSE. }
    LOCAL dc IS info["DC"].
    LOCAL root IS info["PARTS"][0].
    LOCAL key IS "relay_"+idx.
    mLog("STATS relay-release begin index="+idx+" carrierPeriod="+SHIP:ORBIT:PERIOD
        +" ejectionForce="+info["FORCE"]+" battery="+info["EC"]+"/"+info["CAPACITY"]).
    stateSet(key+"_intent",LEXICON("UIDS",info["UIDS"],"DC",dc:UID,"TIME",TIME:SECONDS)).
    LOCAL modu IS 0.
    IF dc:HASMODULE("ModuleDecouple") { SET modu TO dc:GETMODULE("ModuleDecouple"). }
    ELSE { SET modu TO dc:GETMODULE("ModuleAnchoredDecoupler"). }
    IF NOT modu:HASEVENT("Decouple") { UNLOCK STEERING. RETURN FALSE. }
    modu:DOEVENT("Decouple").
    WAIT 1.
    IF NOT contextCheck:CALL() OR relayAttachedCount(info["UIDS"]) <> 0 OR root:SHIP = SHIP {
        UNLOCK STEERING. RETURN FALSE.
    }
    LOCAL released IS root:SHIP.
    LOCAL period IS released:ORBIT:PERIOD.
    LOCAL validation IS validateReleased:CALL(idx,released).
    LOCAL expected IS validation["REFERENCE"].
    LOCAL valid IS released:BODY = SHIP:BODY AND validation["VALID"]
        AND period > 0 AND period < 1e30.
    IF NOT (period > 0 AND period < 1e30) { SET period TO -1. }
    stateSet(key+"_record",LEXICON("TIME",TIME:SECONDS,"PERIOD",period,"VALID",valid,"UID",root:UID)).
    IF RELAY_NAME_PREFIX <> "" { SET released:NAME TO RELAY_NAME_PREFIX+"-"+idx. }
    mLog("STATS relay-release index="+idx+" vessel="+released:NAME+" valid="+valid
        +" period="+period+" reference="+expected+" errorSeconds="+(period-expected)
        +" pe="+released:ORBIT:PERIAPSIS+" ap="+released:ORBIT:APOAPSIS
        +" inc="+released:ORBIT:INCLINATION+" lan="+released:ORBIT:LAN
        +" aop="+released:ORBIT:ARGUMENTOFPERIAPSIS+" ecc="+released:ORBIT:ECCENTRICITY).
    UNLOCK STEERING.
    SET SAS TO TRUE.
    RETURN valid.
}
