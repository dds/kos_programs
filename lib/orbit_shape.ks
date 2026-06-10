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

// Speed at a true anomaly ON THE SHIP'S CURRENT ORBIT — pure
// conic math from the live elements. NO future-state prediction:
// flight-found (three times) that VELOCITYAT and POSITIONAT
// differences are contaminated by the parent body's own motion
// in this kOS build (~60-500 m/s at the Mun), poisoning every
// seed built from them. Elements cannot lie; Kepler does the
// timing; the nd:ORBIT refiners do the precision.
LOCAL FUNCTION _radiusAtTa {
    PARAMETER ta.
    LOCAL ecc IS SHIP:ORBIT:ECCENTRICITY.
    RETURN SHIP:ORBIT:SEMIMAJORAXIS * (1 - ecc ^ 2)
        / (1 + ecc * COS(ta)).
}

LOCAL FUNCTION _speedAtTa {
    PARAMETER ta.
    RETURN SQRT(SHIP:BODY:MU
        * (2 / _radiusAtTa(ta) - 1 / SHIP:ORBIT:SEMIMAJORAXIS)).
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
    LOCAL burnTa IS taNow + angAN.
    IF rDN > rAN {
        SET burnEta TO etaDN.
        SET burnTa TO taNow + angDN.
    }

    // Never plan a burn we cannot align for.
    IF burnEta < 60 { SET burnEta TO burnEta + SHIP:ORBIT:PERIOD. }
    LOCAL burnUt IS TIME:SECONDS + burnEta.

    // Pure-normal seed from elements: a plane rotation by theta
    // costs 2 v sin(theta/2) at the node. Sign and exactness are
    // the refiner's job (it owns the NORMAL axis and walks through
    // zero if the sense is wrong) — no frames, no predictions.
    LOCAL dvSeed IS 2 * _speedAtTa(burnTa) * SIN(theta / 2).
    LOCAL nd IS NODE(burnUt, 0, dvSeed, 0).
    ADD nd.
    WAIT 0.02.

    // The analytic node is only a SEED. Refine it against the
    // game's own propagation (nd:ORBIT) in pure element space —
    // immune to every POSITIONAT/VELOCITYAT frame and timing
    // subtlety (flight-found: two analytic attempts left 27-29
    // deg residuals; the game knows where the ship will be).
    LOCAL seedErr IS _planeErrOf(nd:ORBIT, nTgt).
    LOCAL finalErr IS _refinePlaneNode(nd, nTgt).

    mLog("Plane match node: dV=" + ROUND(nd:DELTAV:MAG, 1)
        + " m/s  theta=" + ROUND(theta, 2)
        + "deg  planeErr=" + ROUND(finalErr, 2)
        + "deg  ETA=" + ROUND(nd:ETA, 0) + "s").
    mLogWarn("STATS plane-match plan dv=" + ROUND(nd:DELTAV:MAG, 1)
        + " theta=" + ROUND(theta, 2)
        + " targetInc=" + ROUND(targetInc, 2)
        + " targetLan=" + ROUND(targetLan, 2)
        + " seedDv=" + ROUND(dvSeed, 1)
        + " seedErr=" + ROUND(seedErr, 2)
        + " finalErr=" + ROUND(finalErr, 2)
        + " eta=" + ROUND(nd:ETA, 0)).

    IF finalErr > 5 {
        mLogError("Plane match: refinement stuck at "
            + ROUND(finalErr, 1) + "deg — discarding node.").
        REMOVE nd.
        RETURN 0.
    }
    archivePlannedManeuverLog("plane-match").
    RETURN nd.
}

// Plane error of an orbit (by its elements) against a target
// normal, both built by the same calibrated constructor — pure
// element space, no frames involved.
LOCAL FUNCTION _planeErrOf {
    PARAMETER o, nTgt.
    RETURN VANG(planeNormalFromIncLan(o:INCLINATION, o:LAN), nTgt).
}

