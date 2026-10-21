// ============================================================
// landing_diagnostics.ks - Bounded flight recorder; no extra terrain scan.
// (0:/lib/landing_diagnostics.ks)
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingDiagnosticStart {
    PARAMETER ctx.
    SET ctx["DIAGNOSTIC"] TO LEXICON("ROWS", LIST(), "BYTES", 0, "DROPPED", 0,
        "CONTROL_ROWS", LIST(), "CONTROL_BYTES", 0,
        "PHASES", LEXICON(), "LAST_UT", TIME:SECONDS, "LAST_STATE", ctx["STATE"],
        "LAST_ACC", MAX(0,SHIP:THRUST) / MAX(0.01,SHIP:MASS),
        "LAST_BOTTOM", _landingBottomRadar(), "LAST_VS", ctx["V_SPEED"],
        "PATH", "0:/logs/archive/_diagnostics/landingdiag_" + slug() + "_"
            + ROUND(TIME:SECONDS * 1000,0) + "_" + bootLogName(),
        "LAST_ATTEMPT", -9999, "LAST_HUD", -9999, "STATE", "",
        "HEADER", "STATS landing-diag schema=3 ut=" + TIME:SECONDS
            + " vessel=" + SHIP:NAME + " body=" + SHIP:BODY:NAME
            + " radius=" + SHIP:BODY:RADIUS + " mu=" + SHIP:BODY:MU
            + " rotation=" + SHIP:BODY:ROTATIONPERIOD
            + " economy=" + LANDING_ECONOMY_BRAKE + " flexible=" + LANDING_FLEXIBLE_SITE
            + " poweredLead=" + LANDING_POWERED_LEAD
            + " stageCredit=" + LANDING_STAGE_BRAKE_CREDIT + " brakeStageDv=" + ctx["BRAKE_STAGE_DV"]
            + " normalSlope=" + LANDING_TERRAIN_MAX_SLOPE
            + " emergencySlope=" + MIN(15, LANDING_DIVERT_EMERGENCY_SLOPE)
            + " maxTilt=" + MAX_TILT + " maxTime=" + LANDING_APPROACH_MAX_TIME
            + " clearance=" + LANDING_BRAKE_CLEARANCE
            + " requireKerbin=" + LANDING_DIVERT_REQUIRE_KERBIN
            + " radioTolerance=" + LANDING_DIVERT_KERBIN_TOLERANCE
            + " mass=" + SHIP:MASS + " remainingDv=" + SHIP:DELTAV:VACUUM
            + " stageDv=" + STAGE:DELTAV:VACUUM + " stage=" + STAGE:NUMBER
            + " startBottom=" + _landingBottomRadar() + " startHs=" + ctx["H_SPEED"]
            + " startVs=" + ctx["V_SPEED"] + " activeAcc=" + ctx["MAX_ACC"]
            + " planAcc=" + ctx["PLAN_ACC"] + " reserveAcc=" + ctx["RESERVE_ACC"]
            + " requested=" + ctx["REQUESTED_LAT"] + "," + ctx["REQUESTED_LNG"]).
}

