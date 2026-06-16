// ============================================================
// vessel_hardware.ks  -  Vessel hardware operations
// (0:/lib/vessel_hardware.ks)
//
// Landing guidance calls these at state transitions or from the tick-level
// global checks. This keeps flight math out of part-module bookkeeping.
// ============================================================

@LAZYGLOBAL OFF.

GLOBAL FUNCTION vesselDeployGear {
    FOR m IN SHIP:MODULESNAMED("ModuleWheelDeployment") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    FOR m IN SHIP:MODULESNAMED("ModuleLandingLeg") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    GEAR ON.
}

GLOBAL FUNCTION vesselDeployAntennas {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableAntenna") {
        IF m:HASEVENT("Extend Antenna") { m:DOEVENT("Extend Antenna"). }
    }
}

GLOBAL FUNCTION vesselDeploySolarPanels {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
        IF m:HASEVENT("Extend Solar Panel") { m:DOEVENT("Extend Solar Panel"). }
    }
}

GLOBAL FUNCTION vesselSetReactionWheelAuthority {
    PARAMETER pct.
    LOCAL clampedPct IS MAX(0, MIN(100, pct)).
    FOR m IN SHIP:MODULESNAMED("ModuleReactionWheel") {
        IF m:HASFIELD("Authority Limiter") {
            m:SETFIELD("Authority Limiter", clampedPct).
        }
    }
}

GLOBAL FUNCTION vesselNeedsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs {
        IF eng:FLAMEOUT { RETURN TRUE. }
    }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

GLOBAL FUNCTION vesselStageForLanding {
    WAIT 0.2.
    STAGE.
    WAIT 0.5.
}

GLOBAL FUNCTION vesselLandingCleanup {
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
}

LOCAL FUNCTION _vesselTaggedDecoupler {
    PARAMETER tagName.
    FOR partRef IN SHIP:PARTS {
        IF partRef:TAG = tagName {
            IF partRef:HASMODULE("ModuleDecouple")
                    OR partRef:HASMODULE("ModuleAnchoredDecoupler") {
                RETURN partRef.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _vesselDecouplePart {
    PARAMETER partRef.
    IF partRef:HASMODULE("ModuleDecouple") {
        partRef:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF partRef:HASMODULE("ModuleAnchoredDecoupler") {
        partRef:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogWarn("Decoupler tag found, but no decouple module. Trying STAGE.").
        STAGE.
    }
}

LOCAL FUNCTION _vesselBestTipDirection {
    LOCAL hereTerrain IS SHIP:GEOPOSITION:TERRAINHEIGHT.
    LOCAL herePos IS SHIP:GEOPOSITION.
    LOCAL sampleDist IS MAX(5, ALT:RADAR + 2).
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(herePos:LAT)).

    LOCAL bestHeading IS 0.
    LOCAL bestDiff IS 999999.

    LOCAL headingDeg IS 0.
    UNTIL headingDeg >= 360 {
        LOCAL northM IS COS(headingDeg) * sampleDist.
        LOCAL eastM IS SIN(headingDeg) * sampleDist.
        LOCAL sampleLat IS herePos:LAT + northM * degPerM.
        LOCAL sampleLng IS herePos:LNG + eastM * degPerM / lonScale.
        LOCAL sampleTerrain IS LATLNG(sampleLat, sampleLng):TERRAINHEIGHT.
        LOCAL diff IS ABS(sampleTerrain - hereTerrain).

        IF diff < bestDiff {
            SET bestDiff TO diff.
            SET bestHeading TO headingDeg.
        }
        SET headingDeg TO headingDeg + 45.
    }

    mLog("Best tip direction: heading " + ROUND(bestHeading,0)
        + " deg, terrain diff=" + ROUND(bestDiff,1) + "m.").
    RETURN bestHeading.
}

GLOBAL FUNCTION vesselCarrierHandoff {
    PARAMETER carrierTag.
    PARAMETER doTip.
    PARAMETER settleTime.
    PARAMETER tipTime.
    PARAMETER roverOrientTime.

    LOCAL decoupler IS _vesselTaggedDecoupler(carrierTag).
    IF decoupler = 0 {
        mLogWarn("No decoupler tagged '" + carrierTag
            + "' - skipping carrier handoff.").
        RETURN.
    }

    mLog("Carrier handoff: settling " + ROUND(settleTime,1) + "s.").
    WAIT settleTime.

    LOCAL tipDir IS _vesselBestTipDirection().
    IF doTip {
        mLog("Tipping carrier heading " + ROUND(tipDir,0) + " deg.").
        SET SAS TO FALSE.
        LOCK STEERING TO HEADING(tipDir, 0):VECTOR.

        LOCAL tipEnd IS TIME:SECONDS + tipTime.
        LOCAL decoupled IS FALSE.
        UNTIL TIME:SECONDS >= tipEnd {
            LOCAL tiltDeg IS VANG(SHIP:FACING:FOREVECTOR, SHIP:UP:VECTOR).
            HUDTEXT("Tipping: " + ROUND(tiltDeg,1) + " deg from vertical",
                0.5, 2, 13, YELLOW, FALSE).
            IF NOT decoupled AND tiltDeg > 30 {
                mLog("Decoupling rover at tilt=" + ROUND(tiltDeg,1) + " deg.").
                _vesselDecouplePart(decoupler).
                SET decoupled TO TRUE.
                WAIT 0.1.
                UNLOCK STEERING.
                BREAK.
            }
            WAIT 0.05.
        }
        IF NOT decoupled {
            LOCAL timeoutTilt IS VANG(SHIP:FACING:FOREVECTOR, SHIP:UP:VECTOR).
            mLog("Tip timeout - decoupling at tilt=" + ROUND(timeoutTilt,1) + " deg.").
            _vesselDecouplePart(decoupler).
            WAIT 0.1.
            UNLOCK STEERING.
        }
    } ELSE {
        mLog("Decoupling rover from carrier.").
        _vesselDecouplePart(decoupler).
        WAIT 0.5.
    }

    mLog("Orienting rover wheels-down.").
    SET SAS TO FALSE.
    LOCK STEERING TO LOOKDIRUP(SHIP:NORTH:VECTOR, SHIP:UP:VECTOR).

    LOCAL orientEnd IS TIME:SECONDS + roverOrientTime + 12.
    UNTIL TIME:SECONDS >= orientEnd {
        LOCAL topErr IS VANG(SHIP:FACING:TOPVECTOR, SHIP:UP:VECTOR).
        LOCAL onGround IS SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
        LOCAL onGroundStr IS "".
        IF onGround { SET onGroundStr TO " LANDED". }
        HUDTEXT("Rover orient: alt=" + ROUND(ALT:RADAR,1)
            + "m  topErr=" + ROUND(topErr,1)
            + "deg" + onGroundStr,
            0.5, 2, 13, CYAN, FALSE).
        IF onGround AND topErr < 15 { BREAK. }
        WAIT 0.05.
    }
    UNLOCK STEERING.

    SET BRAKES TO TRUE.
    SET SAS TO TRUE.
    vesselSetReactionWheelAuthority(25).
    mLog("Brakes engaged, reaction wheels at 25%.").

    vesselDeployAntennas().
    vesselDeploySolarPanels().

    mLog("Carrier handoff complete. Rover on surface, ready for operations.").
}