// ============================================================
// _refinePlaneNode — coordinate descent on the node's TIME /
// NORMAL / PROGRADE / RADIALOUT against nd:ORBIT, minimizing
// plane error plus a light penalty for disturbing the apsides
// (those belong to later SHAPE steps). Bound orbit elements vary
// smoothly with node tweaks, so this converges fast from the
// analytic seed. Returns the final plane error in degrees.
// ============================================================
LOCAL FUNCTION _refinePlaneNode {
    PARAMETER nd, nTgt.

    LOCAL pe0 IS SHIP:PERIAPSIS.
    LOCAL ap0 IS SHIP:APOAPSIS.
    // Hard floor: the apsis penalty is light by design (later
    // SHAPE steps restore the apsides cheaply), but the refiner
    // must never trade periapsis into terrain or atmosphere.
    LOCAL peFloor IS 10000.
    IF SHIP:BODY:ATM:EXISTS {
        SET peFloor TO SHIP:BODY:ATM:HEIGHT + 10000.
    }

    LOCAL FUNCTION _cost {
        IF nd:ORBIT:PERIAPSIS < peFloor { RETURN 9999. }
        RETURN _planeErrOf(nd:ORBIT, nTgt)
            + 0.01 * (ABS(nd:ORBIT:PERIAPSIS - pe0)
                    + ABS(nd:ORBIT:APOAPSIS - ap0)) / 1000.
    }

    LOCAL axes IS LIST("TIME", "NORMAL", "PROGRADE", "RADIALOUT").
    LOCAL steps IS LEXICON(
        "TIME", 120, "NORMAL", 16, "PROGRADE", 8, "RADIALOUT", 8).
    LOCAL minTime IS TIME:SECONDS + 60.

    LOCAL best IS _stableEval(_cost@).
    FROM { LOCAL i IS 0. } UNTIL i >= 60 STEP { SET i TO i + 1. } DO {
        IF _planeErrOf(nd:ORBIT, nTgt) < 0.15 { BREAK. }
        LOCAL improved IS FALSE.
        FOR axis IN axes {
            LOCAL oldVal IS _nodeAxis(nd, axis).
            FOR sgn IN LIST(1, -1) {
                LOCAL trial IS oldVal + sgn * steps[axis].
                IF axis <> "TIME" OR trial > minTime {
                    _setNodeAxis(nd, axis, trial).
                    LOCAL c IS _stableEval(_cost@).
                    IF c < best - 0.05 {
                        SET best TO c.
                        SET oldVal TO trial.
                        SET improved TO TRUE.
                    } ELSE {
                        _setNodeAxis(nd, axis, oldVal).
                        WAIT 0.02.
                    }
                }
            }
        }
        IF NOT improved {
            FOR axis IN axes { SET steps[axis] TO steps[axis] / 2. }
            IF steps["NORMAL"] < 0.1 AND steps["TIME"] < 1 { BREAK. }
        }
    }
    WAIT 0.05.
    RETURN _planeErrOf(nd:ORBIT, nTgt).
}

LOCAL FUNCTION _nodeAxis {
    PARAMETER nd, axis.
    IF axis = "TIME" { RETURN nd:TIME. }
    IF axis = "NORMAL" { RETURN nd:NORMAL. }
    IF axis = "PROGRADE" { RETURN nd:PROGRADE. }
    RETURN nd:RADIALOUT.
}

LOCAL FUNCTION _setNodeAxis {
    PARAMETER nd, axis, val.
    IF axis = "TIME" { SET nd:TIME TO val. }
    ELSE IF axis = "NORMAL" { SET nd:NORMAL TO val. }
    ELSE IF axis = "PROGRADE" { SET nd:PROGRADE TO val. }
    ELSE { SET nd:RADIALOUT TO val. }
}

// ============================================================
// _planTangentBurnAt — prograde/retrograde burn at burnEta that
// re-sizes the orbit so the FAR apsis radius becomes targetAlt.
// Exact at an apsis; used either at Pe/Ap or on a near-circular
// orbit (where every point is approximately an apsis).
// ============================================================
LOCAL FUNCTION _planTangentBurnAt {
    PARAMETER burnEta.
    PARAMETER burnTa.
    PARAMETER targetAlt.
    PARAMETER label.
    LOCAL mu IS SHIP:BODY:MU.
    // Radius and speed from the live elements at the burn's true
    // anomaly — no future-state prediction of any kind (both
    // VELOCITYAT and POSITIONAT differences proved contaminated
    // by the parent body's own motion in this kOS build).
    LOCAL rBurn IS _radiusAtTa(burnTa).
    LOCAL rTarget IS SHIP:BODY:RADIUS + targetAlt.
    LOCAL tSMA IS (rBurn + rTarget) / 2.
    LOCAL vNow IS _speedAtTa(burnTa).
    LOCAL vNew IS SQRT(mu * (2 / rBurn - 1 / tSMA)).
    LOCAL nd IS NODE(TIME:SECONDS + burnEta, 0, 0, vNew - vNow).
    ADD nd.
    mLog(label + " node: dV=" + ROUND(nd:DELTAV:MAG, 1)
        + " m/s  targetAlt=" + ROUND(targetAlt / 1000, 1)
        + "km  ETA=" + ROUND(burnEta, 0) + "s").
    archivePlannedManeuverLog(label).
    RETURN nd.
}

