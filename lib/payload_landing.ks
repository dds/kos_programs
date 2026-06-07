// ============================================================
// payload_landing.ks — Minimal landing payload phases
// (0:/lib/payload_landing.ks)
// ============================================================

GLOBAL FUNCTION phaseLandDeorbit {
    mLogWarn("STATS land-deorbit phase setup PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,1)
        + " targetPeKm=" + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1)).
    IF SHIP:STATUS = "SUB_ORBITAL" AND landingImpactAcceptableForAssist() {
        mLogWarn("STATS land-deorbit phase skip status=already-suborbital").
        nextPhase(fr3Seq).
        RETURN.
    }
    IF CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH") AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0 {
        IF _timedLandingDeorbit() {
            nextPhase(fr3Seq).
        }
        RETURN.
    }
    IF NOT _confirmLandingTarget() { RETURN. }
    LOCAL deorbitOk IS landingTargetedDeorbit().
    mLogWarn("STATS land-deorbit phase result PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " status=" + SHIP:STATUS
        + " ok=" + deorbitOk).
    IF NOT deorbitOk {
        mLogError("Landing deorbit did not meet target tolerance; holding for manual review.").
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING DEORBIT FAILED TARGET CHECK".
        PRINT "  Keep/reselect the waypoint, check orbit reachability, then reboot/resume.".
        yieldToPrompt().
        RETURN.
    }
    nextPhase(fr3Seq).
}

LOCAL FUNCTION _timedLandingDeorbit {
    LOCAL leadMin IS 5.
    IF CFG:HASKEY("LANDING_DEORBIT_LEAD_MINUTES") {
        SET leadMin TO CFG["LANDING_DEORBIT_LEAD_MINUTES"].
    }
    LOCAL burnUT IS TIME:SECONDS + MAX(30, leadMin * 60).
    LOCAL bodyR IS SHIP:ORBIT:BODY:RADIUS.
    LOCAL mu IS SHIP:ORBIT:BODY:MU.
    LOCAL rBurn IS (POSITIONAT(SHIP, burnUT) - POSITIONAT(SHIP:BODY, burnUT)):MAG.
    LOCAL rPe IS bodyR + LANDING_CFG["DEORBIT_PE"].
    LOCAL tSMA IS (rBurn + rPe) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUT):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnUT, 0, 0, vNew - vNow).

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    ADD nd.
    mLogWarn("STATS land-deorbit timed setup leadMin=" + ROUND(leadMin,1)
        + " burnT=" + ROUND(burnUT - TIME:SECONDS,0)
        + " targetPeKm=" + ROUND(LANDING_CFG["DEORBIT_PE"]/1000,1)
        + " dv=" + ROUND(nd:DELTAV:MAG,1)).
    mLog("Timed sim deorbit node: dV=" + ROUND(nd:DELTAV:MAG,1)
        + " m/s at T+" + ROUND(nd:ETA,0) + "s.").
    archivePlannedManeuverLog("timed-landing-deorbit").
    LOCAL ok IS executeManeuver().
    mLogWarn("STATS land-deorbit timed result ok=" + ok
        + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
        + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
        + " status=" + SHIP:STATUS).
    IF NOT ok {
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  TIMED LANDING DEORBIT MISSED".
        PRINT "  Reboot/resume or rerun setup when ready.".
        yieldToPrompt().
        RETURN FALSE.
    }
    RETURN TRUE.
}

LOCAL FUNCTION _confirmLandingTarget {
    LOCAL targetInfo IS landingResolveTarget().
    IF NOT targetInfo["FOUND"] {
        IF _autoLandingTarget() {
            SET targetInfo TO landingResolveTarget().
        }
    }
    PRINT " ".
    PRINT "  LANDING TARGET CHECK".
    IF targetInfo["FOUND"] {
        PRINT "  Source: " + targetInfo["SOURCE"].
        PRINT "  Lat/Lng: " + ROUND(targetInfo["LAT"],4)
            + ", " + ROUND(targetInfo["LNG"],4).
        mLogWarn("STATS landing target confirm source=" + targetInfo["SOURCE"]
            + " lat=" + ROUND(targetInfo["LAT"],4)
            + " lng=" + ROUND(targetInfo["LNG"],4)).
    } ELSE {
        PRINT "  No landing target found.".
        PRINT "  Select a waypoint, run simlandhere, or set LANDING_TARGET_LAT/LNG.".
        mLogWarn("STATS landing target confirm status=missing").
        yieldToPrompt().
        RETURN FALSE.
    }
    PRINT "  Press any key to plan targeted deorbit.".
    WAIT UNTIL TERMINAL:INPUT:HASCHAR.
    TERMINAL:INPUT:GETCHAR().
    RETURN TRUE.
}

