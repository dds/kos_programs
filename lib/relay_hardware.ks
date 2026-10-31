// Read-only inventory/geometry plus explicit activation of attached payloads.
// Only relay deployment and its diagnostic command load this provider.
@LAZYGLOBAL OFF.
GLOBAL RELAY_COUNT IS 3.
GLOBAL RELAY_ALT IS -1.
GLOBAL RELAY_VERIFY_HARDWARE IS 0.
GLOBAL RELAY_MIN_PANELS IS 1.
GLOBAL RELAY_MIN_EC IS 200.
GLOBAL RELAY_RESERVE_DV IS 50.
GLOBAL RELAY_PERIOD_TOLERANCE IS 5.
GLOBAL RELAY_NAME_PREFIX IS "".
GLOBAL RELAY_ANTENNA_PARTS IS LIST("restock-relay-radial-2","restock-relay-radial-2_v2",
    "HighGainAntenna5","RelayAntenna5","RelayAntenna50","RelayAntenna100").

GLOBAL FUNCTION relayGeometry {
    PARAMETER count, altitude, bdy.
    LOCAL out IS LEXICON("OK",FALSE,"REASON","invalid-count-or-altitude").
    IF NOT (count >= 2 AND count <= 12 AND count = ROUND(count,0)
            AND altitude > 0 AND altitude < 1e30 AND bdy:MU > 0 AND bdy:RADIUS > 0) { RETURN out. }
    LOCAL radius IS bdy:RADIUS+altitude.
    LOCAL period IS 2*CONSTANT:PI*SQRT(radius^3/bdy:MU).
    LOCAL phaseSma IS radius*((count-1)/count)^(2/3).
    LOCAL phasePe IS 2*phaseSma-radius-bdy:RADIUS.
    LOCAL floorAlt IS 5000.
    IF bdy:ATM:EXISTS { SET floorAlt TO bdy:ATM:HEIGHT+5000. }
    SET out["REASON"] TO "unsafe-ring-or-phasing-orbit".
    IF NOT (phasePe > floorAlt AND radius < bdy:SOIRADIUS
            AND radius*COS(180/count) > bdy:RADIUS) { RETURN out. }
    LOCAL dv IS SQRT(bdy:MU/radius)-SQRT(bdy:MU*(2/radius-1/phaseSma)).
    SET out["PERIOD"] TO period.
    SET out["PHASE_PERIOD"] TO period*(count-1)/count.
    SET out["PHASE_PE"] TO phasePe.
    SET out["PHASE_SMA"] TO phaseSma.
    SET out["RADIUS"] TO radius.
    SET out["DEPLOY_DV"] TO 2*(count-1)*dv.
    SET out["REASON"] TO "ok".
    SET out["OK"] TO TRUE.
    RETURN out.
}

GLOBAL FUNCTION relayPayloadInfo {
    PARAMETER idx.
    LOCAL out IS LEXICON("OK",FALSE,"REASON","separator-tag", "PARTS",LIST(),
        "UIDS",LIST(),"EC",0,"CAPACITY",0,"PANELS",0,"RELAYS",0,"COMMAND",0,"FORCE",0).
    IF RELAY_VERIFY_HARDWARE > 0 AND NOT (RELAY_MIN_PANELS >= 1
            AND RELAY_MIN_PANELS = ROUND(RELAY_MIN_PANELS,0)
            AND RELAY_MIN_EC > 0 AND RELAY_MIN_EC < 1e30) {
        SET out["REASON"] TO "invalid-hardware-policy". RETURN out.
    }
    LOCAL matches IS SHIP:PARTSTAGGED("relay_"+idx).
    IF matches:LENGTH <> 1 { RETURN out. }
    LOCAL dc IS matches[0].
    IF NOT dc:ISTYPE("Separator") { RETURN out. }
    IF dc:ISDECOUPLED OR NOT (dc:HASMODULE("ModuleDecouple")
            OR dc:HASMODULE("ModuleAnchoredDecoupler")) { RETURN out. }
    SET out["DC"] TO dc.
    SET out["FORCE"] TO dc:EJECTIONFORCE.
    LOCAL parts IS out["PARTS"].
    FOR child IN dc:CHILDREN { parts:ADD(child). }
    LOCAL i IS 0.
    UNTIL i >= parts:LENGTH {
        LOCAL part_ IS parts[i].
        SET out["REASON"] TO "carrier-or-other-payload-in-release-branch".
        IF part_:UID = CORE:PART:UID OR part_:ISTYPE("Separator") { RETURN out. }
        out["UIDS"]:ADD(part_:UID).
        IF part_:HASMODULE("ModuleCommand") { SET out["COMMAND"] TO out["COMMAND"]+1. }
        IF part_:HASMODULE("ModuleDeployableSolarPanel") { SET out["PANELS"] TO out["PANELS"]+1. }
        IF part_:HASMODULE("ModuleDataTransmitter") AND RELAY_ANTENNA_PARTS:CONTAINS(part_:NAME) {
            SET out["RELAYS"] TO out["RELAYS"]+1.
        }
        FOR res IN part_:RESOURCES {
            IF res:NAME = "ElectricCharge" {
                SET out["EC"] TO out["EC"]+res:AMOUNT.
                SET out["CAPACITY"] TO out["CAPACITY"]+res:CAPACITY.
            }
        }
        IF RELAY_VERIFY_HARDWARE > 0 {
            SET out["REASON"] TO "payload-engine-not-passive".
            IF part_:HASMODULE("ModuleEngines") OR part_:HASMODULE("ModuleEnginesFX") { RETURN out. }
        }
        FOR child IN part_:CHILDREN { parts:ADD(child). }
        SET i TO i+1.
    }
    SET out["REASON"] TO "empty-payload".
    IF parts:LENGTH = 0 { RETURN out. }
    IF RELAY_VERIFY_HARDWARE > 0 {
        SET out["REASON"] TO "disable-payload-staging-in-VAB".
        IF dc:STAGED { RETURN out. }
        SET out["REASON"] TO "missing-command-relay-or-solar".
        IF out["COMMAND"] = 0 OR out["RELAYS"] = 0 OR out["PANELS"] < RELAY_MIN_PANELS { RETURN out. }
        SET out["REASON"] TO "insufficient-payload-battery".
        IF NOT (out["CAPACITY"] >= RELAY_MIN_EC AND out["CAPACITY"] < 1e30
                AND out["EC"] >= out["CAPACITY"]*0.8 AND out["EC"] < 1e30) { RETURN out. }
    }
    SET out["REASON"] TO "ok".
    SET out["OK"] TO TRUE.
    RETURN out.
}