// ============================================================
// _placedApsisTa — TRUE ANOMALY of the point of the
// (near-circular) orbit where the target periapsis should sit:
// argument of latitude = target AoP, measured from the ascending
// node in the direction of motion. Sense resolved empirically.
// ============================================================
LOCAL FUNCTION _placedApsisTa {
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
    RETURN SHIP:ORBIT:TRUEANOMALY + ang.
}

LOCAL FUNCTION _peFloor {
    IF SHIP:BODY:ATM:EXISTS { RETURN SHIP:BODY:ATM:HEIGHT + 10000. }
    RETURN 10000.
}

// Evaluate a cost delegate until two consecutive reads agree.
// Flight-found: nd:ORBIT readouts immediately after a node tweak
// can be stale/noisy — a descent steering on phantom values
// "accepted" its way to Pe -106km when every such state priced
// at 9999. Double-reading makes acceptance decisions honest.
LOCAL FUNCTION _stableEval {
    PARAMETER costFn.
    WAIT 0.02.
    LOCAL c1 IS costFn:CALL().
    WAIT 0.02.
    LOCAL c2 IS costFn:CALL().
    LOCAL tries IS 0.
    UNTIL ABS(c1 - c2) < 0.02 OR tries >= 5 {
        SET c1 TO c2.
        WAIT 0.02.
        SET c2 TO costFn:CALL().
        SET tries TO tries + 1.
    }
    RETURN c2.
}

// Trust-region cost for refining ONE burn: the burn's own
// objective plus HEAVY penalties for touching anything else.
// Flight-found: a composite all-contract cost let a 64deg AoP
// error bully a clean 49 m/s Pe-raise into an orbit-wrecking AoP
// chase. Each burn now minds its own business:
//   aop      — |AoP err| + 0.1/km drift of the apsides from NOW
//   apsis    — 0.5/km errors of BOTH apsides vs their targets
// All burns: 5/deg plane drift from NOW, dV capped at 2x the
// analytic seed + 15, unsafe orbits priced out.
LOCAL FUNCTION _burnCostOf {
    PARAMETER o, label, targets, dvMag, seedDv, peNow, apNow, nNow.
    IF o:ECCENTRICITY >= 1 OR o:PERIAPSIS < _peFloor() { RETURN 9999. }
    IF dvMag > seedDv * 2 + 15 { RETURN 9999. }

    LOCAL cost IS dvMag * 0.01
        + VANG(planeNormalFromIncLan(o:INCLINATION, o:LAN), nNow) * 5.

    IF label = "aop" {
        SET cost TO cost
            + ABS(_angDiff(o:ARGUMENTOFPERIAPSIS, targets["AOP"]))
            + (ABS(o:APOAPSIS - apNow) + ABS(o:PERIAPSIS - peNow)) * 0.0001.
    } ELSE {
        // Tangent apsis burns: the objective is THIS burn's apsis
        // ONLY — the other apsis is the next burn's job, preserved
        // (vs now) rather than chased (flight-found: a perfect
        // 1.8 m/s set-ap seed was discarded at cost 68.9 because
        // it was charged for a 137km Pe error it cannot touch).
        LOCAL apexObjective IS label = "set-ap" OR label = "placed-pe"
            OR label = "set-pe-for-ap".
        IF apexObjective {
            LOCAL apTgt IS apNow.
            IF targets:HASKEY("AP") { SET apTgt TO targets["AP"]. }
            SET cost TO cost + ABS(o:APOAPSIS - apTgt) * 0.0005
                + ABS(o:PERIAPSIS - peNow) * 0.0001.
        } ELSE {
            LOCAL peTgt IS peNow.
            IF targets:HASKEY("PE") { SET peTgt TO targets["PE"]. }
            SET cost TO cost + ABS(o:PERIAPSIS - peTgt) * 0.0005
                + ABS(o:APOAPSIS - apNow) * 0.0001.
        }
    }
    RETURN cost.
}

