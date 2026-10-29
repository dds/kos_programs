// ============================================================
// science_impact.ks — airless deorbit and continuous impact science
// (0:/lib/science_impact.ks). The probe is deliberately expendable.
// No claim of landed science, destruction detection, or R&D delivery.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL SCIENCE_IMPACT_PE IS -1000.
GLOBAL SCIENCE_IMPACT_DV_CAP IS 150.

LOCAL FUNCTION _scienceImpactHold {
    PARAMETER reason.
    SET WARP TO 0.
    UNLOCK STEERING.
    mLogError("STATS science-impact result=hold reason=" + reason
        + " body=" + SHIP:BODY:NAME + " Pe=" + SHIP:PERIAPSIS).
    PRINT "SCIENCE IMPACT HELD: " + reason + ". Review trajectory before resuming.".
    yieldToPrompt().
}

LOCAL FUNCTION _scienceImpactDeorbit {
    // Resume a flown impact trajectory without planning a second burn.
    IF SHIP:PERIAPSIS < 0 { RETURN TRUE. }
    IF SHIP:STATUS <> "ORBITING" OR NOT (SHIP:ORBIT:ECCENTRICITY < 1) {
        _scienceImpactHold("requires-bound-orbit-or-impact-trajectory"). RETURN FALSE.
    }
    LOCAL nd IS planLowerPe(SCIENCE_IMPACT_PE).
    IF nd:TIME < TIME:SECONDS+60 {
        SET nd:TIME TO nd:TIME+SHIP:ORBIT:PERIOD.
    }
    WAIT 0.2.
    IF ABORT OR NOT (nd:ORBIT:PERIAPSIS < 0 AND nd:ORBIT:BODY = SHIP:BODY)
            OR NOT (nd:DELTAV:MAG <= SCIENCE_IMPACT_DV_CAP
                AND nd:DELTAV:MAG <= SHIP:DELTAV:VACUUM)
            OR nd:TIME < TIME:SECONDS+60 {
        REMOVE nd.
        _scienceImpactHold("deorbit-node-or-fuel-invalid"). RETURN FALSE.
    }
    mLog("STATS science-impact deorbit dv=" + ROUND(nd:DELTAV:MAG,2)
        + " predictedPe=" + nd:ORBIT:PERIAPSIS + " nodeUt=" + nd:TIME).
    IF NOT executeManeuver() {
        _scienceImpactHold("interrupted-deorbit"). RETURN FALSE.
    }
    IF NOT thrustCutoffOk() { RETURN FALSE. }
    IF NOT (SHIP:PERIAPSIS < 0) OR SHIP:ORBIT:HASNEXTPATCH {
        _scienceImpactHold("flown-trajectory-does-not-impact"). RETURN FALSE.
    }
    RETURN TRUE.
}