GLOBAL FUNCTION relayAttachedCount {
    PARAMETER uids.
    LOCAL count IS 0.
    FOR part_ IN SHIP:PARTS { IF uids:CONTAINS(part_:UID) { SET count TO count+1. } }
    RETURN count.
}

// The carrier becomes a second relay. Do not count the departing branch's
// antenna, panels or battery as its retained hardware.
GLOBAL FUNCTION relayCarrierReady {
    PARAMETER excluded, deployed IS FALSE.
    LOCAL relays IS 0. LOCAL panels IS 0. LOCAL command IS 0.
    LOCAL charge IS 0. LOCAL capacity IS 0.
    FOR part_ IN SHIP:PARTS {
        IF NOT excluded:CONTAINS(part_:UID) {
            IF part_:HASMODULE("ModuleCommand") { SET command TO command+1. }
            IF part_:HASMODULE("ModuleDeployableSolarPanel") { SET panels TO panels+1. }
            IF part_:HASMODULE("ModuleDataTransmitter") AND RELAY_ANTENNA_PARTS:CONTAINS(part_:NAME) {
                IF deployed AND NOT relayAntennaReady(LEXICON("PARTS",LIST(part_))) { RETURN FALSE. }
                SET relays TO relays+1.
            }
            FOR res IN part_:RESOURCES {
                IF res:NAME = "ElectricCharge" {
                    SET charge TO charge+res:AMOUNT. SET capacity TO capacity+res:CAPACITY.
                }
            }
        }
    }
    RETURN command > 0 AND relays > 0 AND panels >= RELAY_MIN_PANELS
        AND capacity >= RELAY_MIN_EC AND capacity < 1e30
        AND charge >= 0.8*capacity AND charge < 1e30.
}

GLOBAL FUNCTION relayActivatePayload {
    PARAMETER info.
    FOR part_ IN info["PARTS"] {
        IF ABORT { RETURN. }
        FOR moduleName IN LIST("ModuleDeployableAntenna","ModuleDeployableSolarPanel") {
            IF part_:HASMODULE(moduleName) {
                LOCAL modu IS part_:GETMODULE(moduleName).
                LOCAL done IS FALSE.
                FOR eventName IN LIST("Extend Antenna","Extend Solar Panel","Extend","Deploy") {
                    IF NOT done AND modu:HASEVENT(eventName) { modu:DOEVENT(eventName). SET done TO TRUE. }
                }
            }
        }
    }
}

GLOBAL FUNCTION relayAntennaReady {
    PARAMETER info.
    FOR part_ IN info["PARTS"] {
        IF part_:HASMODULE("ModuleDataTransmitter") AND RELAY_ANTENNA_PARTS:CONTAINS(part_:NAME)
                AND part_:HASMODULE("ModuleDeployableAntenna") {
            LOCAL modu IS part_:GETMODULE("ModuleDeployableAntenna").
            // HG-20/HG-5 expose Retract only after deployment. Fixed relay
            // dishes have no deployable module. No hidden-field guesses.
            IF NOT (modu:HASEVENT("Retract Antenna") OR modu:HASEVENT("Retract")) { RETURN FALSE. }
        }
    }
    RETURN TRUE.
}
