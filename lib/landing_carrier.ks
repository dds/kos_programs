// landing_carrier.ks - tiny emergency carrier landing assist.

LOCAL FUNCTION _lcNum {
    PARAMETER key.
    PARAMETER fallback.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN fallback.
}

LOCAL FUNCTION _lcTag {
    IF CFG:HASKEY("LANDING_ASSIST_DECOUPLER_TAG") {
        RETURN CFG["LANDING_ASSIST_DECOUPLER_TAG"].
    }
    RETURN "probe_decoupler".
}

LOCAL FUNCTION _lcHVel {
    LOCAL upVec IS SHIP:UP:VECTOR.
    RETURN SHIP:VELOCITY:SURFACE - (VDOT(SHIP:VELOCITY:SURFACE, upVec) * upVec).
}

LOCAL FUNCTION _lcMaxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

LOCAL FUNCTION _lcGrav {
    LOCAL r IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    RETURN SHIP:BODY:MU / (r^2).
}

LOCAL FUNCTION _lcSteer {
    PARAMETER hVel.
    PARAMETER hSpeed.
    PARAMETER tiltDeg.
    LOCAL upVec IS SHIP:UP:VECTOR.
    IF hSpeed < 0.5 { RETURN upVec. }
    LOCAL lean IS MIN(SIN(tiltDeg), hSpeed / 25).
    RETURN (upVec + (-hVel):NORMALIZED * lean):NORMALIZED.
}

