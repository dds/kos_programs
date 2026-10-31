// ============================================================
// molniya_pair.ks - Passive northern relay, carrier becomes southern relay.
// (0:/lib/molniya_pair.ks). SHAPE owns every burn and its KAC/solar waits.
// Circularize high, then lower Pe at the opposite argument of latitude;
// no180deg radial apsidal flip or new maneuver controller is required.
// ============================================================
@LAZYGLOBAL OFF.
GLOBAL MOLNIYA_PAIR_AP IS -1.
GLOBAL MOLNIYA_PAIR_PE IS -1.

LOCAL FUNCTION _pairAngle {
    PARAMETER first, second.
    RETURN ABS(MOD(first-second+540,360)-180).
}

LOCAL FUNCTION _pairContext {
    RETURN NOT ABORT AND NOT phaseShouldYield AND WARP = 0 AND SHIP = KUNIVERSE:ACTIVEVESSEL
        AND stateGet("mission_id","") <> ""
        AND SHIP:BODY:NAME = "Kerbin" AND getTarget() = "Kerbin"
        AND SHIP:STATUS = "ORBITING" AND NOT SHIP:ORBIT:HASNEXTPATCH
        AND SHIP:PERIAPSIS > SHIP:BODY:ATM:HEIGHT+10000
        AND SHIP:APOAPSIS < SHIP:BODY:SOIRADIUS-SHIP:BODY:RADIUS
        AND SHIP:ORBIT:ECCENTRICITY >= 0 AND SHIP:ORBIT:ECCENTRICITY < 1
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0 AND NOT HASNODE
        AND stateGet("burn_pending","false") <> "true"
        AND stateGet("burn_started","false") <> "true"
        AND stateGet("deorbit_burn_started","false") <> "true".
}

LOCAL FUNCTION _pairHold {
    PARAMETER reason.
    SET WARP TO 0.
    UNLOCK STEERING.
    mLogError("STATS molniya-pair result=hold reason="+reason
        +" leg="+stateGet("relay_pair_leg","north")).
    PRINT "MOLNIYA PAIR HELD: "+reason+". Nodes and release evidence retained.".
    yieldToPrompt().
}

LOCAL FUNCTION _pairOrbit {
    PARAMETER vessel, aop.
    LOCAL orb IS vessel:ORBIT.
    RETURN vessel:BODY = SHIP:BODY AND NOT orb:HASNEXTPATCH
        AND orb:PERIAPSIS > SHIP:BODY:ATM:HEIGHT+10000
        AND orb:APOAPSIS < SHIP:BODY:SOIRADIUS-SHIP:BODY:RADIUS
        AND ABS(orb:APOAPSIS-MOLNIYA_PAIR_AP) <= 5000
        AND ABS(orb:PERIAPSIS-MOLNIYA_PAIR_PE) <= 5000
        AND orb:ECCENTRICITY > 0.6 AND orb:ECCENTRICITY < 1
        AND orb:INCLINATION >= 63 AND orb:INCLINATION <= 64
        AND _pairAngle(orb:ARGUMENTOFPERIAPSIS,aop) <= 10
        AND orb:PERIOD >= 9697 AND orb:PERIOD <= 11852.
}

LOCAL FUNCTION _pairReleasedOrbit {
    PARAMETER idx, released.
    RETURN LEXICON("REFERENCE",10774,"VALID",_pairOrbit(released,270)).
}

LOCAL FUNCTION _pairCircle {
    RETURN ABS(SHIP:APOAPSIS-MOLNIYA_PAIR_AP) <= 1000
        AND ABS(SHIP:PERIAPSIS-MOLNIYA_PAIR_AP) <= 1000
        AND SHIP:ORBIT:ECCENTRICITY < 0.001
        AND ABS(SHIP:ORBIT:INCLINATION-63.4) <= 0.2
        AND _pairAngle(SHIP:ORBIT:LAN,stateGetNum("relay_pair_lan",-1)) <= 0.2.
}

