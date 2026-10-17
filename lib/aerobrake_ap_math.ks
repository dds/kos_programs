// Finite, planar vacuum prediction. Real drag/pressure remain live guards.
// Numeric vectors use a frozen orbital plane; no RAW vector crosses a WAIT.
@LAZYGLOBAL OFF.

GLOBAL FUNCTION aeroApOrbit {
    PARAMETER pos.
    PARAMETER vel.
    PARAMETER mu.
    LOCAL radiusMag IS pos:MAG.
    LOCAL h2 IS VCRS(pos,vel):MAG^2.
    LOCAL energy IS vel:MAG^2/2-mu/radiusMag.
    LOCAL ecc IS SQRT(MAX(0,1+2*energy*h2/mu^2)).
    LOCAL apo IS 1e30.
    IF energy < 0 { SET apo TO -mu/energy-h2/(mu*(1+ecc)). }
    RETURN LEXICON("PE",h2/(mu*(1+ecc)),"AP",apo,"E",energy,"ECC",ecc,"H2",h2).
}

// Project the energy-reducing direction onto the constant-periapsis plane.
// A small gradient component corrects Pe drift toward the entry target.
GLOBAL FUNCTION aeroApDirection {
    PARAMETER pos.
    PARAMETER vel.
    PARAMETER mu.
    PARAMETER targetRadius.
    PARAMETER acceleration.
    LOCAL orbitInfo IS aeroApOrbit(pos,vel,mu).
    LOCAL radiusMag IS pos:MAG.
    LOCAL radial IS pos/radiusMag.
    LOCAL vr IS VDOT(vel,radial).
    LOCAL transverse IS vel-vr*radial.
    LOCAL rp IS orbitInfo["PE"].
    LOCAL denominator IS mu*rp-orbitInfo["H2"].
    IF ABS(denominator) < 1 OR transverse:MAG < 1 { RETURN -vel:NORMALIZED. }
    LOCAL gradient IS rp^3/denominator
        * (vr*radial+(1-radiusMag^2/rp^2)*transverse).
    IF gradient:MAG < 0.05 { RETURN -transverse:NORMALIZED. }
    LOCAL normal IS gradient:NORMALIZED.
    LOCAL along IS -vel+normal*VDOT(vel,normal).
    IF along:MAG < 0.01*vel:MAG { RETURN V(0,0,0). }
    // Pe is insensitive to thrust at Pe itself. Do not demand a large
    // radial correction there just to remove a few metres of conic drift.
    LOCAL peError IS targetRadius-rp.
    SET peError TO MAX(0,peError-100)+MIN(0,peError+100).
    LOCAL correction IS MAX(-0.25,MIN(0.25,
        peError/(30*MAX(0.01,acceleration)*gradient:MAG))).
    RETURN along:NORMALIZED*SQRT(1-correction^2)+normal*correction.
}

