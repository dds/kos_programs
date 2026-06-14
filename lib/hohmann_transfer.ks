// ============================================================
// hohmann_transfer.ks - Lightweight same-SOI transfer helpers
// (0:/lib/hohmann_transfer.ks)
// ============================================================

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
