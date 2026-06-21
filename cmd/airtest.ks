// ============================================================
// cmd/airtest.ks  —  Airplane assist shakeout card  (0:/cmd/airtest.ks)
//
// Scripted flight-test card for the PID assists: engages each
// mode, applies step inputs, measures the response, and logs
// STATS lines (plus 1s-interval observation telemetry to the
// archive) so gains can be tuned from the logs.
//
// The heading test self-checks the bank direction: if the error
// GROWS after the step, HDG_BANK_SIGN is flipped live and the
// step retried — note the warning and bake the flip into the
// craft's configure hook afterward.
//
// How to run (sim recommended):
//   1. Boot the plane, press a key within 5s for MANUAL mode
//      (the mission loop owns the terminal otherwise).
//   2. Take off by hand, climb to a safe test altitude (>1500m
//      AGL), trim roughly level, leave throttle where you want it.
//   3. RUNPATH("0:/cmd/airtest.ks").
//      RUNPATH("0:/cmd/airtest.ks", LEX("only", "hdg")).
//      RUNPATH("0:/cmd/airtest.ks", LEX("dwell", 30)).
//
// Tests: roll (wing leveler), alt (+400m step), hdg (+90deg
// step), spd (+30 m/s step — autopilot owns throttle during it).
// ============================================================

PARAMETER opts IS LEXICON().

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL only IS "".
LOCAL dwell IS 20.
IF opts:HASKEY("only")  { SET only TO opts["only"]. }
IF opts:HASKEY("dwell") { SET dwell TO opts["dwell"]. }

LOCAL FUNCTION _want {
    PARAMETER name.
    RETURN only = "" OR only = name.
}

LOCAL FUNCTION _wrap180 {
    PARAMETER a.
    UNTIL a <= 180 { SET a TO a - 360. }
    UNTIL a > -180 { SET a TO a + 360. }
    RETURN a.
}

LOCAL FUNCTION _bank {
    RETURN _wrap180(SHIP:FACING:ROLL).
}

// Drive the assists ourselves — in manual mode no mission loop
// is calling planeUpdate().
LOCAL FUNCTION _fly {
    PARAMETER seconds.
    LOCAL endT IS TIME:SECONDS + seconds.
    UNTIL TIME:SECONDS >= endT {
        planeUpdate().
        WAIT 0.05.
    }
}

LOCAL err IS FALSE.
IF NOT PLANE_PID_CTRL {
    PRINT "ERROR: PID_CTRL is disabled for this craft.".
    SET err TO TRUE.
}
IF SHIP:STATUS <> "FLYING" OR ALT:RADAR < 800 {
    PRINT "ERROR: be airborne above 800m AGL first"
        + " (status=" + SHIP:STATUS
        + " radar=" + ROUND(ALT:RADAR, 0) + "m).".
    SET err TO TRUE.
}