LOCAL FUNCTION _lcDecoupler {
    PARAMETER tagName.
    FOR p IN SHIP:PARTS {
        IF p:TAG = tagName {
            IF p:HASMODULE("ModuleDecouple")
                    OR p:HASMODULE("ModuleAnchoredDecoupler") {
                RETURN p.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _lcDecouple {
    PARAMETER p.
    IF p = 0 { RETURN FALSE. }
    IF p:HASMODULE("ModuleDecouple") {
        p:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
        RETURN TRUE.
    }
    IF p:HASMODULE("ModuleAnchoredDecoupler") {
        p:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
        RETURN TRUE.
    }
    RETURN FALSE.
}

LOCAL FUNCTION _lcThrottleForV {
    PARAMETER targetV.
    PARAMETER vSpeed.
    PARAMETER gain.
    PARAMETER maxAcc.
    IF maxAcc <= 0 { RETURN 0. }
    IF vSpeed > targetV + 0.5 { RETURN 0. }
    LOCAL desired IS (targetV - vSpeed) * gain.
    RETURN MAX(0, MIN(_lcNum("LANDING_ASSIST_THROTTLE", 1), (_lcGrav() + desired) / maxAcc)).
}

LOCAL FUNCTION _lcCarrierLand {
    LOCAL tagName IS _lcTag().
    LOCAL decoupler IS _lcDecoupler(tagName).
    IF decoupler = 0 {
        mLogWarn("No assist decoupler tagged '" + tagName + "'; landing carrier only.").
    }

    SET SAS TO FALSE.
    LOCAL lastMode IS "".
    LOCAL nextStatsAlt IS 5000.
    LOCAL finalAlt IS _lcNum("LANDING_ASSIST_SURFACE_FINAL_ALT", 250).
    LOCAL finalSpeed IS _lcNum("LANDING_ASSIST_SURFACE_FINAL_SPEED", 0.8).
    LOCAL finalMax IS _lcNum("LANDING_ASSIST_SURFACE_FINAL_MAX_SPEED", 4).
    LOCAL panicAlt IS _lcNum("LANDING_ASSIST_SURFACE_PANIC_ALT", 2000).
    LOCAL panicSpeed IS _lcNum("LANDING_ASSIST_SURFACE_PANIC_SPEED", 120).
    LOCAL hFinal IS _lcNum("LANDING_ASSIST_SURFACE_FINAL_HSPEED", 2).
    LOCAL brakeTilt IS _lcNum("LANDING_ASSIST_SURFACE_BRAKE_TILT", 25).
    LOCAL dropAlt IS _lcNum("LANDING_ASSIST_SURFACE_DROP_ALT", 600).
    LOCAL dropMaxV IS _lcNum("LANDING_ASSIST_SURFACE_DROP_MAX_VSPEED", 120).

    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
        LOCAL hVel IS _lcHVel().
        LOCAL hSpeed IS hVel:MAG.
        LOCAL radarAlt IS ALT:RADAR.
        LOCAL vSpeed IS SHIP:VERTICALSPEED.
        LOCAL speed IS SQRT(hSpeed^2 + MAX(0, -vSpeed)^2).
        LOCAL mode_ IS "DROP".

        IF radarAlt <= panicAlt AND speed >= panicSpeed {
            SET mode_ TO "HBRAKE".
        } ELSE IF radarAlt <= finalAlt {
            SET mode_ TO "FINAL".
        } ELSE IF hSpeed > hFinal AND radarAlt <= panicAlt {
            SET mode_ TO "HBRAKE".
        } ELSE IF radarAlt <= dropAlt OR -vSpeed >= dropMaxV {
            SET mode_ TO "VBRAKE".
        }

        IF mode_ <> lastMode {
            mLogWarn("STATS carrier mode=" + mode_
                + " alt=" + ROUND(radarAlt,1)
                + " h=" + ROUND(hSpeed,1)
                + " v=" + ROUND(vSpeed,1)
                + " speed=" + ROUND(speed,1)).
            SET lastMode TO mode_.
        }

        IF mode_ = "HBRAKE" {
            LOCK STEERING TO _lcSteer(hVel, hSpeed, brakeTilt).
        } ELSE {
            LOCK STEERING TO _lcSteer(hVel, hSpeed, _lcNum("LANDING_ASSIST_MAX_TILT", 12)).
        }

        LOCAL maxAcc IS _lcMaxAcc().
        IF mode_ = "DROP" {
            LOCK THROTTLE TO 0.
        } ELSE IF mode_ = "HBRAKE" {
            IF vSpeed > 2 {
                LOCK THROTTLE TO 0.
            } ELSE {
                LOCK THROTTLE TO _lcNum("LANDING_ASSIST_SURFACE_BRAKE_THROTTLE", 1).
            }
        } ELSE IF mode_ = "VBRAKE" {
            LOCAL targetVb IS -MAX(finalMax, MIN(_lcNum("LANDING_ASSIST_DESCENT_SPEED", 35), radarAlt * 0.08)).
            LOCK THROTTLE TO _lcThrottleForV(targetVb, vSpeed, 0.45, maxAcc).
        } ELSE {
            LOCAL targetV IS -MAX(finalSpeed, MIN(finalMax, radarAlt * 0.05)).
            IF radarAlt < 25 { SET targetV TO -finalSpeed. }
            LOCK THROTTLE TO _lcThrottleForV(targetV, vSpeed, 0.6, maxAcc).
        }

        IF radarAlt < nextStatsAlt {
            mLogWarn("STATS carrier descent alt=" + ROUND(radarAlt,1)
                + " h=" + ROUND(hSpeed,2)
                + " v=" + ROUND(vSpeed,2)
                + " maxAcc=" + ROUND(maxAcc,2)).
            SET nextStatsAlt TO nextStatsAlt / 2.
            IF nextStatsAlt < 100 { SET nextStatsAlt TO 100. }
        }
        WAIT 0.05.
    }

    LOCK THROTTLE TO 0.
    WAIT _lcNum("LANDING_ASSIST_SURFACE_SETTLE_TIME", 2).
    mLogWarn("STATS carrier touchdown status=" + SHIP:STATUS
        + " h=" + ROUND(_lcHVel():MAG,2)
        + " v=" + ROUND(SHIP:VERTICALSPEED,2)).

    IF _lcNum("LANDING_ASSIST_SURFACE_TIPOVER", 1) > 0 {
        LOCK STEERING TO SHIP:FACING:RIGHTVECTOR.
        WAIT _lcNum("LANDING_ASSIST_SURFACE_TIP_TIME", 1.5).
    }
    IF decoupler <> 0 {
        mLog("Carrier handoff: decoupling rover.").
        _lcDecouple(decoupler).
        WAIT _lcNum("LANDING_ASSIST_SURFACE_RELEASE_SETTLE", 0.5).
    }

    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    RETURN TRUE.
}

GLOBAL FUNCTION phaseLandAssist {
    mLogPhase("LANDING ASSIST").
    mLogWarn("STATS land-assist tiny setup alt=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(_lcHVel():MAG,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)).
    IF _lcCarrierLand() {
        nextPhase(fr3Seq).
    } ELSE {
        stateSet("phase", "LAND_ASSIST").
        LOCK THROTTLE TO 0.
        yieldToPrompt().
    }
}
