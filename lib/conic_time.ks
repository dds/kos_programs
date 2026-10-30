// Shared elliptic/parabolic/hyperbolic time from periapsis.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION conicTimeFromPe {
    PARAMETER ecc.
    PARAMETER p.
    PARAMETER mu.
    PARAMETER cosine.
    PARAMETER sine.
    IF ABS(ecc-1) < 0.0000001 {
        LOCAL barker IS sine/MAX(0.000000001,1+cosine).
        RETURN 0.5*SQRT(p^3/mu)*(barker+barker^3/3).
    }
    LOCAL semiMajor IS p/(1-ecc^2).
    LOCAL motion IS SQRT(mu/ABS(semiMajor)^3).
    IF ecc > 1 {
        LOCAL sh IS sine*SQRT(ecc^2-1)/(1+ecc*cosine).
        RETURN (ecc*sh-LN(sh+SQRT(1+sh^2)))/motion.
    }
    LOCAL anomaly IS ARCTAN2(SQRT(1-ecc^2)*sine,ecc+cosine).
    RETURN (anomaly*CONSTANT:PI/180-ecc*SIN(anomaly))/motion.
}