IF NOT err {
    IF NOT planeActive { planeInit(). }

    // High-rate telemetry straight to the archive for this run.
    LOCAL oldInterval IS OBS_CFG["INTERVAL"].
    SET OBS_CFG["INTERVAL"] TO 1.
    observeStart().

    PRINT " ".
    PRINT "  -- AIRTEST CARD: " + SHIP:NAME + " --".
    mLogWarn("STATS airtest start craft=" + SHIP:NAME
        + " alt=" + ROUND(SHIP:ALTITUDE, 0)
        + " spd=" + ROUND(SHIP:AIRSPEED, 0)
        + " dwell=" + dwell).

    // ---- 1. Wing leveler ----
    IF _want("roll") {
        PRINT "  [roll] wing leveler, " + dwell + "s.".
        wingLevelerOn().
        _fly(dwell).
        mLogWarn("STATS airtest roll residualBank=" + ROUND(ABS(_bank()), 2)).
        wingLevelerOff().
    }

    // ---- 2. Altitude hold: capture, then +400m step ----
    IF _want("alt") {
        LOCAL alt0 IS ROUND(SHIP:ALTITUDE, 0).
        PRINT "  [alt] hold " + alt0 + "m, then step +400m.".
        altHoldOn(alt0).
        wingLevelerOn().
        _fly(dwell).
        LOCAL altTgt IS alt0 + 400.
        altHoldOn(altTgt).
        LOCAL maxAlt IS SHIP:ALTITUDE.
        LOCAL capT IS -1.
        LOCAL t0 IS TIME:SECONDS.
        UNTIL TIME:SECONDS - t0 > 90 {
            planeUpdate().
            IF SHIP:ALTITUDE > maxAlt { SET maxAlt TO SHIP:ALTITUDE. }
            IF capT < 0 AND ABS(SHIP:ALTITUDE - altTgt) < 30 {
                SET capT TO ROUND(TIME:SECONDS - t0, 1).
            }
            WAIT 0.05.
        }
        mLogWarn("STATS airtest alt step=400 captureT=" + capT
            + " overshoot=" + ROUND(MAX(0, maxAlt - altTgt), 0)
            + " finalErr=" + ROUND(SHIP:ALTITUDE - altTgt, 0)).
        altHoldOff().
        wingLevelerOff().
    }

    // ---- 3. Heading hold: +90deg step with bank-sign self-check ----
    IF _want("hdg") {
        LOCAL hdg0 IS ROUND(SHIP:FACING:YAW, 0).
        LOCAL hdgTgt IS MOD(hdg0 + 90, 360).
        PRINT "  [hdg] hold " + hdg0 + ", then step to " + hdgTgt + ".".
        altHoldOn(SHIP:ALTITUDE).
        hdgHoldOn(hdg0).
        _fly(10).

        LOCAL attempts IS 0.
        LOCAL capT IS -1.
        UNTIL attempts >= 2 {
            SET attempts TO attempts + 1.
            hdgHoldOn(hdgTgt).
            LOCAL t0 IS TIME:SECONDS.
            LOCAL maxBank IS 0.
            LOCAL signBad IS FALSE.
            UNTIL TIME:SECONDS - t0 > 120 {
                planeUpdate().
                LOCAL e IS ABS(_wrap180(hdgTgt - SHIP:FACING:YAW)).
                IF ABS(_bank()) > maxBank { SET maxBank TO ABS(_bank()). }
                IF capT < 0 AND e < 5 {
                    SET capT TO ROUND(TIME:SECONDS - t0, 1).
                    BREAK.
                }
                // Error growing past the initial 90 means we banked
                // the wrong way — flip the sign and retry the step.
                IF TIME:SECONDS - t0 > 12 AND e > 100 {
                    SET signBad TO TRUE.
                    BREAK.
                }
                WAIT 0.05.
            }
            IF signBad AND attempts < 2 {
                SET PLANE_HDG_BANK_SIGN TO -PLANE_HDG_BANK_SIGN.
                mLogWarn("AIRTEST: heading error grew — flipping HDG_BANK_SIGN to "
                    + PLANE_HDG_BANK_SIGN
                    + ". Bake this into the craft configure hook!").
                HUDTEXT("HDG_BANK_SIGN flipped: "
                    + PLANE_HDG_BANK_SIGN, 8, 2, 16, YELLOW, FALSE).
            } ELSE {
                mLogWarn("STATS airtest hdg step=90 captureT=" + capT
                    + " maxBank=" + ROUND(maxBank, 1)
                    + " sign=" + PLANE_HDG_BANK_SIGN
                    + " finalErr=" + ROUND(_wrap180(hdgTgt - SHIP:FACING:YAW), 1)).
                BREAK.
            }
        }
        hdgHoldOff().
        altHoldOff().
    }

    // ---- 4. Speed hold: capture, then +30 m/s step ----
    IF _want("spd") {
        LOCAL spd0 IS ROUND(SHIP:AIRSPEED, 0).
        PRINT "  [spd] hold " + spd0 + " m/s, then step +30 (AP owns throttle).".
        wingLevelerOn().
        spdHoldOn(spd0).
        _fly(dwell).
        spdHoldOn(spd0 + 30).
        _fly(45).
        mLogWarn("STATS airtest spd step=30 finalErr="
            + ROUND(SHIP:AIRSPEED - (spd0 + 30), 1)).
        spdHoldOff().
        wingLevelerOff().
        PRINT "  [spd] done — YOUR throttle again.".
    }

    apOff().
    SET OBS_CFG["INTERVAL"] TO oldInterval.
    observeStop().

    PRINT " ".
    PRINT "  AIRTEST COMPLETE — you have the airplane.".
    PRINT "  Results: STATS lines in flight log + 0:/logs/obs/.".
    mLogWarn("STATS airtest done sign=" + PLANE_HDG_BANK_SIGN).
}