// Nine FSM states bound this ledger even when detailed ring rows rotate.
// Integrate live thrust/mass, not mass ratios across stage separations.
// These are cadence-dependent impulse estimates; retain the largest gap
// so a paused/slow CPU cannot masquerade as high precision. No I/O here.
LOCAL FUNCTION _landingDiagnosticAccumulate {
    PARAMETER ctx.
    LOCAL capture IS ctx["DIAGNOSTIC"].
    LOCAL phases IS capture["PHASES"].
    LOCAL nowUt IS TIME:SECONDS.
    LOCAL elapsed IS MAX(0,nowUt-capture["LAST_UT"]).
    LOCAL bottom IS _landingBottomRadar().
    LOCAL actualAcc IS MAX(0,SHIP:THRUST) / MAX(0.01,SHIP:MASS).
    LOCAL meanAcc IS (capture["LAST_ACC"]+actualAcc)/2.
    FOR phaseName IN LIST(capture["LAST_STATE"],ctx["STATE"]) {
        IF NOT phases:HASKEY(phaseName) {
            SET phases[phaseName] TO LEXICON("SECONDS",0,"POWERED",0,"IMPULSE",0,
                "SLOW",0,"MAX_GAP",0,"ENTRIES",0,"MIN_BOTTOM",bottom,"MAX_BOTTOM",bottom).
        }
    }
    LOCAL phase IS phases[capture["LAST_STATE"]].
    IF phase["ENTRIES"] = 0 { SET phase["ENTRIES"] TO 1. }
    SET phase["SECONDS"] TO phase["SECONDS"] + elapsed.
    SET phase["IMPULSE"] TO phase["IMPULSE"] + meanAcc * elapsed.
    SET phase["MAX_GAP"] TO MAX(phase["MAX_GAP"],elapsed).
    SET phase["MIN_BOTTOM"] TO MIN(phase["MIN_BOTTOM"],MIN(bottom,capture["LAST_BOTTOM"])).
    SET phase["MAX_BOTTOM"] TO MAX(phase["MAX_BOTTOM"],MAX(bottom,capture["LAST_BOTTOM"])).
    IF meanAcc > 0.001 {
        SET phase["POWERED"] TO phase["POWERED"] + elapsed.
        IF MIN(bottom,capture["LAST_BOTTOM"]) > 50
                AND MAX(ABS(ctx["V_SPEED"]),ABS(capture["LAST_VS"])) < 1 {
            SET phase["SLOW"] TO phase["SLOW"] + elapsed.
        }
    }
    IF capture["LAST_STATE"] <> ctx["STATE"] {
        SET phases[ctx["STATE"]]["ENTRIES"] TO phases[ctx["STATE"]]["ENTRIES"] + 1.
    }
    SET capture["LAST_STATE"] TO ctx["STATE"].
    SET capture["LAST_UT"] TO nowUt.
    SET capture["LAST_ACC"] TO actualAcc.
    SET capture["LAST_BOTTOM"] TO bottom.
    SET capture["LAST_VS"] TO ctx["V_SPEED"].
}

GLOBAL FUNCTION landingDiagnosticHud {
    PARAMETER ctx.
    PARAMETER text.
    PARAMETER targetVs IS "uncontrolled".
    PARAMETER targetHs IS "uncontrolled".
    LOCAL capture IS ctx["DIAGNOSTIC"].
    IF TIME:SECONDS - capture["LAST_HUD"] < 2 { RETURN. }
    SET capture["LAST_HUD"] TO TIME:SECONDS.
    LOCAL exhausted IS FALSE.
    IF ctx["DIVERT_SEARCH"]:HASKEY("EXHAUSTED") {
        SET exhausted TO ctx["DIVERT_SEARCH"]["EXHAUSTED"].
    }
    LOCAL bottom IS _landingBottomRadar().
    // Reuse the actual controller's current/commanded speeds and distances,
    // including hover/refinement commands, rather than reconstructing them.
    landingDiagnosticRecord(ctx, "STATS landing-diag control ut=" + TIME:SECONDS
        + " state=" + ctx["STATE"] + " throttle=" + ctx["TARGET_THROTTLE"]
        + " age=" + (TIME:SECONDS - ctx["STATE_ENTERED"])
        + " pending=" + ctx["DIVERT_PENDING"] + " exhausted=" + exhausted
        + " vsActual=" + ctx["V_SPEED"] + " vsCommand=" + targetVs
        + " hsActual=" + ctx["H_SPEED"] + " hsCommand=" + targetHs
        + " bottom=" + bottom + " asl=" + SHIP:ALTITUDE
        + " targetElevation=" + ctx["TARGET_ELEVATION"]
        + " controlHeight=" + MIN(bottom,_landingTargetHeight(ctx))
        + " burnHeight=" + _landingBurnHeight(ctx)
        + " rawThrottle=" + SHIP:CONTROL:MAINTHROTTLE
        + " pilotThrottle=" + SHIP:CONTROL:PILOTMAINTHROTTLE
        + " thrust=" + SHIP:THRUST + " mass=" + SHIP:MASS
        + " gravity=" + ctx["GRAV"] + " brakeStageDv=" + ctx["BRAKE_STAGE_DV"]
        + " facingUp=" + VDOT(SHIP:FACING:FOREVECTOR,ctx["UP_VEC"])
        + " " + text, TRUE).
}

GLOBAL FUNCTION landingDiagnosticSearchText {
    PARAMETER ctx.
    LOCAL search IS ctx["DIVERT_SEARCH"].
    IF NOT search:HASKEY("CHECKED") { RETURN "not-started". }
    RETURN "emergency=" + search["EMERGENCY"] + " slopeLimit=" + search["SLOPE_LIMIT"]
        + " retry=" + search["RETRIED"] + " exhausted=" + search["EXHAUSTED"]
        + " lat=" + search["LAT"] + " lng=" + search["LNG"]
        + " started=" + search["STARTED"] + " startHs=" + search["START_HS"]
        + " radius=" + search["RADIUS"] + " step=" + search["STEP"]
        + " index=" + search["INDEX"] + " checked=" + search["CHECKED"]
        + " minGrade=" + search["MIN_GRADE"] + " lastReason=" + search["LAST_REASON"]
        + " reachRejected=" + search["REJECTS"]["reachability"]
        + " terrainRejected=" + search["REJECTS"]["terrain-grade"]
        + " clearanceRejected=" + search["REJECTS"]["altitude-clearance"]
        + " lightRejected=" + search["REJECTS"]["light"].
}

