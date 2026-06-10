// ============================================================
// orbit_shape.ks  —  Closed-form orbit shaping  (0:/lib/orbit_shape.ks)
//
// Drive the current orbit to a fully (or partially) specified
// target orbit around the CURRENT body: AP, PE, INC, LAN, AOP.
// No numeric search — every burn is computed in closed form from
// classical orbital mechanics, and the phase loop re-measures the
// real orbit after each burn, so execution errors self-correct.
//
// Why this works as a sequence of independent 1D problems:
//   1. PLANE  — rotating the velocity vector about the radial
//      axis at the line where the current and target planes
//      intersect changes INC+LAN together in ONE burn and
//      preserves the orbit shape exactly (same speed, same
//      radial velocity => same SMA, ecc, true anomaly).
//   2. AOP    — a radial impulse at the bisector point rotates
//      the apsidal line in-plane, preserving SMA and ecc
//      (planAoPChange in maneuver.ks).
//   3. APSES  — prograde burns at Pe/Ap set the opposite apsis
//      and move neither the plane nor the apsidal line.
// So PLANE -> AOP -> APSES converges in one round plus trims.
//
// Phase: SHAPE  (bind via dependencies.txt: PHASE SHAPE = orbit_shape)
//
// CFG keys (all optional — omitted elements are left alone):
//   SHAPE_AP   — target apoapsis altitude (m)
//   SHAPE_PE   — target periapsis altitude (m)
//   SHAPE_INC  — target inclination (deg)
//   SHAPE_LAN  — target longitude of ascending node (deg)
//   SHAPE_AOP  — target argument of periapsis (deg)
//   SHAPE_ALT_TOL — apsis tolerance in m (default 1000)
//   SHAPE_ANG_TOL — plane tolerance in deg (default 0.15)
//   SHAPE_AOP_TOL — AoP tolerance in deg (default 1.0)
//
// Notes:
//   - INC+LAN are converged as a single PLANE error: the angle
//     between the current orbit normal and the target orbit
//     normal. This stays well-defined even for near-equatorial
//     orbits where LAN itself is numerically unstable.
//   - AoP is skipped when the target orbit is near-circular
//     (ecc < 0.004): the apsidal line is then physically
//     meaningless and KSP's reported AOP is noise.
//   - Handedness of the constructed target normal is calibrated
//     at runtime against a known orbit (the ship's, or any moon
//     of the same body) instead of trusting kOS/KSP coordinate
//     conventions. If no reference exists (everything perfectly
//     equatorial) the first plane burn may pick the mirror
//     plane; the next loop round detects and corrects it.
// ============================================================

@LAZYGLOBAL OFF.

LOCAL MAX_RETRIES        IS 5.
LOCAL MAX_SHAPE_BURNS    IS 12.
LOCAL DEFAULT_ALT_TOL    IS 1000.
LOCAL DEFAULT_ANG_TOL    IS 0.15.
LOCAL DEFAULT_AOP_TOL    IS 1.0.
LOCAL NEAR_CIRC_ECC      IS 0.01.
LOCAL MIN_AOP_TARGET_ECC IS 0.004.

// ============================================================
// Small helpers
// ============================================================

