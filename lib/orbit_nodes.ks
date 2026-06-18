// ============================================================
// orbit_nodes.ks — compact node timing helpers
// ============================================================

LOCAL FUNCTION _orbitNodeTangent {
    PARAMETER ves IS SHIP.
    RETURN ves:VELOCITY:ORBIT:NORMALIZED.
}

LOCAL FUNCTION _orbitNodeBinormal {
    PARAMETER ves IS SHIP.
    RETURN VCRS((ves:POSITION - ves:BODY:POSITION):NORMALIZED,
        _orbitNodeTangent(ves)):NORMALIZED.
}

LOCAL FUNCTION _orbitNodeLan {
    PARAMETER ves IS SHIP.
    RETURN ANGLEAXIS(ves:ORBIT:LAN, ves:BODY:ANGULARVEL:NORMALIZED)
        * SOLARPRIMEVECTOR.
}

GLOBAL FUNCTION orbitNodeAngleToBodyAscending {
    PARAMETER ves IS SHIP.

    LOCAL joinVector IS _orbitNodeLan(ves).
    LOCAL angle IS VANG((ves:POSITION - ves:BODY:POSITION):NORMALIZED,
        joinVector).
    IF ves:STATUS = "LANDED" {
        SET angle TO angle - 90.
    } ELSE {
        LOCAL signVector IS VCRS(-ves:BODY:POSITION, joinVector).
        IF VDOT(_orbitNodeBinormal(ves), signVector) < 0 {
            SET angle TO -angle.
        }
    }
    RETURN angle.
}

GLOBAL FUNCTION orbitNodeAngleToBodyDescending {
    PARAMETER ves IS SHIP.

    LOCAL joinVector IS -_orbitNodeLan(ves).
    LOCAL angle IS VANG((ves:POSITION - ves:BODY:POSITION):NORMALIZED,
        joinVector).
    IF ves:STATUS = "LANDED" {
        SET angle TO angle - 90.
    } ELSE {
        LOCAL signVector IS VCRS(-ves:BODY:POSITION, joinVector).
        IF VDOT(_orbitNodeBinormal(ves), signVector) < 0 {
            SET angle TO -angle.
        }
    }
    RETURN angle.
}

GLOBAL FUNCTION orbitNodeRelativeVector {
    PARAMETER orbitBinormal.
    PARAMETER targetBinormal.
    RETURN VCRS(orbitBinormal, targetBinormal):NORMALIZED.
}

LOCAL FUNCTION _angleToRelativeNode {
    PARAMETER orbitBinormal.
    PARAMETER targetBinormal.
    PARAMETER ascending.

    LOCAL joinVector IS orbitNodeRelativeVector(orbitBinormal, targetBinormal).
    IF NOT ascending { SET joinVector TO -joinVector. }
    LOCAL radiusVec IS (SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED.
    LOCAL angle IS VANG(radiusVec, joinVector).
    LOCAL signVector IS VCRS(radiusVec, joinVector).
    IF VDOT(orbitBinormal, signVector) < 0 { SET angle TO -angle. }
    RETURN angle.
}

GLOBAL FUNCTION orbitNodeAngleToRelativeAscending {
    PARAMETER orbitBinormal.
    PARAMETER targetBinormal.
    RETURN _angleToRelativeNode(orbitBinormal, targetBinormal, TRUE).
}

GLOBAL FUNCTION orbitNodeAngleToRelativeDescending {
    PARAMETER orbitBinormal.
    PARAMETER targetBinormal.
    RETURN _angleToRelativeNode(orbitBinormal, targetBinormal, FALSE).
}

LOCAL FUNCTION _meanAnomalyDeg {
    PARAMETER ta, obtEcc.
    LOCAL eAnom IS 2 * ARCTAN2(
        SQRT(1 - obtEcc) * SIN(ta / 2),
        SQRT(1 + obtEcc) * COS(ta / 2)).
    RETURN eAnom - obtEcc * SIN(eAnom) * CONSTANT:RADTODEG.
}

GLOBAL FUNCTION etaToTrueAnomaly {
    PARAMETER targetTA.

    UNTIL targetTA >= 0   { SET targetTA TO targetTA + 360. }
    UNTIL targetTA < 360  { SET targetTA TO targetTA - 360. }

    LOCAL obtEcc IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    IF obtEcc >= 1 {
        LOCAL taToGo IS targetTA - SHIP:ORBIT:TRUEANOMALY.
        IF taToGo < 0 { SET taToGo TO taToGo + 360. }
        RETURN (taToGo / 360) * period.
    }

    LOCAL mNow IS _meanAnomalyDeg(SHIP:ORBIT:TRUEANOMALY, obtEcc).
    LOCAL mTgt IS _meanAnomalyDeg(targetTA, obtEcc).
    LOCAL dM IS mTgt - mNow.
    UNTIL dM >= 0   { SET dM TO dM + 360. }
    UNTIL dM < 360  { SET dM TO dM - 360. }
    RETURN (dM / 360) * period.
}