GLOBAL FUNCTION landingDiagnosticRecord {
    PARAMETER ctx.
    PARAMETER row.
    PARAMETER control IS FALSE.
    LOCAL capture IS ctx["DIAGNOSTIC"].
    // A prolonged hold must not evict all the terrain evidence that caused
    // it. Reserve half the buffer for control history, half for samples/events.
    LOCAL bucket IS "ROWS".
    LOCAL sizeKey IS "BYTES".
    IF control { SET bucket TO "CONTROL_ROWS". SET sizeKey TO "CONTROL_BYTES". }
    capture[bucket]:ADD(row).
    SET capture[sizeKey] TO capture[sizeKey] + row:LENGTH.
    UNTIL capture[bucket]:LENGTH <= 32 AND capture[sizeKey] <= 8000 {
        SET capture[sizeKey] TO capture[sizeKey] - capture[bucket][0]:LENGTH.
        capture[bucket]:REMOVE(0).
        SET capture["DROPPED"] TO capture["DROPPED"] + 1.
    }
}

GLOBAL FUNCTION landingDiagnosticSample {
    PARAMETER ctx.
    PARAMETER site.
    PARAMETER siteLat.
    PARAMETER siteLng.
    PARAMETER passName.
    PARAMETER slopeLimit.
    // Keep every terrain measurement. Cheap reachability rejections are
    // represented by their pass totals and every tenth candidate.
    IF site["REASON"] = "reachability" AND ctx["DIVERT_SEARCH"]:HASKEY("CHECKED") {
        IF ctx["DIVERT_SEARCH"]["CHECKED"] > 1
                AND MOD(ctx["DIVERT_SEARCH"]["CHECKED"],10) <> 0 { RETURN. }
    }
    LOCAL neighbors IS "unmeasured".
    IF site["TERRAIN"]:LENGTH = 4 {
        SET neighbors TO "" + site["TERRAIN"][0] + "," + site["TERRAIN"][1]
            + "," + site["TERRAIN"][2] + "," + site["TERRAIN"][3].
    }
    landingDiagnosticRecord(ctx, "STATS landing-diag sample ut=" + TIME:SECONDS
        + " pass=" + passName + " limit=" + slopeLimit + " state=" + ctx["STATE"]
        + " lat=" + siteLat + " lng=" + siteLng + " ok=" + site["OK"]
        + " reason=" + site["REASON"] + " grade=" + site["GRADE"]
        + " elevation=" + site["ELEVATION"] + " neighbors20m=" + neighbors
        + " distance=" + site["DIST"] + " transit=" + site["TRANSIT"]
        + " asl=" + SHIP:ALTITUDE + " bottom=" + _landingBottomRadar()
        + " hs=" + ctx["H_SPEED"] + " vs=" + ctx["V_SPEED"]
        + " lateralAcc=" + lmApproachAcceleration(ctx["MAX_ACC"],ctx["GRAV"])
        + " sun=" + site["SUN"] + " kerbin=" + site["KERBIN"]).
}