LOCAL FUNCTION _cfgNum {
    PARAMETER key.
    PARAMETER defaultValue.
    IF DEFINED CFG AND CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _angDiff {
    PARAMETER a, b.
    LOCAL d IS a - b.
    UNTIL d <= 180  { SET d TO d - 360. }
    UNTIL d > -180  { SET d TO d + 360. }
    RETURN d.
}

// Body "north" axis used by KSP for inclination/LAN definitions.
LOCAL FUNCTION _bodyNorth {
    RETURN SHIP:BODY:ANGULARVEL:NORMALIZED.
}

// Current orbit normal (angular momentum direction) — same
// convention as lib_navigation's orbitBinormal.
LOCAL FUNCTION _shipNormal {
    RETURN VCRS(
        (SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED,
        SHIP:VELOCITY:ORBIT:NORMALIZED):NORMALIZED.
}

// Normal of any orbitable around its own parent, evaluated now.
LOCAL FUNCTION _orbitableNormal {
    PARAMETER obt_.
    LOCAL parent IS obt_:BODY.
    RETURN VCRS(
        (obt_:POSITION - parent:POSITION):NORMALIZED,
        obt_:ORBIT:VELOCITY:ORBIT:NORMALIZED):NORMALIZED.
}

// ============================================================
// nodeFromDvVector — convert a raw dV vector at a future time
// into a maneuver node. Shared frame recipe (matches the proven
// implementation in maneuver_rendezvous.ks).
// ============================================================
GLOBAL FUNCTION nodeFromDvVector {
    PARAMETER burnUt.
    PARAMETER dvVec.
    LOCAL r1 IS POSITIONAT(SHIP, burnUt) - POSITIONAT(SHIP:BODY, burnUt).
    LOCAL progradeHat IS VELOCITYAT(SHIP, burnUt):ORBIT:NORMALIZED.
    LOCAL normalHat IS VCRS(r1, progradeHat):NORMALIZED.
    LOCAL radialHat IS VCRS(normalHat, progradeHat):NORMALIZED.
    RETURN NODE(burnUt,
        VDOT(dvVec, radialHat),
        VDOT(dvVec, normalHat),
        VDOT(dvVec, progradeHat)).
}

// ============================================================
// planeNormalFromIncLan — construct the orbit-normal unit vector
// for a target (inc, lan) around the current body.
//
// The ascending-node direction follows lib_navigation's orbitLAN
// convention. The normal is then one of two mirror candidates;
// the correct mirror is calibrated against a reference orbit
// whose elements AND normal vector we can both measure.
// ============================================================
GLOBAL FUNCTION planeNormalFromIncLan {
    PARAMETER inc, lan.
    LOCAL bodyUp IS _bodyNorth().
    LOCAL mirror IS _normalMirrorSign().
    RETURN _normalCandidate(inc, lan, bodyUp, mirror).
}

LOCAL FUNCTION _normalCandidate {
    PARAMETER inc, lan, bodyUp, mirror.
    LOCAL nodeVec IS (ANGLEAXIS(lan, bodyUp) * SOLARPRIMEVECTOR):NORMALIZED.
    LOCAL w IS VCRS(bodyUp, nodeVec):NORMALIZED.
    RETURN (COS(inc) * bodyUp + mirror * SIN(inc) * w):NORMALIZED.
}

// Determine which mirror candidate matches KSP's element
// conventions, using the ship's own orbit when it is inclined
// enough to disambiguate, otherwise any moon of the same body.
// Returns +1 or -1; +1 with a warning when no reference exists.
LOCAL _mirrorSignCache IS 0.
LOCAL FUNCTION _normalMirrorSign {
    IF _mirrorSignCache <> 0 { RETURN _mirrorSignCache. }
    LOCAL bodyUp IS _bodyNorth().

    LOCAL refInc IS SHIP:ORBIT:INCLINATION.
    LOCAL refLan IS SHIP:ORBIT:LAN.
    LOCAL refNormal IS _shipNormal().
    LOCAL found IS refInc > 0.3 AND refInc < 179.7.

    IF NOT found {
        LOCAL allBodies IS LIST().
        LIST BODIES IN allBodies.
        FOR bod IN allBodies {
            IF NOT found AND bod:HASBODY AND bod:BODY = SHIP:BODY
                    AND bod:ORBIT:INCLINATION > 0.3
                    AND bod:ORBIT:INCLINATION < 179.7 {
                SET refInc TO bod:ORBIT:INCLINATION.
                SET refLan TO bod:ORBIT:LAN.
                SET refNormal TO _orbitableNormal(bod).
                SET found TO TRUE.
            }
        }
    }

    IF NOT found {
        mLogWarn("SHAPE: no inclined reference orbit — normal mirror "
            + "sign unverified; first plane burn may need a second round.").
        RETURN 1.
    }

    LOCAL plus IS _normalCandidate(refInc, refLan, bodyUp, 1).
    IF VANG(plus, refNormal) < 90 {
        SET _mirrorSignCache TO 1.
    } ELSE {
        SET _mirrorSignCache TO -1.
    }
    RETURN _mirrorSignCache.
}

// ============================================================
// Target lexicon and error measurement
// ============================================================

// shapeTargets — read SHAPE_* CFG keys into a targets lexicon.
GLOBAL FUNCTION shapeTargets {
    LOCAL t IS LEXICON().
    FOR key IN LIST("AP", "PE", "INC", "LAN", "AOP") {
        IF DEFINED CFG AND CFG:HASKEY("SHAPE_" + key) {
            t:ADD(key, CFG["SHAPE_" + key]).
        }
    }
    // AP below PE is always operator error — fix and warn.
    IF t:HASKEY("AP") AND t:HASKEY("PE") AND t["AP"] < t["PE"] {
        mLogWarn("SHAPE: target AP < PE — swapping.").
        LOCAL tmp IS t["AP"].
        SET t["AP"] TO t["PE"].
        SET t["PE"] TO tmp.
    }
    RETURN t.
}

// Eccentricity the target orbit will have (used to decide if AoP
// is physically meaningful). Falls back to current values for
// unspecified apsides.
LOCAL FUNCTION _targetEcc {
    PARAMETER targets.
    LOCAL bodyR IS SHIP:BODY:RADIUS.
    LOCAL ap IS SHIP:APOAPSIS.
    LOCAL pe IS SHIP:PERIAPSIS.
    IF targets:HASKEY("AP") { SET ap TO targets["AP"]. }
    IF targets:HASKEY("PE") { SET pe TO targets["PE"]. }
    LOCAL rA IS bodyR + ap.
    LOCAL rP IS bodyR + pe.
    RETURN (rA - rP) / (rA + rP).
}

// shapeErrors — measure current errors against targets.
// PLANE is the single source of truth for INC+LAN convergence;
// INC/LAN are also reported individually for the log.
GLOBAL FUNCTION shapeErrors {
    PARAMETER targets.
    LOCAL e IS LEXICON().
    IF targets:HASKEY("AP") {
        e:ADD("AP", SHIP:APOAPSIS - targets["AP"]).
    }
    IF targets:HASKEY("PE") {
        e:ADD("PE", SHIP:PERIAPSIS - targets["PE"]).
    }
    IF targets:HASKEY("INC") OR targets:HASKEY("LAN") {
        LOCAL tInc IS SHIP:ORBIT:INCLINATION.
        LOCAL tLan IS SHIP:ORBIT:LAN.
        IF targets:HASKEY("INC") { SET tInc TO targets["INC"]. }
        IF targets:HASKEY("LAN") { SET tLan TO targets["LAN"]. }
        e:ADD("PLANE", VANG(_shipNormal(), planeNormalFromIncLan(tInc, tLan))).
        e:ADD("INC", _angDiff(SHIP:ORBIT:INCLINATION, tInc)).
        e:ADD("LAN", _angDiff(SHIP:ORBIT:LAN, tLan)).
    }
    IF targets:HASKEY("AOP") AND _targetEcc(targets) >= MIN_AOP_TARGET_ECC {
        e:ADD("AOP", _angDiff(SHIP:ORBIT:ARGUMENTOFPERIAPSIS, targets["AOP"])).
    }
    RETURN e.
}

LOCAL FUNCTION _errorSummary {
    PARAMETER errs.
    LOCAL s IS "".
    FOR key IN errs:KEYS {
        LOCAL val IS errs[key].
        IF key = "AP" OR key = "PE" {
            SET s TO s + " " + key + "Err=" + ROUND(val / 1000, 2) + "km".
        } ELSE {
            SET s TO s + " " + key + "Err=" + ROUND(val, 3).
        }
    }
    RETURN s.
}

// shapeConverged — TRUE when every requested element is in tolerance.
GLOBAL FUNCTION shapeConverged {
    PARAMETER targets.
    LOCAL errs IS shapeErrors(targets).
    LOCAL altTol IS _cfgNum("SHAPE_ALT_TOL", DEFAULT_ALT_TOL).
    LOCAL angTol IS _cfgNum("SHAPE_ANG_TOL", DEFAULT_ANG_TOL).
    LOCAL aopTol IS _cfgNum("SHAPE_AOP_TOL", DEFAULT_AOP_TOL).
    IF errs:HASKEY("AP")    AND ABS(errs["AP"]) > altTol    { RETURN FALSE. }
    IF errs:HASKEY("PE")    AND ABS(errs["PE"]) > altTol    { RETURN FALSE. }
    IF errs:HASKEY("PLANE") AND errs["PLANE"]   > angTol    { RETURN FALSE. }
    IF errs:HASKEY("AOP")   AND ABS(errs["AOP"]) > aopTol   { RETURN FALSE. }
    RETURN TRUE.
}

// ============================================================
// planPlaneMatch — single combined INC+LAN burn.
//
// Burns at the intersection line of the current and target orbit
// planes (the relative node), rotating the velocity vector about
// the radial axis by the dihedral angle. Picks whichever of the
// two crossings sits at higher radius (slower => cheaper), and
// resolves the rotation sense empirically by testing both and
// keeping the one whose post-burn normal lands on target.
// ============================================================
GLOBAL FUNCTION planPlaneMatch {
    PARAMETER targetInc.
    PARAMETER targetLan.

    LOCAL b IS _shipNormal().
    LOCAL nTgt IS planeNormalFromIncLan(targetInc, targetLan).
    LOCAL theta IS VANG(b, nTgt).
    IF theta < 0.01 { RETURN 0. }

    // Relative-node crossings, as exact true-anomaly offsets.
    LOCAL angAN IS angleToRelativeAscendingNode(b, nTgt).
    LOCAL angDN IS angleToRelativeDescendingNode(b, nTgt).
    IF angAN < 0 { SET angAN TO angAN + 360. }
    IF angDN < 0 { SET angDN TO angDN + 360. }
    LOCAL taNow IS SHIP:ORBIT:TRUEANOMALY.
    LOCAL etaAN IS etaToTrueAnomaly(taNow + angAN).
    LOCAL etaDN IS etaToTrueAnomaly(taNow + angDN).

    // Radius at each crossing: r = p / (1 + e cos TA).
    LOCAL ecc IS SHIP:ORBIT:ECCENTRICITY.
    LOCAL p IS SHIP:ORBIT:SEMIMAJORAXIS * (1 - ecc ^ 2).
    LOCAL rAN IS p / (1 + ecc * COS(taNow + angAN)).
    LOCAL rDN IS p / (1 + ecc * COS(taNow + angDN)).

    LOCAL burnEta IS etaAN.
    IF rDN > rAN { SET burnEta TO etaDN. }

    // Never plan a burn we cannot align for.
    IF burnEta < 60 { SET burnEta TO burnEta + SHIP:ORBIT:PERIOD. }
    LOCAL burnUt IS TIME:SECONDS + burnEta.

    LOCAL rVec IS POSITIONAT(SHIP, burnUt) - POSITIONAT(SHIP:BODY, burnUt).
    LOCAL rHat IS rVec:NORMALIZED.
    LOCAL vel IS VELOCITYAT(SHIP, burnUt):ORBIT.

    // Try both rotation senses; keep the one whose post-burn plane
    // normal is closest to the target normal. Immune to handedness.
    LOCAL vPlus IS ANGLEAXIS(theta, rHat) * vel.
    LOCAL vMinus IS ANGLEAXIS(-theta, rHat) * vel.
    LOCAL nPlus IS VCRS(rHat, vPlus:NORMALIZED):NORMALIZED.
    LOCAL nMinus IS VCRS(rHat, vMinus:NORMALIZED):NORMALIZED.
    LOCAL vNew IS vPlus.
    LOCAL residual IS VANG(nPlus, nTgt).
    IF VANG(nMinus, nTgt) < residual {
        SET vNew TO vMinus.
        SET residual TO VANG(nMinus, nTgt).
    }

    LOCAL dvVec IS vNew - vel.
    LOCAL nd IS nodeFromDvVector(burnUt, dvVec).
    ADD nd.

    mLog("Plane match node: dV=" + ROUND(nd:DELTAV:MAG, 1)
        + " m/s  theta=" + ROUND(theta, 2)
        + "deg  residual=" + ROUND(residual, 3)
        + "deg  ETA=" + ROUND(burnEta, 0) + "s").
    mLogWarn("STATS plane-match plan dv=" + ROUND(nd:DELTAV:MAG, 1)
        + " theta=" + ROUND(theta, 2)
        + " targetInc=" + ROUND(targetInc, 2)
        + " targetLan=" + ROUND(targetLan, 2)
        + " residual=" + ROUND(residual, 3)
        + " eta=" + ROUND(burnEta, 0)).
    archivePlannedManeuverLog("plane-match").
    RETURN nd.
}

// ============================================================
// _planTangentBurnAt — prograde/retrograde burn at burnEta that
// re-sizes the orbit so the FAR apsis radius becomes targetAlt.
// Exact at an apsis; used either at Pe/Ap or on a near-circular
// orbit (where every point is approximately an apsis).
// ============================================================
LOCAL FUNCTION _planTangentBurnAt {
    PARAMETER burnEta.
    PARAMETER targetAlt.
    PARAMETER label.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL burnUt IS TIME:SECONDS + burnEta.
    LOCAL rBurn IS (POSITIONAT(SHIP, burnUt) - POSITIONAT(SHIP:BODY, burnUt)):MAG.
    LOCAL rTarget IS SHIP:BODY:RADIUS + targetAlt.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS VELOCITYAT(SHIP, burnUt):ORBIT:MAG.
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(burnUt, 0, 0, vNew - vNow).
    ADD nd.
    mLog(label + " node: dV=" + ROUND(nd:DELTAV:MAG, 1)
        + " m/s  targetAlt=" + ROUND(targetAlt / 1000, 1)
        + "km  ETA=" + ROUND(burnEta, 0) + "s").
    archivePlannedManeuverLog(label).
    RETURN nd.
}

// ============================================================
// _placedApsisEta — ETA to the point of the (near-circular)
// orbit where the target periapsis should sit: argument of
// latitude = target AoP, measured from the ascending node in
// the direction of motion. Sense resolved empirically.
// ============================================================
LOCAL FUNCTION _placedApsisEta {
    PARAMETER aop.
    LOCAL b IS _shipNormal().
    LOCAL nodeVec IS (ANGLEAXIS(SHIP:ORBIT:LAN, _bodyNorth()) * SOLARPRIMEVECTOR):NORMALIZED.

    // Which rotation sense about the normal moves "forward" along
    // the orbit? Test with the velocity direction at our position.
    LOCAL rHat IS (SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED.
    LOCAL fwd IS SHIP:VELOCITY:ORBIT:NORMALIZED.
    LOCAL sense IS 1.
    IF VDOT(ANGLEAXIS(90, b) * rHat, fwd) < 0 { SET sense TO -1. }

    LOCAL peDir IS (ANGLEAXIS(sense * aop, b) * nodeVec):NORMALIZED.

    // Central angle from current position to that direction,
    // signed along the direction of motion.
    LOCAL ang IS VANG(rHat, peDir).
    IF VDOT(ANGLEAXIS(sense * ang, b) * rHat, peDir) < 0.999 {
        SET ang TO 360 - ang.
    }
    RETURN etaToTrueAnomaly(SHIP:ORBIT:TRUEANOMALY + ang).
}

// ============================================================
// shapeNextBurn — plan the single most-needed correction burn.
// Returns LEX("node", nd, "label", text) or 0 when converged
// (or nothing useful can be planned).
//
// Priority: PLANE -> placed apsis (circular start) -> AOP ->
// AP -> PE. Each call re-reads the live orbit, so the sequence
// self-heals across execution errors.
// ============================================================
GLOBAL FUNCTION shapeNextBurn {
    PARAMETER targets.

    LOCAL errs IS shapeErrors(targets).
    LOCAL altTol IS _cfgNum("SHAPE_ALT_TOL", DEFAULT_ALT_TOL).
    LOCAL angTol IS _cfgNum("SHAPE_ANG_TOL", DEFAULT_ANG_TOL).
    LOCAL aopTol IS _cfgNum("SHAPE_AOP_TOL", DEFAULT_AOP_TOL).

    // --- 1. Orbit plane (INC + LAN in one burn) ---
    IF errs:HASKEY("PLANE") AND errs["PLANE"] > angTol {
        LOCAL tInc IS SHIP:ORBIT:INCLINATION.
        LOCAL tLan IS SHIP:ORBIT:LAN.
        IF targets:HASKEY("INC") { SET tInc TO targets["INC"]. }
        IF targets:HASKEY("LAN") { SET tLan TO targets["LAN"]. }
        LOCAL nd IS planPlaneMatch(tInc, tLan).
        IF nd <> 0 { RETURN LEX("node", nd, "label", "plane"). }
    }

    // --- 2. Near-circular start with a requested AoP: establish
    // eccentricity at the right place instead of fighting an
    // undefined apsidal line. Burn where the periapsis belongs. ---
    IF SHIP:ORBIT:ECCENTRICITY < NEAR_CIRC_ECC
            AND targets:HASKEY("AOP")
            AND _targetEcc(targets) >= MIN_AOP_TARGET_ECC
            AND (targets:HASKEY("AP") OR targets:HASKEY("PE")) {
        LOCAL needAp IS errs:HASKEY("AP") AND ABS(errs["AP"]) > altTol.
        LOCAL needPe IS errs:HASKEY("PE") AND ABS(errs["PE"]) > altTol.
        IF needAp OR needPe {
            LOCAL rNowAlt IS SHIP:ALTITUDE.
            IF targets:HASKEY("AP") AND targets["AP"] > rNowAlt {
                // Burn prograde at the desired Pe location, raising
                // the opposite side to AP — the burn point becomes Pe.
                LOCAL eta1 IS _placedApsisEta(targets["AOP"]).
                IF eta1 < 60 { SET eta1 TO eta1 + SHIP:ORBIT:PERIOD. }
                RETURN LEX(
                    "node", _planTangentBurnAt(eta1, targets["AP"], "placed-pe"),
                    "label", "placed-pe").
            }
            IF targets:HASKEY("PE") {
                // Shrinking orbit: burn retrograde at the desired AP
                // location (AoP+180), lowering the opposite side to PE.
                LOCAL eta2 IS _placedApsisEta(targets["AOP"] + 180).
                IF eta2 < 60 { SET eta2 TO eta2 + SHIP:ORBIT:PERIOD. }
                RETURN LEX(
                    "node", _planTangentBurnAt(eta2, targets["PE"], "placed-ap"),
                    "label", "placed-ap").
            }
        }
    }

    // --- 3. Argument of periapsis (in-plane apsidal rotation) ---
    IF errs:HASKEY("AOP") AND ABS(errs["AOP"]) > aopTol
            AND SHIP:ORBIT:ECCENTRICITY >= NEAR_CIRC_ECC {
        LOCAL nd2 IS planAoPChange(targets["AOP"]).
        IF nd2 <> 0 { RETURN LEX("node", nd2, "label", "aop"). }
    }

    // --- 4 & 5. Apsides. Order by feasibility: an Ap target below
    // the current Pe cannot be set from Pe, so fix Pe first then. ---
    LOCAL needAp2 IS errs:HASKEY("AP") AND ABS(errs["AP"]) > altTol.
    LOCAL needPe2 IS errs:HASKEY("PE") AND ABS(errs["PE"]) > altTol.

    IF needAp2 AND targets["AP"] >= SHIP:PERIAPSIS {
        LOCAL etaPe IS ETA:PERIAPSIS.
        IF etaPe < 60 { SET etaPe TO etaPe + SHIP:ORBIT:PERIOD. }
        RETURN LEX(
            "node", _planTangentBurnAt(etaPe, targets["AP"], "set-ap"),
            "label", "set-ap").
    }
    IF needPe2 {
        LOCAL etaAp IS ETA:APOAPSIS.
        IF etaAp < 60 { SET etaAp TO etaAp + SHIP:ORBIT:PERIOD. }
        RETURN LEX(
            "node", _planTangentBurnAt(etaAp, targets["PE"], "set-pe"),
            "label", "set-pe").
    }
    IF needAp2 {
        // AP target below current Pe and PE already in tolerance:
        // dip via the Ap burn anyway; next round restores PE.
        LOCAL etaAp2 IS ETA:APOAPSIS.
        IF etaAp2 < 60 { SET etaAp2 TO etaAp2 + SHIP:ORBIT:PERIOD. }
        RETURN LEX(
            "node", _planTangentBurnAt(etaAp2, targets["AP"], "set-pe-for-ap"),
            "label", "set-pe-for-ap").
    }

    RETURN 0.
}

// ============================================================
// phaseShape — phase handler. Plans and executes one burn at a
// time, re-measuring the live orbit between burns, until every
// requested element is in tolerance or the burn budget runs out.
// ============================================================
GLOBAL FUNCTION phaseShape {
    LOCAL targets IS shapeTargets().
    IF targets:LENGTH = 0 {
        mLog("SHAPE: no SHAPE_* targets configured — skipping.").
        nextPhase(xferSeq).
        RETURN.
    }

    mLog("SHAPE targets: " + _targetSummary(targets)).
    mLogWarn("STATS shape setup" + _targetSummary(targets)
        + _errorSummary(shapeErrors(targets))).

    LOCAL burns IS 0.
    UNTIL shapeConverged(targets) OR burns >= MAX_SHAPE_BURNS {
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
        LOCAL planned IS shapeNextBurn(targets).
        IF planned = 0 {
            mLogWarn("SHAPE: no further burn plannable"
                + _errorSummary(shapeErrors(targets))).
            BREAK.
        }
        SET burns TO burns + 1.
        mLog("SHAPE burn " + burns + ": " + planned["label"]).
        LOCAL success IS FALSE.
        LOCAL retries IS 0.
        UNTIL success {
            SET success TO executeManeuver().
            IF NOT success {
                SET retries TO retries + 1.
                IF retries >= MAX_RETRIES {
                    mLogError("SHAPE: burn " + planned["label"]
                        + " failed after " + retries + " attempts — halting.").
                    RETURN.
                }
                mLog("SHAPE: burn missed (attempt " + retries + ") — replanning.").
                WAIT 10.
                UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
                LOCAL replanned IS shapeNextBurn(targets).
                IF replanned = 0 { SET success TO TRUE. }
            }
        }
        WAIT 2.
    }

    LOCAL finalErrs IS shapeErrors(targets).
    LOCAL ok IS shapeConverged(targets).
    orbitSummary().
    IF ok {
        mLog("SHAPE complete in " + burns + " burns" + _errorSummary(finalErrs)).
    } ELSE {
        mLogWarn("SHAPE finished UNCONVERGED after " + burns
            + " burns" + _errorSummary(finalErrs)).
    }
    mLogWarn("STATS shape result solved=" + ok
        + " burns=" + burns
        + _errorSummary(finalErrs)).
    nextPhase(xferSeq).
}

LOCAL FUNCTION _targetSummary {
    PARAMETER targets.
    LOCAL s IS "".
    FOR key IN targets:KEYS {
        IF key = "AP" OR key = "PE" {
            SET s TO s + " " + key + "=" + ROUND(targets[key] / 1000, 1) + "km".
        } ELSE {
            SET s TO s + " " + key + "=" + ROUND(targets[key], 2).
        }
    }
    RETURN s.
}
