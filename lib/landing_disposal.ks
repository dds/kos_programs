// ============================================================
// landing_disposal.ks - Optional fueled transfer-stage separation
// (0:/lib/landing_disposal.ks)
// Only the powered landing band carries this policy. Guidance and the
// existing staging driver retain ownership of steering and engine recovery.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingStageDisposalInfo {
    PARAMETER ctx.
    LOCAL result IS LEXICON("OK", FALSE, "REASON", "stack", "STAGE", -1,
        "DV", 0, "REQUIRED_DV", 0, "HEIGHT", _landingBurnHeight(ctx), "GATE", 0).
    LOCAL engineStage IS vesselLandingNextEngineStage().
    // This policy only discards an adjacent serial transfer stage, never
    // arbitrary intervening slots or a stack whose future dV belongs to
    // more than the selected lander stage.
    IF engineStage < 0 OR STAGE:NUMBER <> engineStage + 1
            OR CORE:PART:DECOUPLEDIN >= engineStage { RETURN result. }
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:AVAILABLETHRUST > 0 {
            IF eng:DECOUPLEDIN <> engineStage OR eng:THROTTLELOCK { RETURN result. }
        }
        IF eng:POSSIBLETHRUST > 0 AND NOT eng:FLAMEOUT
                AND eng:DECOUPLEDIN < engineStage AND eng:STAGE <> engineStage {
            RETURN result.
        }
    }
    SET result["STAGE"] TO engineStage.
    SET result["REASON"] TO "disposal-speed".
    IF NOT (ctx["H_SPEED"] > MAX(30, APPROACH_HSPEED)) { RETURN result. }
    SET result["REASON"] TO "lander-acceleration".
    LOCAL reserveAcc IS vesselLandingReserveAcc().
    LOCAL gravAcc IS ctx["BRAKE_GRAV"].
    IF NOT (reserveAcc > gravAcc) { RETURN result. }
    LOCAL delay IS MAX(LANDING_BRAKE_REACTION_TIME,
        1 + 2 * MAX(0.05, LANDING_STAGE_SETTLE)).
    LOCAL envelope IS lmBrakeEnvelope(ctx["H_SPEED"], ctx["DOWN_SPEED"], reserveAcc, gravAcc, delay).
    SET result["GATE"] TO envelope["V"].
    SET result["REASON"] TO "lander-clearance".
    IF NOT (result["HEIGHT"] > envelope["V"]) { RETURN result. }
    LOCAL speed IS SQRT(ctx["H_SPEED"] ^ 2 + (ctx["DOWN_SPEED"] + gravAcc * delay) ^ 2).
    LOCAL stopTime IS speed / lmBrakeNetAcc(reserveAcc, gravAcc) * MAX(1, BURN_MARGIN).
    SET result["DV"] TO SHIP:DELTAV:VACUUM - STAGE:DELTAV:VACUUM.
    SET result["REQUIRED_DV"] TO speed + gravAcc * (delay + stopTime)
        + MAX(0, LANDING_STAGE_DISCARD_RESERVE_DV).
    SET result["REASON"] TO "lander-fuel".
    IF NOT (result["DV"] >= result["REQUIRED_DV"]) { RETURN result. }
    SET result["REASON"] TO "ballistic-disposal".
    // With no remaining nodes, a bound descending coast that passes below
    // measured terrain at periapsis necessarily intersects the surface.
    // This is a disposal/contact check, not a debris separation-distance or
    // component-destruction guarantee.
    IF HASNODE OR SHIP:BODY:ATM:EXISTS OR ctx["V_SPEED"] >= 0
            OR SHIP:ORBIT:ECCENTRICITY >= 1 { RETURN result. }
    LOCAL periUT IS TIME:SECONDS + ETA:PERIAPSIS.
    IF ORBITAT(SHIP, periUT):BODY:NAME <> SHIP:BODY:NAME { RETURN result. }
    LOCAL periGeo IS lmGroundGeoAt(periUT).
    IF SHIP:PERIAPSIS + LANDING_BRAKE_CLEARANCE >= periGeo:TERRAINHEIGHT { RETURN result. }
    SET result["OK"] TO TRUE.
    SET result["REASON"] TO "ready".
    RETURN result.
}

GLOBAL FUNCTION landingStageDisposalTick {
    PARAMETER ctx.
    IF ABORT {
        SET ctx["DISCARD_PENDING"] TO FALSE.
        _landingSetThrottle(ctx, 0).
        RETURN.
    }
    IF ctx["DISCARD_PENDING"] {
        // Let zero throttle reach physics before separating a fueled engine.
        // Every throttle publisher honors DISCARD_PENDING until we finish or
        // cancel; a cutoff that fails never causes a blind separation.
        _landingSetThrottle(ctx, 0).
        SET SHIP:CONTROL:MAINTHROTTLE TO 0.
        SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
        LOCAL elapsed IS TIME:SECONDS - ctx["DISCARD_SINCE"].
        IF elapsed < 0.05 { RETURN. }
        LOCAL check IS landingStageDisposalInfo(ctx).
        IF check["OK"] AND SHIP:THRUST <= 0.001 AND STAGE:READY
                AND TIME:SECONDS - ctx["DISCARD_SINCE"] < 1 {
            SET ctx["STAGE_ENGINE"] TO check["STAGE"].
            IF vesselLandingStageEvent(ctx, check["STAGE"]) {
                SET ctx["DISCARD_PENDING"] TO FALSE.
                mLog("STATS landing-discard stage-requested height=" + ROUND(check["HEIGHT"],0)
                    + " hs=" + ROUND(ctx["H_SPEED"],1) + " vs=" + ROUND(ctx["V_SPEED"],1)).
                RETURN.
            }
        }
        IF NOT check["OK"] OR TIME:SECONDS - ctx["DISCARD_SINCE"] >= 1 {
            IF check["OK"] { SET check["REASON"] TO "cutoff-or-staging-timeout". }
            SET ctx["DISCARD_PENDING"] TO FALSE.
            mLogWarn("STATS landing-discard canceled reason=" + check["REASON"]
                + " thrust=" + SHIP:THRUST + ". Existing propulsion retained.").
        }
        RETURN.
    }
    IF LANDING_STAGE_DISCARD_HSPEED <= 0 OR ctx["DISCARD_TRIED"] { RETURN. }
    IF LANDING_ECONOMY_BRAKE <= 0 OR LANDING_FLEXIBLE_SITE <= 0
            OR ctx["STATE"] <> "BRAKING_BURN" OR vesselNeedsStage() { RETURN. }
    IF ctx["H_SPEED"] > LANDING_STAGE_DISCARD_HSPEED
            OR ctx["H_SPEED"] <= MAX(30, APPROACH_HSPEED)
            OR ctx["V_SPEED"] >= 0 { RETURN. }
    SET ctx["DISCARD_TRIED"] TO TRUE.
    LOCAL check IS landingStageDisposalInfo(ctx).
    mLog("STATS landing-discard check ok=" + check["OK"] + " reason=" + check["REASON"]
        + " stage=" + check["STAGE"] + " height=" + ROUND(check["HEIGHT"],0)
        + " gate=" + ROUND(check["GATE"],0) + " landerDv=" + ROUND(check["DV"],1)
        + " requiredDv=" + ROUND(check["REQUIRED_DV"],1)).
    IF NOT check["OK"] { RETURN. }
    SET ctx["DISCARD_SINCE"] TO TIME:SECONDS.
    SET ctx["DISCARD_PENDING"] TO TRUE.
    _landingSetThrottle(ctx, 0).
    SET SHIP:CONTROL:MAINTHROTTLE TO 0.
    SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
}