GLOBAL FUNCTION landingDiagnosticTick {
    PARAMETER ctx.
    PARAMETER finished IS FALSE.
    LOCAL capture IS ctx["DIAGNOSTIC"].
    _landingDiagnosticAccumulate(ctx).
    IF capture["STATE"] <> ctx["STATE"] OR finished {
        landingDiagnosticRecord(ctx, "STATS landing-diag state=" + ctx["STATE"]
            + " finished=" + finished + " ut=" + TIME:SECONDS
            + " bottom=" + _landingBottomRadar() + " hs=" + ctx["H_SPEED"]
            + " vs=" + ctx["V_SPEED"] + " throttle=" + ctx["TARGET_THROTTLE"]
            + " rawThrottle=" + SHIP:CONTROL:MAINTHROTTLE
            + " pilotThrottle=" + SHIP:CONTROL:PILOTMAINTHROTTLE + " thrust=" + SHIP:THRUST
            + " activeAcc=" + ctx["MAX_ACC"] + " reserveAcc=" + ctx["RESERVE_ACC"]
            + " gravity=" + ctx["GRAV"] + " planAcc=" + ctx["PLAN_ACC"]
            + " targetHeight=" + _landingTargetHeight(ctx)
            + " localElevation=" + ctx["DIVERT_ELEVATION"]
            + " target=" + ctx["TARGET_LAT"] + "," + ctx["TARGET_LNG"]
            + " stage=" + STAGE:NUMBER + " mass=" + SHIP:MASS).
        SET capture["STATE"] TO ctx["STATE"].
    }
    // Archive writes are synchronous. Never extend a burn/control tick or
    // force a coast/hover for logging. Only a genuinely quiet coast with a
    // full minute to the conservative braking gate may export in flight.
    IF NOT (SHIP:THRUST <= 0.001) OR NOT (SHIP:CONTROL:MAINTHROTTLE <= 0)
            OR NOT (SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) { RETURN FALSE. }
    IF NOT finished {
        IF ABORT OR ctx["STATE"] <> "COAST" OR ctx["TARGET_THROTTLE"] <> 0
                OR ctx["DISCARD_PENDING"] OR TIME:SECONDS < ctx["STAGE_UNTIL"]
                OR TIME:SECONDS - capture["LAST_ATTEMPT"] < 15 { RETURN FALSE. }
    }
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    IF NOT finished {
        // Even unsuccessful export eligibility checks are rate-limited;
        // do not run a second stopping-envelope solve every coast tick.
        SET capture["LAST_ATTEMPT"] TO TIME:SECONDS.
        LOCAL gate IS _landingBrakeGateInfo(ctx).
        IF NOT (gate["V_ETA"] >= 60) OR NOT (gate["H_ETA"] >= 60) { RETURN FALSE. }
    }
    LOCAL payload IS capture["HEADER"] + CHAR(10).
    FOR row IN capture["ROWS"] { SET payload TO payload + row + CHAR(10). }
    FOR row IN capture["CONTROL_ROWS"] { SET payload TO payload + row + CHAR(10). }
    FOR phaseName IN capture["PHASES"]:KEYS {
        LOCAL phase IS capture["PHASES"][phaseName].
        SET payload TO payload + "STATS landing-diag summary cumulative=true state=" + phaseName
            + " seconds=" + ROUND(phase["SECONDS"],3) + " poweredSeconds=" + ROUND(phase["POWERED"],3)
            + " impulseDv=" + ROUND(phase["IMPULSE"],3) + " slowDescentSeconds=" + ROUND(phase["SLOW"],3)
            + " entries=" + phase["ENTRIES"] + " maxSampleGap=" + ROUND(phase["MAX_GAP"],3)
            + " minBottom=" + ROUND(phase["MIN_BOTTOM"],2) + " maxBottom=" + ROUND(phase["MAX_BOTTOM"],2)
            + CHAR(10).
    }
    SET payload TO payload + "STATS landing-diag " + landingDiagnosticSearchText(ctx) + CHAR(10).
    LOCAL completion IS "STATS landing-diag checkpoint ut=" + TIME:SECONDS
        + " finished=" + finished + " dropped=" + capture["DROPPED"]
        + " remainingDv=" + SHIP:DELTAV:VACUUM + " mass=" + SHIP:MASS.
    SET payload TO payload + completion.
    FOR dir_ IN LIST("0:/logs", "0:/logs/archive", "0:/logs/archive/_diagnostics") {
        IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
        IF NOT EXISTS(dir_) { CREATEDIR(dir_). }
    }
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    LOCAL dest IS capture["PATH"].
    LOG payload TO dest.
    // A detected disconnect retains the buffer for a later checkpoint.
    // Repeated rows after reconnect are preferable to losing that evidence.
    IF NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    IF finished {
        LOCAL verified IS OPEN(dest):READALL:STRING:CONTAINS(completion).
        IF verified {
            LOCAL sidecar IS dest + ".boot.log".
            IF HOMECONNECTION:ISCONNECTED AND NOT EXISTS(sidecar) { COPYPATH(flightLogPath(),sidecar). }
            mLog("Landing diagnostic verified: " + dest).
        }
        IF NOT verified { RETURN FALSE. }
    }
    SET capture["ROWS"] TO LIST().
    SET capture["BYTES"] TO 0.
    SET capture["CONTROL_ROWS"] TO LIST().
    SET capture["CONTROL_BYTES"] TO 0.
    IF NOT finished { mLog("Landing diagnostic checkpoint: " + dest). }
    // Re-measure after any I/O before the owner evaluates its next gate.
    _landingCacheTick(ctx).
    RETURN TRUE.
}
