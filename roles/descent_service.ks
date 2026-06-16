// ============================================================
// descent_service.ks - Passive service-module descent role
// (0:/roles/descent_service.ks)
//
// Set CORE:TAG = "descent_service" on a service-module CPU. It
// stays hands-off while attached, then takes over after descent
// separation to hold the service module retrograde and ride its
// chutes down.
// ============================================================

// --- Config defaults owned by this file ---
GLOBAL DESCENT_SERVICE_ARM_ALT IS 60000.
GLOBAL DESCENT_SERVICE_SEPARATION_DROP IS 0.15.
GLOBAL DESCENT_SERVICE_RELEASE_ALT IS 500.
GLOBAL DESCENT_CHUTES_TAG IS "".

SET DESCENT_SERVICE_ARM_ALT TO 60000.
SET DESCENT_SERVICE_SEPARATION_DROP TO 0.15.
SET DESCENT_SERVICE_RELEASE_ALT TO 500.
SET DESCENT_CHUTES_TAG TO "descent_chutes".

applyKnownMissionState().

GLOBAL FUNCTION bootVehicleLibs {
    RETURN LIST("logs").
}

GLOBAL FUNCTION main {
    LOCAL armAlt IS DESCENT_SERVICE_ARM_ALT.
    LOCAL massDrop IS DESCENT_SERVICE_SEPARATION_DROP.
    LOCAL releaseAlt IS DESCENT_SERVICE_RELEASE_ALT.

    LOCK THROTTLE TO 0.
    mLog("Descent service CPU: standby. No steering until separation.").
    mLog("Arming below " + ROUND(armAlt/1000, 1) + "km on descent; mass drop trigger "
        + ROUND(massDrop, 2) + "t.").

    IF SHIP:STATUS = "PRELAUNCH"
            OR SHIP:STATUS = "LANDED"
            OR SHIP:STATUS = "SPLASHED" {
        mLog("Descent service CPU waiting for launch/surface departure.").
        WAIT UNTIL SHIP:STATUS <> "PRELAUNCH"
            AND SHIP:STATUS <> "LANDED"
            AND SHIP:STATUS <> "SPLASHED".
        mLog("Descent service CPU airborne; continuing standby.").
    }

    WAIT UNTIL (SHIP:BODY:ATM:EXISTS
            AND SHIP:ALTITUDE < armAlt
            AND SHIP:VERTICALSPEED < 0)
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".

    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        mLog("Descent service CPU reached surface before arming.").
        RETURN.
    }

    LOCAL baseMass IS SHIP:MASS.
    mLogWarn("STATS descent-service armed massT=" + ROUND(baseMass, 3)
        + " altKm=" + ROUND(SHIP:ALTITUDE/1000, 1)
        + " speed=" + ROUND(SHIP:AIRSPEED, 1)).

    WAIT UNTIL SHIP:MASS < baseMass - massDrop
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".

    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        mLog("Descent service CPU reached surface before separation.").
        RETURN.
    }

    mLogWarn("STATS descent-service separation massT=" + ROUND(SHIP:MASS, 3)
        + " dropT=" + ROUND(baseMass - SHIP:MASS, 3)
        + " altKm=" + ROUND(SHIP:ALTITUDE/1000, 1)
        + " speed=" + ROUND(SHIP:AIRSPEED, 1)).
    mLog("Descent service separated - taking retrograde attitude.").

    SAS OFF.
    LOCK THROTTLE TO 0.
    LOCK STEERING TO RETROGRADE.

    _serviceOpenExtendBays().
    _serviceArmChutes().

    WAIT UNTIL ALT:RADAR < releaseAlt
        OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".

    UNLOCK STEERING.
    SAS ON.
    mLog("Descent service attitude released at radar="
        + ROUND(ALT:RADAR, 1) + "m.").

    IF SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "SPLASHED" {
        WAIT UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
    }

    mLogWarn("STATS descent-service landed type=" + SHIP:STATUS
        + " speed=" + ROUND(SHIP:AIRSPEED, 1)).
    WAIT UNTIL FALSE.
}

LOCAL FUNCTION _serviceOpenExtendBays {
    LOCAL opened IS 0.
    LOCAL missing IS 0.
    FOR p IN SHIP:PARTSTAGGED("extend_bay") {
        IF p:HASMODULE("ModuleAnimateGeneric") {
            LOCAL bm IS p:GETMODULE("ModuleAnimateGeneric").
            IF bm:HASEVENT("Open") {
                bm:DOEVENT("Open").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Open Doors") {
                bm:DOEVENT("Open Doors").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Extend") {
                bm:DOEVENT("Extend").
                SET opened TO opened + 1.
            } ELSE IF bm:HASEVENT("Deploy") {
                bm:DOEVENT("Deploy").
                SET opened TO opened + 1.
            } ELSE {
                SET missing TO missing + 1.
            }
        } ELSE {
            SET missing TO missing + 1.
        }
    }
    IF opened > 0 OR missing > 0 {
        mLog("Service extend bays opened: " + opened
            + "  unavailable: " + missing + ".").
        WAIT 1.
    }
}

LOCAL FUNCTION _serviceArmChutes {
    LOCAL tag IS DESCENT_CHUTES_TAG.

    LOCAL parts IS SHIP:PARTSTAGGED(tag).
    IF parts:LENGTH = 0 {
        mLog("Service found no parts tagged '" + tag
            + "'; scanning all chutes.").
        FOR p IN SHIP:PARTS {
            IF p:HASMODULE("ModuleParachute")
                    OR p:HASMODULE("RealChuteModule") {
                parts:ADD(p).
            }
        }
    }

    LOCAL armed IS 0.
    FOR p IN parts {
        LOCAL moduleName IS "".
        IF p:HASMODULE("ModuleParachute") { SET moduleName TO "ModuleParachute". }
        ELSE IF p:HASMODULE("RealChuteModule") { SET moduleName TO "RealChuteModule". }

        IF moduleName <> "" {
            LOCAL m IS p:GETMODULE(moduleName).
            IF m:HASEVENT("arm parachute") {
                m:DOEVENT("arm parachute").
                SET armed TO armed + 1.
            } ELSE IF m:HASEVENT("deploy chute") {
                m:DOEVENT("deploy chute").
                SET armed TO armed + 1.
            } ELSE IF m:HASEVENT("deploy") {
                m:DOEVENT("deploy").
                SET armed TO armed + 1.
            }
        }
    }
    mLog("Service chutes armed/deployed: " + armed + ".").
}
