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