// Positive time from Pe to an outbound radius; inbound is its negative.
LOCAL FUNCTION _aeroApConicTime {
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

GLOBAL FUNCTION aerobrakeApEntryEta {
    PARAMETER atmHeight.
    IF SHIP:ALTITUDE <= atmHeight { RETURN 0. }
    LOCAL pos IS SHIP:POSITION-SHIP:BODY:POSITION.
    LOCAL vel IS SHIP:VELOCITY:ORBIT.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL info IS aeroApOrbit(pos,vel,mu).
    IF info["PE"] >= SHIP:BODY:RADIUS+atmHeight OR info["ECC"] < 0.000001 { RETURN -1. }
    IF info["E"] >= 0 AND VDOT(pos,vel) >= 0 { RETURN -1. }
    LOCAL p IS info["H2"]/mu.
    LOCAL cosine IS MAX(-1,MIN(1,(p/(SHIP:BODY:RADIUS+atmHeight)-1)/info["ECC"])).
    LOCAL beforePe IS _aeroApConicTime(info["ECC"],p,mu,cosine,SQRT(MAX(0,1-cosine^2))).
    RETURN MAX(0,ETA:PERIAPSIS-beforePe).
}

GLOBAL FUNCTION aeroApPredict {
    PARAMETER ctx.
    PARAMETER delay.
    PARAMETER stepSec IS 2.
    LOCAL pos IS ctx["POS"].
    LOCAL vel IS ctx["VEL"].
    LOCAL elapsed IS 0.
    // RK2 coast to ignition, then variable-mass RK2 powered guidance.
    UNTIL elapsed >= delay OR ABORT {
        LOCAL dt IS MIN(5,delay-elapsed).
        LOCAL acc1 IS -ctx["MU"]*pos/pos:MAG^3.
        LOCAL midpoint IS pos+vel*dt/2.
        SET pos TO pos+(vel+acc1*dt/2)*dt.
        SET vel TO vel-ctx["MU"]*midpoint/midpoint:MAG^3*dt.
        SET elapsed TO elapsed+dt.
    }
    LOCAL burnTime IS 0.
    LOCAL applied IS 0.
    LOCAL duration IS ctx["VE"]/ctx["ACC"]*(1-CONSTANT:E^(-ctx["BUDGET"]/ctx["VE"])).
    LOCAL info IS aeroApOrbit(pos,vel,ctx["MU"]).
    LOCAL reason IS "available-fuel".
    UNTIL burnTime >= duration OR ABORT {
        SET info TO aeroApOrbit(pos,vel,ctx["MU"]).
        IF info["PE"] < ctx["LOW"]+100 OR info["PE"] > ctx["HIGH"]-100 {
            SET reason TO "periapsis-corridor". BREAK.
        }
        IF info["AP"] <= ctx["TARGET_AP"] { SET reason TO "apoapsis-target". BREAK. }
        LOCAL acc IS ctx["ACC"]/(1-ctx["ACC"]*burnTime/ctx["VE"]).
        LOCAL direction IS aeroApDirection(pos,vel,ctx["MU"],ctx["TARGET_PE"],acc).
        IF direction:MAG < 0.5 OR VDOT(direction,vel) >= -0.01*vel:MAG {
            SET reason TO "no-useful-direction". BREAK.
        }
        IF pos:MAG <= ctx["ATMO"] AND VANG(direction,-vel) > ctx["ANGLE"] {
            SET reason TO "entry-attitude-window". BREAK.
        }
        LOCAL energyLeft IS info["E"]+ctx["MU"]/(ctx["TARGET_PE"]+ctx["TARGET_AP"]).
        IF energyLeft <= 1 { SET reason TO "apoapsis-target". BREAK. }
        LOCAL dt IS MIN(stepSec,duration-burnTime).
        SET dt TO MIN(dt,0.8*energyLeft/(acc*MAX(1,-VDOT(direction,vel)))).
        IF dt < 0.001 { SET reason TO "apoapsis-target". BREAK. }
        LOCAL acc1 IS acc*direction-ctx["MU"]*pos/pos:MAG^3.
        LOCAL midpoint IS pos+vel*dt/2.
        LOCAL midvel IS vel+acc1*dt/2.
        LOCAL midacc IS ctx["ACC"]/(1-ctx["ACC"]*(burnTime+dt/2)/ctx["VE"]).
        LOCAL middir IS aeroApDirection(midpoint,midvel,ctx["MU"],ctx["TARGET_PE"],midacc).
        IF middir:MAG < 0.5 { SET reason TO "no-useful-direction". BREAK. }
        SET pos TO pos+midvel*dt.
        SET vel TO vel+(midacc*middir-ctx["MU"]*midpoint/midpoint:MAG^3)*dt.
        SET burnTime TO burnTime+dt.
    }
    SET applied TO -ctx["VE"]*LN(1-ctx["ACC"]*burnTime/ctx["VE"]).
    SET info TO aeroApOrbit(pos,vel,ctx["MU"]).
    LOCAL valid IS NOT ABORT AND applied > 0.1
        AND info["PE"] >= ctx["LOW"]+100 AND info["PE"] <= ctx["HIGH"]-100
        AND info["E"] < ctx["ENERGY"].
    RETURN LEXICON("OK",valid,"REASON",reason,"DV",applied,"DURATION",burnTime,
        "DELAY",delay,"PE",info["PE"],"AP",info["AP"],"ENERGY",info["E"]).
}