// Game-truth refinement of a single burn within its trust region.
// Axes: TIME (a misplaced seed can be a sizeable fraction of the
// period off), RADIALOUT, PROGRADE. NORMAL is excluded — plane
// work belongs to the plane burn, and the plane-drift penalty
// guards the rest.
LOCAL FUNCTION _refineBurnNode {
    PARAMETER nd, label, targets.
    LOCAL peNow IS SHIP:PERIAPSIS.
    LOCAL apNow IS SHIP:APOAPSIS.
    LOCAL nNow IS planeNormalFromIncLan(
        SHIP:ORBIT:INCLINATION, SHIP:ORBIT:LAN).
    WAIT 0.02.
    LOCAL seedDv IS MAX(5, nd:DELTAV:MAG).

    LOCAL axes IS LIST("TIME", "RADIALOUT", "PROGRADE").
    LOCAL steps IS LEXICON(
        "TIME", MAX(60, SHIP:ORBIT:PERIOD / 16),
        "RADIALOUT", MAX(4, seedDv / 8),
        "PROGRADE", MAX(2, seedDv / 16)).
    LOCAL minTime IS TIME:SECONDS + 60.

    LOCAL FUNCTION _cost {
        RETURN _burnCostOf(nd:ORBIT, label, targets,
            nd:DELTAV:MAG, seedDv, peNow, apNow, nNow).
    }

    LOCAL best IS _stableEval(_cost@).
    FROM { LOCAL i IS 0. } UNTIL i >= 60 STEP { SET i TO i + 1. } DO {
        LOCAL improved IS FALSE.
        FOR axis IN axes {
            LOCAL oldVal IS _nodeAxis(nd, axis).
            FOR sgn IN LIST(1, -1) {
                LOCAL trial IS oldVal + sgn * steps[axis].
                IF axis <> "TIME" OR trial > minTime {
                    _setNodeAxis(nd, axis, trial).
                    LOCAL c IS _stableEval(_cost@).
                    IF c < best - 0.05 {
                        SET best TO c.
                        SET oldVal TO trial.
                        SET improved TO TRUE.
                    } ELSE {
                        _setNodeAxis(nd, axis, oldVal).
                        WAIT 0.02.
                    }
                }
            }
        }
        IF NOT improved {
            FOR axis IN axes { SET steps[axis] TO steps[axis] / 2. }
            IF steps["RADIALOUT"] < 0.1 AND steps["TIME"] < 1 { BREAK. }
        }
    }
    RETURN _stableEval(_cost@).
}

LOCAL FUNCTION _nodeUnsafe {
    PARAMETER nd.
    RETURN nd:ORBIT:ECCENTRICITY >= 1 OR nd:ORBIT:PERIAPSIS < _peFloor().
}

// A non-plane burn must never trash the plane we already paid
// for (flight-found: a refined "set-pe" was accepted at inc 41
// from a 138.9 plane because it was merely SAFE).
LOCAL FUNCTION _nodeWrecksPlane {
    PARAMETER nd.
    RETURN VANG(
        planeNormalFromIncLan(nd:ORBIT:INCLINATION, nd:ORBIT:LAN),
        planeNormalFromIncLan(SHIP:ORBIT:INCLINATION, SHIP:ORBIT:LAN)) > 5.
}

// One-shot stable cost of a node as it stands (no refinement).
LOCAL FUNCTION _burnCostNow {
    PARAMETER nd, label, targets.
    LOCAL peNow IS SHIP:PERIAPSIS.
    LOCAL apNow IS SHIP:APOAPSIS.
    LOCAL nNow IS planeNormalFromIncLan(
        SHIP:ORBIT:INCLINATION, SHIP:ORBIT:LAN).
    LOCAL FUNCTION _c {
        RETURN _burnCostOf(nd:ORBIT, label, targets,
            nd:DELTAV:MAG, MAX(5, nd:DELTAV:MAG), peNow, apNow, nNow).
    }
    RETURN _stableEval(_c@).
}