LOCAL FUNCTION _autoLandingTarget {
    IF NOT CFG:HASKEY("LANDING_AUTO_TARGET") { RETURN FALSE. }
    IF CFG["LANDING_AUTO_TARGET"] <= 0 { RETURN FALSE. }

    LOCAL minutes IS 5.
    IF CFG:HASKEY("LANDING_AUTO_TARGET_MINUTES") {
        SET minutes TO CFG["LANDING_AUTO_TARGET_MINUTES"].
    }
    LOCAL geo IS SHIP:BODY:GEOPOSITIONOF(POSITIONAT(SHIP, TIME:SECONDS + minutes * 60)).
    SET LANDING_CFG["TARGET_LAT"] TO geo:LAT.
    SET LANDING_CFG["TARGET_LNG"] TO geo:LNG.
    SET LANDING_CFG["TARGET_LOCK"] TO TRUE.
    IF DEFINED stateSet {
        stateSet("mission_cfg_LANDING_TARGET_LAT", geo:LAT).
        stateSet("mission_cfg_LANDING_TARGET_LNG", geo:LNG).
        stateSet("mission_cfg_LANDING_TARGET_LOCK", "1").
    }
    mLogWarn("STATS landing target auto source=ground-track minutes="
        + ROUND(minutes,1)
        + " lat=" + ROUND(geo:LAT,4)
        + " lng=" + ROUND(geo:LNG,4)).
    RETURN TRUE.
}

GLOBAL FUNCTION phaseLandAssist {
    mLogWarn("STATS land-assist phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " releaseSurface=" + LANDING_CFG["ASSIST_RELEASE_ON_SURFACE"]).
    IF _redirectOrbitalLandingPhase("LAND_ASSIST") { RETURN. }
    IF CFG:HASKEY("LANDING_SKIP_TARGET_SEARCH") AND CFG["LANDING_SKIP_TARGET_SEARCH"] > 0 {
        mLogWarn("STATS landing-impact skipped reason=sim-no-target-search").
    } ELSE IF NOT landingImpactAcceptableForAssist() {
        mLogError("Predicted landing impact is not within target tolerance; holding LAND_ASSIST.").
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        PRINT " ".
        PRINT "  LANDING IMPACT CHECK FAILED".
        PRINT "  Replan deorbit or verify selected waypoint before descent.".
        yieldToPrompt().
        RETURN.
    }
    LOCAL assistOk IS landingAssistStage().
    mLogWarn("STATS land-assist phase result ok=" + assistOk
        + " alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " status=" + SHIP:STATUS).
    IF NOT assistOk {
        mLogError("Landing assist failed; holding current phase for manual review.").
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        PRINT " ".
        PRINT "  LANDING ASSIST FAILED".
        PRINT "  Review target, decoupler tag, attitude, fuel, and phase before reboot.".
        yieldToPrompt().
        RETURN.
    }
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
        yieldToPrompt().
        RETURN.
    }
    nextPhase(fr3Seq).
}

GLOBAL FUNCTION phaseLand {
    mLogWarn("STATS land phase setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)
        + " status=" + SHIP:STATUS).

    IF _redirectOrbitalLandingPhase("LAND") { RETURN. }

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
        yieldToPrompt().
        RETURN.
    }
    nextPhase(fr3Seq).
}

LOCAL FUNCTION _redirectOrbitalLandingPhase {
    PARAMETER phaseName.
    IF (SHIP:STATUS = "ORBITING" OR SHIP:STATUS = "SUB_ORBITAL")
            AND SHIP:PERIAPSIS > LANDING_CFG["DEORBIT_PE"] {
        mLogWarn(phaseName + " requested while still in orbit; returning to LAND_DEORBIT.").
        stateSet("phase", "LAND_DEORBIT").
        PRINT " ".
        PRINT "  LANDING TARGET CHECK".
        PRINT "  Select the landing waypoint in map/navigation.".
        PRINT "  Phase reset to LAND_DEORBIT. Reboot/resume when ready.".
        yieldToPrompt().
        RETURN TRUE.
    }
    RETURN FALSE.
}

GLOBAL FUNCTION phaseRover {
    roverInit().
    roverHUD().
}
