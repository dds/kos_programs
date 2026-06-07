// ============================================================
// payload_landing.ks — Minimal landing payload phases
// (0:/lib/payload_landing.ks)
// ============================================================

GLOBAL FUNCTION phaseLandDeorbit {
    mLogWarn("STATS land-deorbit phase setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " targetPeKm=" + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1)).
    landingTargetedDeorbit().
    mLogWarn("STATS land-deorbit phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " status=" + SHIP:STATUS).
    nextPhase(fr3Seq).
}

GLOBAL FUNCTION phaseLandAssist {
    mLogWarn("STATS land-assist phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " releaseSurface=" + LANDING_CFG["ASSIST_RELEASE_ON_SURFACE"]).
    LOCAL assistOk IS landingAssistStage().
    mLogWarn("STATS land-assist phase result ok=" + assistOk
        + " alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " status=" + SHIP:STATUS).
    IF CFG:HASKEY("RELOAD_AFTER_LAND_ASSIST") AND CFG["RELOAD_AFTER_LAND_ASSIST"] > 0 {
        nextPhase(fr3Seq).
        LOCAL nextPh IS stateGet("phase", "").
        LOCAL nextBand IS "LAND".
        IF nextPh = "ROVER" { SET nextBand TO "ROVER". }
        stateSet("reload_required", "true").
        stateSet("reload_reason", "LAND_ASSIST_RELEASE").
        stateSet("reload_next_phase", nextPh).
        stateSet("reload_next_band", nextBand).
        mLog("Reload point after landing assist release. Reboot rover CPU to continue.").
        PRINT " ".
        PRINT "  LANDING ASSIST RELEASE COMPLETE".
        PRINT "  Reboot this CPU to load rover landing code.".
        WAIT UNTIL FALSE.
    }
    nextPhase(fr3Seq).
}

GLOBAL FUNCTION phaseLand {
    mLogWarn("STATS land phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).
    landingExecute().
    mLogWarn("STATS land phase result alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).
    IF CFG:HASKEY("RELOAD_AFTER_LAND") AND CFG["RELOAD_AFTER_LAND"] > 0 {
        nextPhase(fr3Seq).
        stateSet("reload_required", "true").
        stateSet("reload_reason", "TOUCHDOWN").
        stateSet("reload_next_phase", stateGet("phase", "")).
        stateSet("reload_next_band", "ROVER").
        mLog("Reload point after touchdown. Reboot rover CPU to load rover code.").
        PRINT " ".
        PRINT "  TOUCHDOWN COMPLETE".
        PRINT "  Reboot this CPU to load rover code.".
        WAIT UNTIL FALSE.
    }
    nextPhase(fr3Seq).
}

GLOBAL FUNCTION phaseRover {
    roverInit().
    roverHUD().
}
