// Compact deorbit node executor for storage-limited landing bands.

GLOBAL FUNCTION executeDeorbitNode {
    PARAMETER nd.
    LOCAL burnDV IS nd:DELTAV:MAG.

    IF SHIP:AVAILABLETHRUST <= 0 {
        FOR eng IN SHIP:ENGINES {
            IF NOT eng:IGNITION { eng:ACTIVATE. }
        }
        WAIT 0.5.
    }
    IF SHIP:AVAILABLETHRUST <= 0 {
        STAGE.
        WAIT 1.
    }
    IF SHIP:AVAILABLETHRUST <= 0 OR SHIP:MASS <= 0 {
        mLogError("Deorbit burn failed: no thrust.").
        REMOVE nd.
        RETURN FALSE.
    }

    LOCAL burnTime IS burnDV / MAX(0.1, SHIP:AVAILABLETHRUST / SHIP:MASS).
    LOCAL startTime IS nd:TIME - burnTime / 2.
    IF startTime < TIME:SECONDS + 5 { SET startTime TO TIME:SECONDS + 5. }
    mLogWarn("STATS deorbit-burn setup dv=" + ROUND(burnDV,1)
        + " eta=" + ROUND(startTime - TIME:SECONDS,1)).

    UNTIL TIME:SECONDS >= startTime - 90 {
        WAIT MIN(10, MAX(0.5, startTime - 90 - TIME:SECONDS)).
    }

    SET SAS TO FALSE.
    LOCK STEERING TO nd:BURNVECTOR.
    UNTIL VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) < 5
            OR TIME:SECONDS >= startTime - 2 {
        LOCK STEERING TO nd:BURNVECTOR.
        WAIT 0.1.
    }

    WAIT UNTIL TIME:SECONDS >= startTime.
    IF VANG(SHIP:FACING:FOREVECTOR, nd:BURNVECTOR) > 15 {
        mLogError("Refusing deorbit burn: off vector.").
        LOCK THROTTLE TO 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        RETURN FALSE.
    }

    LOCAL burnStart IS TIME:SECONDS.
    LOCAL origVec IS nd:BURNVECTOR.
    UNTIL nd:DELTAV:MAG < MAX(0.08, burnDV * 0.01)
            OR TIME:SECONDS - burnStart > burnTime * 2 + 8 {
        LOCK STEERING TO nd:BURNVECTOR.
        IF nd:DELTAV:MAG > 0.1
                AND VDOT(origVec:NORMALIZED, nd:BURNVECTOR:NORMALIZED) < 0 {
            BREAK.
        }
        IF nd:DELTAV:MAG > 3 {
            LOCK THROTTLE TO 1.
        } ELSE IF nd:DELTAV:MAG > 0.4 {
            LOCK THROTTLE TO 0.25.
        } ELSE {
            LOCK THROTTLE TO 0.05.
        }
        WAIT 0.02.
    }

    LOCAL residual IS nd:DELTAV:MAG.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
    SET SAS TO TRUE.
    mLogWarn("STATS deorbit-burn result dv=" + ROUND(burnDV,1)
        + " residual=" + ROUND(residual,2)).
    RETURN TRUE.
}
