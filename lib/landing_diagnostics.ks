// ============================================================
// landing_diagnostics.ks - Bounded flight recorder; no extra terrain scan.
// (0:/lib/landing_diagnostics.ks)
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingDiagnosticStart {
    PARAMETER ctx.
    SET ctx["DIAGNOSTIC"] TO LEXICON("ROWS", LIST(), "BYTES", 0, "DROPPED", 0,
        "CONTROL_ROWS", LIST(), "CONTROL_BYTES", 0,
        "PATH", "0:/logs/archive/_diagnostics/landingdiag_" + slug() + "_"
            + ROUND(TIME:SECONDS * 1000,0) + "_" + bootLogName(),
        "LAST_ATTEMPT", -9999, "LAST_HUD", -9999, "STATE", "",
        "HEADER", "STATS landing-diag schema=2 ut=" + TIME:SECONDS
            + " vessel=" + SHIP:NAME + " body=" + SHIP:BODY:NAME
            + " radius=" + SHIP:BODY:RADIUS + " mu=" + SHIP:BODY:MU
            + " rotation=" + SHIP:BODY:ROTATIONPERIOD
            + " economy=" + LANDING_ECONOMY_BRAKE + " flexible=" + LANDING_FLEXIBLE_SITE
            + " normalSlope=" + LANDING_TERRAIN_MAX_SLOPE
            + " emergencySlope=" + MIN(15, LANDING_DIVERT_EMERGENCY_SLOPE)
            + " maxTilt=" + MAX_TILT + " maxTime=" + LANDING_APPROACH_MAX_TIME
            + " clearance=" + LANDING_BRAKE_CLEARANCE
            + " requireKerbin=" + LANDING_DIVERT_REQUIRE_KERBIN
            + " radioTolerance=" + LANDING_DIVERT_KERBIN_TOLERANCE
            + " requested=" + ctx["REQUESTED_LAT"] + "," + ctx["REQUESTED_LNG"]).
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
        + " gravity=" + ctx["GRAV"]
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
    SET payload TO payload + "STATS landing-diag " + landingDiagnosticSearchText(ctx) + CHAR(10).
    LOCAL completion IS "STATS landing-diag checkpoint ut=" + TIME:SECONDS
        + " finished=" + finished + " dropped=" + capture["DROPPED"].
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