// Refine a planned non-plane burn within its trust region.
// If refinement misbehaves, REVERT TO THE ANALYTIC SEED — the
// tangent/rotation seeds are exact math and deserve to fly even
// when the optimizer cannot be trusted. Only discard when the
// seed itself is unsafe, plane-wrecking, or simply does not
// accomplish its objective (cost gate — flight-found: a stuck
// refine delivered AoP 17 for a target of 269 at cost 117 and
// was accepted because it was merely SAFE). Returns LEX or 0.
LOCAL FUNCTION _finishShapeNode {
    PARAMETER nd, label, targets.
    IF nd = 0 { RETURN 0. }

    // Snapshot the analytic seed, and log what the game thinks
    // of it (diagnostic for the nd:ORBIT staleness question).
    LOCAL seedTime IS nd:TIME.
    LOCAL seedRad IS nd:RADIALOUT.
    LOCAL seedNorm IS nd:NORMAL.
    LOCAL seedPro IS nd:PROGRADE.
    WAIT 0.1.
    mLogWarn("STATS shape-seed label=" + label
        + " dv=" + ROUND(nd:DELTAV:MAG, 1)
        + " predictPeKm=" + ROUND(nd:ORBIT:PERIAPSIS / 1000, 1)
        + " predictApKm=" + ROUND(nd:ORBIT:APOAPSIS / 1000, 1)
        + " predictAoP=" + ROUND(nd:ORBIT:ARGUMENTOFPERIAPSIS, 1)).

    LOCAL cost IS _refineBurnNode(nd, label, targets).
    WAIT 0.05.
    IF _nodeUnsafe(nd) OR _nodeWrecksPlane(nd) {
        mLogWarn("SHAPE: " + label + " refine went bad (Pe "
            + ROUND(nd:ORBIT:PERIAPSIS / 1000, 1)
            + "km, inc " + ROUND(nd:ORBIT:INCLINATION, 1)
            + ") — reverting to the analytic seed.").
        SET nd:TIME TO seedTime.
        SET nd:RADIALOUT TO seedRad.
        SET nd:NORMAL TO seedNorm.
        SET nd:PROGRADE TO seedPro.
        WAIT 0.1.
        IF (_nodeUnsafe(nd) OR _nodeWrecksPlane(nd)) AND ABS(seedRad) > 1 {
            // Suspected radial sign error in the analytic seed
            // (the AoP impulse family) — try the mirror.
            SET nd:RADIALOUT TO -seedRad.
            WAIT 0.1.
            IF _nodeUnsafe(nd) OR _nodeWrecksPlane(nd) {
                SET nd:RADIALOUT TO seedRad.
                WAIT 0.05.
            } ELSE {
                mLogWarn("SHAPE: " + label
                    + " seed radial sign flipped — refining from mirror.").
                SET cost TO _refineBurnNode(nd, label, targets).
                WAIT 0.05.
            }
        }
        IF _nodeUnsafe(nd) OR _nodeWrecksPlane(nd) {
            mLogError("SHAPE: " + label + " seed itself bad (Pe "
                + ROUND(nd:ORBIT:PERIAPSIS / 1000, 1) + "km ecc "
                + ROUND(nd:ORBIT:ECCENTRICITY, 2)
                + " inc " + ROUND(nd:ORBIT:INCLINATION, 1)
                + ") — discarding.").
            REMOVE nd.
            RETURN 0.
        }
        SET cost TO _burnCostNow(nd, label, targets).
    }

    // Quality gate: safe is not enough — the burn must actually
    // accomplish its objective. A good burn costs single digits.
    IF cost > 30 {
        mLogError("SHAPE: " + label
            + " burn cannot reach its objective (cost "
            + ROUND(cost, 1) + ") — discarding.").
        REMOVE nd.
        RETURN 0.
    }

    mLog("SHAPE " + label + ": dV=" + ROUND(nd:DELTAV:MAG, 1)
        + " m/s -> " + ROUND(nd:ORBIT:PERIAPSIS / 1000, 1) + " x "
        + ROUND(nd:ORBIT:APOAPSIS / 1000, 1) + " km  AoP "
        + ROUND(nd:ORBIT:ARGUMENTOFPERIAPSIS, 1)
        + "  cost=" + ROUND(cost, 2)).
    mLogWarn("STATS shape-refine label=" + label
        + " dv=" + ROUND(nd:DELTAV:MAG, 1)
        + " cost=" + ROUND(cost, 2)).
    RETURN LEX("node", nd, "label", label).
}