GLOBAL FUNCTION phaseScienceImpact {
    SET WARP TO 0.
    WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.
    IF ABORT { RETURN. }
    LOCAL primary IS missionTargetBody().
    IF SHIP:BODY <> primary OR primary:ATM:EXISTS
            OR NOT SCIENCE_ENTRY_BANDS:HASKEY(primary:NAME)
            OR NOT (SCIENCE_IMPACT_PE < 0 AND SCIENCE_IMPACT_PE > -primary:RADIUS/2)
            OR NOT (SCIENCE_IMPACT_DV_CAP > 0 AND SCIENCE_IMPACT_DV_CAP < 1e30)
            OR NOT (SCIENCE_ENTRY_MIN_EC >= 0 AND SCIENCE_ENTRY_MIN_EC < 1) {
        _scienceImpactHold("invalid-body-or-impact-configuration"). RETURN.
    }
    LOCAL bands IS SCIENCE_ENTRY_BANDS[primary:NAME].
    IF bands:LENGTH <> 2 {
        _scienceImpactHold("invalid-sampling-bands"). RETURN.
    }
    IF NOT (bands[0] > bands[1] AND bands[1] >= 0 AND bands[0] < 1e30) {
        _scienceImpactHold("invalid-sampling-bands"). RETURN.
    }
    IF HASNODE OR SHIP:ORBIT:HASNEXTPATCH
            OR (stateGet("burn_pending","false") = "true"
                AND stateGet("burn_started","false") = "true")
            OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
        _scienceImpactHold("existing-maneuver-or-active-controls"). RETURN.
    }
    IF NOT _scienceImpactDeorbit() { RETURN. }
    LOCAL surfaceEta IS aerobrakeApEntryEta(0).
    IF NOT (surfaceEta >= 0 AND surfaceEta < 1e30) {
        _scienceImpactHold("no-future-surface-crossing"). RETURN.
    }
    LOCAL alarm IS kacEnsureAlarm("Science impact: " + primary:NAME,
        TIME:SECONDS+surfaceEta,
        "Nominal sea-level impact; terrain may be reached earlier. Resident science continues.",1).
    mLog("STATS science-impact setup Pe=" + SHIP:PERIAPSIS
        + " etaSurface=" + surfaceEta + " alarm=" + alarm + " resident=True").
    LOCAL entrySteering IS FALSE.
    LOCAL nextReport IS 0.
    UNTIL ABORT {
        IF SHIP:BODY <> primary OR SHIP:ORBIT:HASNEXTPATCH OR HASNODE {
            IF alarm <> "" { DELETEALARM(alarm). }
            _scienceImpactHold("trajectory-changed"). RETURN.
        }
        scienceFlightPulse(scienceEntryContext(),shipPowerFraction() >= SCIENCE_ENTRY_MIN_EC).
        IF SHIP:STATUS = "LANDED" {
            SET WARP TO 0.
            UNLOCK STEERING.
            BRAKES ON.
            LOCAL deadline IS TIME:SECONDS+60.
            UNTIL ABORT OR TIME:SECONDS >= deadline {
                scienceFlightPulse(scienceEntryContext(),shipPowerFraction() >= SCIENCE_ENTRY_MIN_EC).
                WAIT 1.
            }
            IF alarm <> "" { DELETEALARM(alarm). }
            IF NOT ABORT {
                mLog("STATS science-impact result=surface deliveryConfirmed=False").
                nextPhase(xferSeq).
            }
            RETURN.
        }
        SET surfaceEta TO aerobrakeApEntryEta(0).
        IF NOT (surfaceEta >= 0 AND surfaceEta < 1e30) {
            IF alarm <> "" { DELETEALARM(alarm). }
            _scienceImpactHold("no-future-surface-crossing"). RETURN.
        }
        // Stop solar/warp before low-space science and well before terrain.
        // Remain in this band throughout descent, including offline reboots.
        LOCAL boundaryEta IS aerobrakeApEntryEta(bands[0]).
        LOCAL wakeUt IS TIME:SECONDS+MIN(900,MAX(0,surfaceEta-180)).
        IF boundaryEta >= 0 { SET wakeUt TO MIN(wakeUt,TIME:SECONDS+boundaryEta). }
        IF SHIP:ALTITUDE > bands[0] AND wakeUt > TIME:SECONDS+30 {
            SET entrySteering TO FALSE.
            scienceEntryWait(wakeUt).
        } ELSE {
            SET WARP TO 0.
            IF NOT entrySteering {
                SET SAS TO FALSE.
                LOCK STEERING TO SHIP:SRFRETROGRADE.
                SET entrySteering TO TRUE.
            }
            IF TIME:SECONDS >= nextReport {
                mLog("STATS science-impact live altitude=" + ROUND(SHIP:ALTITUDE,1)
                    + " vs=" + ROUND(SHIP:VERTICALSPEED,1)
                    + " ec=" + ROUND(shipPowerFraction(),3)
                    + " homeLink=" + HOMECONNECTION:ISCONNECTED).
                SET nextReport TO TIME:SECONDS+10.
            }
            WAIT 0.5.
        }
    }
    SET WARP TO 0.
    UNLOCK STEERING.
    IF alarm <> "" { DELETEALARM(alarm). }
}
