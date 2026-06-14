// ============================================================
// hohmann_transfer.ks - Lightweight same-SOI transfer helpers
// (0:/lib/hohmann_transfer.ks)
// ============================================================

LOCAL FUNCTION _hohmannNorm360 {
    PARAMETER angle.
    LOCAL result IS angle.
    UNTIL result >= 0 { SET result TO result + 360. }
    UNTIL result < 360 { SET result TO result - 360. }
    RETURN result.
}

// Circular-coplanar Hohmann seed between two same-SOI orbital radii.
// rShip/rTarget are body-centered radii, not altitudes.
GLOBAL FUNCTION _hohmannSeed {
    PARAMETER rShip.
    PARAMETER rTarget.
    PARAMETER mu.
    PARAMETER targetPeriod.

    LOCAL transferA IS (rShip + rTarget) / 2.
    LOCAL tof IS CONSTANT:PI * SQRT(transferA^3 / mu).
    LOCAL vShip IS SQRT(mu / rShip).
    LOCAL vDepart IS SQRT(mu * (2 / rShip - 1 / transferA)).
    LOCAL dv IS vDepart - vShip.
    LOCAL targetSweep IS (360 / targetPeriod) * tof.
    LOCAL idealPhase IS 180 - targetSweep.

    RETURN LEXICON(
        "A", transferA,
        "TOF", tof,
        "DV", dv,
        "TARGET_SWEEP", targetSweep,
        "IDEAL_PHASE", idealPhase
    ).
}

// Solve when phaseAngle() will reach the ideal Hohmann phase.
// phaseAngle is positive when the ship is behind the target. If the
// ship is lower/faster than the target, that phase decreases; if the
// ship is higher/slower, it increases. The wait direction must follow
// that sign or near-ready windows get wrapped into almost a full
// synodic period.
GLOBAL FUNCTION _hohmannPhaseWait {
    PARAMETER currentPhase.
    PARAMETER idealPhase.
    PARAMETER shipPeriod.
    PARAMETER targetPeriod.
    PARAMETER minWait IS 60.

    LOCAL shipRate IS 360 / shipPeriod.
    LOCAL targetRate IS 360 / targetPeriod.
    LOCAL phaseRate IS targetRate - shipRate.
    IF ABS(phaseRate) < 0.000001 {
        RETURN LEXICON("WAIT", 0, "SYNODIC", 0, "DIFF", 0, "PHASE_RATE", phaseRate).
    }

    LOCAL phaseDiff IS 0.
    IF phaseRate < 0 {
        SET phaseDiff TO _hohmannNorm360(currentPhase - idealPhase).
    } ELSE {
        SET phaseDiff TO _hohmannNorm360(idealPhase - currentPhase).
    }

    LOCAL waitTime IS phaseDiff / ABS(phaseRate).
    LOCAL synodicPeriod IS ABS(shipPeriod * targetPeriod / (shipPeriod - targetPeriod)).
    IF waitTime < minWait { SET waitTime TO waitTime + synodicPeriod. }

    RETURN LEXICON(
        "WAIT", waitTime,
        "SYNODIC", synodicPeriod,
        "DIFF", phaseDiff,
        "PHASE_RATE", phaseRate
    ).
}

// _findClosestApproach - find minimum separation between ship and
// a target over a time window. POSITIONAT reflects maneuver nodes,
// so this can evaluate planned burns without the full element
// targeting library.
GLOBAL FUNCTION _findClosestApproach {
    PARAMETER tgt, tStart, tEnd, steps.

    LOCAL dt IS (tEnd - tStart) / steps.
    LOCAL bestT IS tStart.
    LOCAL bestD IS 9e15.

    LOCAL t IS tStart.
    UNTIL t > tEnd {
        LOCAL sep IS (POSITIONAT(SHIP, t) - POSITIONAT(tgt, t)):MAG.
        IF sep < bestD {
            SET bestD TO sep.
            SET bestT TO t.
        }
        SET t TO t + dt.
    }

    LOCAL a IS MAX(tStart, bestT - dt * 2).
    LOCAL b IS MIN(tEnd, bestT + dt * 2).
    LOCAL gr IS (SQRT(5) + 1) / 2.

    FROM { LOCAL i IS 0. } UNTIL i >= 15 STEP { SET i TO i + 1. } DO {
        LOCAL c IS b - (b - a) / gr.
        LOCAL d IS a + (b - a) / gr.
        LOCAL fc IS (POSITIONAT(SHIP, c) - POSITIONAT(tgt, c)):MAG.
        LOCAL fd IS (POSITIONAT(SHIP, d) - POSITIONAT(tgt, d)):MAG.
        IF fc < fd {
            SET b TO d.
        } ELSE {
            SET a TO c.
        }
    }

    LOCAL midT IS (a + b) / 2.
    LOCAL midD IS (POSITIONAT(SHIP, midT) - POSITIONAT(tgt, midT)):MAG.
    RETURN LEXICON("time", midT, "distance", midD).
}