// ============================================================
// shapeNextBurn — plan the single most-needed correction burn.
// Returns LEX("node", nd, "label", text) or 0 when converged
// (or nothing useful can be planned).
//
// Priority: PLANE -> placed apsis (circular start) -> AP -> PE
// -> AOP. Apsides come BEFORE the AoP rotation: tangential apsis
// burns never move the apsidal line, and rotating AoP at the
// (usually lower) target eccentricity is cheaper. Every non-plane
// burn is refined against nd:ORBIT before being returned. Each
// call re-reads the live orbit, so the sequence self-heals.
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
                LOCAL ta1 IS _placedApsisTa(targets["AOP"]).
                LOCAL eta1 IS etaToTrueAnomaly(ta1).
                IF eta1 < 60 { SET eta1 TO eta1 + SHIP:ORBIT:PERIOD. }
                RETURN _finishShapeNode(
                    _planTangentBurnAt(eta1, ta1, targets["AP"], "placed-pe"),
                    "placed-pe", targets).
            }
            IF targets:HASKEY("PE") {
                // Shrinking orbit: burn retrograde at the desired AP
                // location (AoP+180), lowering the opposite side to PE.
                LOCAL ta2 IS _placedApsisTa(targets["AOP"] + 180).
                LOCAL eta2 IS etaToTrueAnomaly(ta2).
                IF eta2 < 60 { SET eta2 TO eta2 + SHIP:ORBIT:PERIOD. }
                RETURN _finishShapeNode(
                    _planTangentBurnAt(eta2, ta2, targets["PE"], "placed-ap"),
                    "placed-ap", targets).
            }
        }
    }

    // --- 3 & 4. Apsides BEFORE the AoP rotation: tangential apsis
    // burns never move the apsidal line, and the rotation is
    // cheaper at the (usually lower) target eccentricity. Order by
    // feasibility: an Ap target below the current Pe cannot be set
    // from Pe, so fix Pe first then. ---
    LOCAL needAp2 IS errs:HASKEY("AP") AND ABS(errs["AP"]) > altTol.
    LOCAL needPe2 IS errs:HASKEY("PE") AND ABS(errs["PE"]) > altTol.

    IF needAp2 AND targets["AP"] >= SHIP:PERIAPSIS {
        LOCAL etaPe IS ETA:PERIAPSIS.
        IF etaPe < 60 { SET etaPe TO etaPe + SHIP:ORBIT:PERIOD. }
        RETURN _finishShapeNode(
            _planTangentBurnAt(etaPe, 0, targets["AP"], "set-ap"),
            "set-ap", targets).
    }
    IF needPe2 {
        LOCAL etaAp IS ETA:APOAPSIS.
        IF etaAp < 60 { SET etaAp TO etaAp + SHIP:ORBIT:PERIOD. }
        RETURN _finishShapeNode(
            _planTangentBurnAt(etaAp, 180, targets["PE"], "set-pe"),
            "set-pe", targets).
    }

    // --- 5. Argument of periapsis (in-plane apsidal rotation) ---
    IF errs:HASKEY("AOP") AND ABS(errs["AOP"]) > aopTol
            AND SHIP:ORBIT:ECCENTRICITY >= NEAR_CIRC_ECC {
        RETURN _finishShapeNode(
            planAoPChange(targets["AOP"]), "aop", targets).
    }
    IF needAp2 {
        // AP target below current Pe and PE already in tolerance:
        // dip via the Ap burn anyway; next round restores PE.
        LOCAL etaAp2 IS ETA:APOAPSIS.
        IF etaAp2 < 60 { SET etaAp2 TO etaAp2 + SHIP:ORBIT:PERIOD. }
        RETURN _finishShapeNode(
            _planTangentBurnAt(etaAp2, 180, targets["AP"], "set-pe-for-ap"),
            "set-pe-for-ap", targets).
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
    mLogWarn("STATS shape result solved=" + ok
        + " burns=" + burns
        + _errorSummary(finalErrs)).
    IF ok {
        mLog("SHAPE complete in " + burns + " burns" + _errorSummary(finalErrs)).
        nextPhase(xferSeq).
        RETURN.
    }
    // Unconverged is an OPERATOR decision, never a silent advance
    // (flight-found: a discarded burn marched the mission on to
    // RELAY_OPS with a 68km Pe error still on the books).
    mLogError("SHAPE unconverged after " + burns + " burns"
        + _errorSummary(finalErrs)).
    PRINT " ".
    PRINT "  SHAPE UNCONVERGED — holding this phase.".
    PRINT "  Reboot to replan, or setphase to skip:".
    PRINT "  RUNPATH(" + CHAR(34) + "1:/cmd/setphase.ks" + CHAR(34)
        + ", " + CHAR(34) + "RELAY_OPS" + CHAR(34) + ").".
    yieldToPrompt().
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
