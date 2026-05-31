// ============================================================
// utils.ks  —  General-purpose utilities  (0:/lib/utils.ks)
// ============================================================

GLOBAL FUNCTION fmtDuration {
    PARAMETER secs.
    LOCAL h IS FLOOR(secs / 3600).
    LOCAL m IS FLOOR(MOD(secs, 3600) / 60).
    LOCAL s IS ROUND(MOD(secs, 60), 0).
    RETURN h + "h " + m + "m " + s + "s".
}

GLOBAL FUNCTION printOrbitRef {
    PARAMETER revs.
    PARAMETER currentPeR.
    PARAMETER bodyMu.
    PARAMETER bR.
    LOCAL dayLen IS SHIP:ORBIT:BODY:ROTATIONPERIOD.
    LOCAL period IS dayLen / revs.
    LOCAL sma IS (bodyMu * (period / (2 * CONSTANT:PI))^2)^(1/3).
    LOCAL apR IS 2 * sma - currentPeR.
    LOCAL apAlt IS apR - bR.
    LOCAL ecc IS 1 - currentPeR / sma.
    IF apAlt > 0 AND ecc < 1 AND ecc > 0 {
        PRINT "  " + revs + " rev/day: T=" + ROUND(period,0) + "s  Ap=" + ROUND(apAlt/1000,0) + "km  ecc=" + ROUND(ecc,3).
    }
}

GLOBAL FUNCTION hasFixedPanels {
    PARAMETER dc.
    LOCAL bfsQ IS LIST().
    FOR ch IN dc:CHILDREN { bfsQ:ADD(ch). }
    UNTIL bfsQ:LENGTH = 0 {
        LOCAL p IS bfsQ[0].
        bfsQ:REMOVE(0).
        IF p:HASMODULE("ModuleDeployableSolarPanel") {
            LOCAL m IS p:GETMODULE("ModuleDeployableSolarPanel").
            IF NOT m:HASEVENT("Extend Solar Panel")
                AND NOT m:HASEVENT("Retract Solar Panel")
                AND NOT m:HASEVENT("Toggle Solar Panel") {
                RETURN TRUE.
            }
        }
        FOR ch IN p:CHILDREN { bfsQ:ADD(ch). }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION printSequence {
    PARAMETER seq.
    LOCAL i IS 0.
    UNTIL i >= seq:LENGTH {
        LOCAL line IS "  ".
        LOCAL j IS i.
        UNTIL j >= seq:LENGTH OR line:LENGTH > 42 {
            IF j > i { SET line TO line + " > ". }
            SET line TO line + seq[j].
            SET j TO j + 1.
        }
        PRINT line.
        SET i TO j.
    }
}