LOCAL FUNCTION _pairSelectLeg {
    PARAMETER leg.
    LOCAL pe IS MOLNIYA_PAIR_PE.
    LOCAL aop IS 90.
    IF leg = "circle" { SET pe TO MOLNIYA_PAIR_AP. SET aop TO -1. }
    // Status first: interruption before/after rewriting overrides can only
    // repeat this same unflown SHAPE leg, never repeat payload separation.
    stateSet("relay_pair_leg",leg).
    missionOverrideUpdate(LEXICON("SEQUENCE",LIST("SHAPE","MOLNIYA_PAIR","DONE"),
        "SHAPE_AP",MOLNIYA_PAIR_AP,"SHAPE_PE",pe,"SHAPE_INC",63.4,
        "SHAPE_LAN",stateGetNum("relay_pair_lan",-1),"SHAPE_AOP",aop,
        "SHAPE_RESERVE_DV",100)).
    // Keep the mission epoch, cumulative SHAPE cap and expenditure intact.
    stateSaveReloadState("MOLNIYA_PAIR_"+leg,"SHAPE","SHAPE").
    mLogSummary("STATS molniya-pair next="+leg+" ap="+MOLNIYA_PAIR_AP+" pe="+pe+" aop="+aop).
    REBOOT.
}

GLOBAL FUNCTION phaseMolniyaPair {
    IF NOT _pairContext() OR NOT (MOLNIYA_PAIR_AP > MOLNIYA_PAIR_PE
            AND MOLNIYA_PAIR_AP < SHIP:BODY:SOIRADIUS-SHIP:BODY:RADIUS
            AND MOLNIYA_PAIR_PE > SHIP:BODY:ATM:HEIGHT+10000
            AND RELAY_VERIFY_HARDWARE > 0) {
        _pairHold("unsafe-context-or-configuration"). RETURN.
    }
    IF NOT thrustCutoffOk() { _pairHold("cutoff"). RETURN. }
    LOCAL campaign IS stateGet("mission_id","")+":"+stateGetNum("launch_time",0)
        +":"+CORE:PART:UID+":"+MOLNIYA_PAIR_AP+":"+MOLNIYA_PAIR_PE.
    LOCAL saved IS stateGet("relay_pair_campaign","").
    LOCAL record IS stateGet("relay_1_record",LEXICON()).
    IF record:LENGTH > 0 {
        FOR key IN LIST("VALID","UID","PERIOD") {
            IF NOT record:HASKEY(key) { _pairHold("incomplete-release-proof"). RETURN. }
        }
        IF NOT (stateGetNum("relay_pair_lan",-1) >= 0 AND stateGetNum("relay_pair_lan",-1) < 360) {
            _pairHold("missing-carrier-plane-checkpoint"). RETURN.
        }
    }
    IF saved <> campaign {
        IF saved <> "" OR record:LENGTH > 0 OR stateGet("relay_1_intent",LEXICON()):LENGTH > 0 {
            _pairHold("foreign-or-unbound-release-ledger"). RETURN.
        }
        stateSet("relay_pair_campaign",campaign).
    }
    LOCAL leg IS stateGet("relay_pair_leg","north").
    mLog("STATS molniya-pair setup leg="+leg+" pe="+SHIP:PERIAPSIS+" ap="+SHIP:APOAPSIS
        +" inc="+SHIP:ORBIT:INCLINATION+" aop="+SHIP:ORBIT:ARGUMENTOFPERIAPSIS
        +" period="+SHIP:ORBIT:PERIOD+" stageDv="+STAGE:DELTAV:VACUUM
        +" shapeSpent="+stateGetNum("shape_budget_spent",0)).
    IF leg = "north" {
        IF record:LENGTH = 0 {
            IF NOT _pairOrbit(SHIP,270) { _pairHold("northern-orbit-not-validated"). RETURN. }
            LOCAL info IS relayPayloadInfo(1).
            IF NOT info["OK"] { _pairHold(info["REASON"]). RETURN. }
            IF NOT relayCarrierReady(info["UIDS"]) { _pairHold("carrier-needs-its-own-relay-power-and-command"). RETURN. }
            LOCAL ra IS SHIP:BODY:RADIUS+MOLNIYA_PAIR_AP.
            LOCAL sma IS SHIP:BODY:RADIUS+(MOLNIYA_PAIR_AP+MOLNIYA_PAIR_PE)/2.
            LOCAL turnDv IS 2*(SQRT(SHIP:BODY:MU/ra)-SQRT(SHIP:BODY:MU*(2/ra-1/sma))).
            LOCAL spent IS stateGetNum("shape_budget_spent",0).
            IF NOT (STAGE:DELTAV:VACUUM >= turnDv+150 AND STAGE:DELTAV:VACUUM < 1e30
                    AND SHIP:AVAILABLETHRUST > 0 AND SHIP:AVAILABLETHRUST < 1e30
                    AND SHAPE_TOTAL_DV_CAP-spent >= turnDv+50) {
                _pairHold("active-carrier-stage-cannot-fund-apsidal-transfer"). RETURN.
            }
            // Activate the retained relay as well as the departing payload.
            relayActivatePayload(LEXICON("PARTS",SHIP:PARTS)).
            LOCAL deadline IS TIME:SECONDS+30.
            UNTIL relayCarrierReady(info["UIDS"],TRUE) OR TIME:SECONDS >= deadline OR NOT _pairContext() { WAIT 0.1. }
            IF NOT _pairContext() OR NOT relayCarrierReady(info["UIDS"],TRUE) {
                _pairHold("retained-relay-antenna-not-ready"). RETURN.
            }
            stateSet("relay_pair_lan",SHIP:ORBIT:LAN).
            IF NOT relayReleasePayload(1,_pairContext@,_pairReleasedOrbit@) {
                _pairHold("northern-release-or-native-proof-failed"). RETURN.
            }
            SET record TO stateGet("relay_1_record",LEXICON()).
        }
        IF NOT record["VALID"] OR relayAttachedCount(LIST(record["UID"])) <> 0 {
            _pairHold("invalid-or-still-attached-northern-relay"). RETURN.
        }
        _pairSelectLeg("circle"). RETURN.
    }
    IF record:LENGTH = 0 { _pairHold("missing-northern-release-record"). RETURN. }
    IF NOT record["VALID"] OR relayAttachedCount(LIST(record["UID"])) <> 0
            OR NOT relayCarrierReady(LIST(),TRUE) {
        _pairHold("invalid-release-or-retained-relay-hardware"). RETURN.
    }
    IF leg = "circle" {
        IF _pairCircle() {
            _pairSelectLeg("south").
        } ELSE { _pairSelectLeg("circle"). }
        RETURN.
    }
    IF leg = "south" {
        IF NOT _pairOrbit(SHIP,90) {
            // Reboot after saving south intent but before its phase/override
            // commit: only the proven preceding circle may resume that leg.
            IF _pairCircle() { _pairSelectLeg("south"). }
            ELSE { _pairHold("southern-orbit-not-validated"). }
            RETURN.
        }
        UNLOCK STEERING.
        SET SHIP:NAME TO RELAY_NAME_PREFIX+"-South".
        mLogSummary("STATS molniya-pair result=complete northUid="+record["UID"]
            +" southPe="+SHIP:PERIAPSIS+" southAp="+SHIP:APOAPSIS+" period="+SHIP:ORBIT:PERIOD).
        PRINT "Northern relay released; carrier is the southern relay. Review both native orbits and radio links.".
        nextPhase(xferSeq). RETURN.
    }
    _pairHold("unknown-leg-checkpoint").
}
