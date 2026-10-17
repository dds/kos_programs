// ============================================================
// return_direct.ks - Landed direct-to-Kerbin feasibility preview
// (0:/lib/return_direct.ks)
//
// Single-stage finite thrust/mass, followed by analytic SOI propagation.
// This searches candidates; it does NOT authorize or execute an ascent.
// Terrain, attitude/staging and subsequent encounters need flight validation.
// ============================================================
@LAZYGLOBAL OFF.

LOCAL FUNCTION _rdComponents {
    PARAMETER vec.
    PARAMETER axes.
    RETURN V(VDOT(vec, axes[0]), VDOT(vec, axes[1]), VDOT(vec, axes[2])).
}

// Every numerical vector uses a frozen, Moon-parent orbital basis. No RAW
// vector survives a WAIT and no future VELOCITYAT frame is used.
LOCAL FUNCTION _rdSnapshot {
    LOCAL out IS LEXICON("VALID", FALSE, "REASON", "requires-landed-Mun-or-Minmus").
    IF SHIP:STATUS <> "LANDED" { RETURN out. }
    LOCAL moon IS SHIP:BODY.
    IF moon:NAME <> "Mun" AND moon:NAME <> "Minmus" { RETURN out. }
    SET out["REASON"] TO "requires-circular-airless-moon-orbit-around-Kerbin".
    IF moon:BODY:NAME <> "Kerbin" OR moon:ATM:EXISTS
            OR moon:ORBIT:ECCENTRICITY > 0.000001 { RETURN out. }
    LOCAL thrustSum IS 0.
    LOCAL flowSum IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT AND NOT eng:THROTTLELOCK
                AND eng:AVAILABLETHRUST > 0 AND eng:VISP > 0 {
            SET thrustSum TO thrustSum + eng:AVAILABLETHRUST.
            SET flowSum TO flowSum + eng:AVAILABLETHRUST / (eng:VISP * CONSTANT:G0).
        }
    }
    SET out["REASON"] TO "requires-enabled-liquid-engine-and-current-stage-dV".
    LOCAL available IS MIN(STAGE:DELTAV:VACUUM, SHIP:DELTAV:VACUUM).
    IF SHIP:MASS <= 0 OR thrustSum <= 0 OR flowSum <= 0 OR available <= 0 { RETURN out. }
    LOCAL epoch IS TIME:SECONDS.
    LOCAL parentRadius IS moon:POSITION - moon:BODY:POSITION.
    LOCAL radial IS parentRadius:NORMALIZED.
    LOCAL parentVel IS (POSITIONAT(moon, epoch + 0.5) - POSITIONAT(moon, epoch - 0.5)).
    LOCAL tangent IS VXCL(radial, parentVel).
    SET out["REASON"] TO "degenerate-parent-orbit".
    IF tangent:MAG < 0.01 OR moon:ORBIT:PERIOD <= 0 { RETURN out. }
    SET tangent TO tangent:NORMALIZED.
    LOCAL axes IS LIST(radial, tangent, VCRS(radial, tangent):NORMALIZED).
    LOCAL startPos IS _rdComponents(SHIP:POSITION - moon:POSITION, axes).
    LOCAL acceleration IS thrustSum / SHIP:MASS.
    LOCAL grav IS moon:MU / startPos:MAG ^ 2.
    SET out["REASON"] TO "surface-TWR-not-above-one".
    IF acceleration <= grav { RETURN out. }
    RETURN LEXICON("VALID", TRUE, "REASON", "ok", "EPOCH", epoch,
        "POS", startPos, "VEL", _rdComponents(SHIP:VELOCITY:ORBIT, axes),
        "NORTH", _rdComponents(HEADING(0, 0):FOREVECTOR, axes),
        "EAST", _rdComponents(HEADING(90, 0):FOREVECTOR, axes),
        "MU", moon:MU, "RADIUS", moon:RADIUS, "SOI", moon:SOIRADIUS,
        "PARENT_MU", moon:BODY:MU, "PARENT_RADIUS", moon:BODY:RADIUS,
        "MOON_RADIUS", parentRadius:MAG, "PERIOD", moon:ORBIT:PERIOD,
        "ACC", acceleration, "VE", thrustSum / flowSum, "AVAILABLE", available,
        "CLEAR_TIME", SQRT(300 / (acceleration - grav))).
}

// Time since periapsis, with the parabolic limit kept finite. Only the
// outbound branch is used; no elliptic anomaly-wrap ambiguity is needed.
LOCAL FUNCTION _rdConicTime {
    PARAMETER ecc.
    PARAMETER semiLatus.
    PARAMETER mu.
    PARAMETER cosine.
    PARAMETER sine.
    IF ABS(ecc - 1) < 0.0000001 {
        LOCAL barker IS sine / MAX(0.000000001, 1 + cosine).
        RETURN 0.5 * SQRT(semiLatus ^ 3 / mu) * (barker + barker ^ 3 / 3).
    }
    LOCAL semiMajor IS semiLatus / (1 - ecc ^ 2).
    LOCAL meanMotion IS SQRT(mu / ABS(semiMajor) ^ 3).
    IF ecc > 1 {
        LOCAL sinhAnomaly IS sine * SQRT(ecc ^ 2 - 1) / (1 + ecc * cosine).
        LOCAL anomaly IS LN(sinhAnomaly + SQRT(1 + sinhAnomaly ^ 2)).
        RETURN (ecc * sinhAnomaly - anomaly) / meanMotion.
    }
    LOCAL anomalyDeg IS ARCTAN2(SQRT(1 - ecc ^ 2) * sine, ecc + cosine).
    RETURN (anomalyDeg * CONSTANT:PI / 180 - ecc * SIN(anomalyDeg)) / meanMotion.
}

LOCAL FUNCTION rdCoastToSoi {
    PARAMETER pos.
    PARAMETER vel.
    PARAMETER mu.
    PARAMETER soiRadius.
    LOCAL invalid IS LEXICON("VALID", FALSE).
    LOCAL radiusMag IS pos:MAG.
    IF radiusMag <= 0 OR mu <= 0 OR radiusMag >= soiRadius { RETURN invalid. }
    LOCAL radialProduct IS VDOT(pos, vel).
    IF radialProduct < 0 { RETURN invalid. }
    LOCAL angular IS VCRS(pos, vel).
    LOCAL semiLatus IS angular:MAG ^ 2 / mu.
    IF semiLatus < 0.01 { RETURN invalid. }
    LOCAL eccentricVec IS ((vel:MAG ^ 2 - mu / radiusMag) * pos - radialProduct * vel) / mu.
    LOCAL ecc IS eccentricVec:MAG.
    IF ecc < 0.000001 { RETURN invalid. }
    LOCAL cosineExit IS (semiLatus / soiRadius - 1) / ecc.
    IF cosineExit <= -1 OR cosineExit >= 1 { RETURN invalid. }
    LOCAL sineExit IS SQRT(MAX(0, 1 - cosineExit ^ 2)).
    LOCAL periAxis IS eccentricVec / ecc.
    LOCAL transverse IS VCRS(angular:NORMALIZED, periAxis).
    LOCAL cosineNow IS MAX(-1, MIN(1, VDOT(pos, periAxis) / radiusMag)).
    LOCAL sineNow IS MAX(0, MIN(1, VDOT(pos, transverse) / radiusMag)).
    LOCAL coastTime IS _rdConicTime(ecc, semiLatus, mu, cosineExit, sineExit)
        - _rdConicTime(ecc, semiLatus, mu, cosineNow, sineNow).
    IF coastTime <= 0 OR coastTime > 1000000 { RETURN invalid. }
    RETURN LEXICON("VALID", TRUE, "TIME", coastTime,
        "POS", soiRadius * (cosineExit * periAxis + sineExit * transverse),
        "VEL", SQRT(mu / semiLatus) * (-sineExit * periAxis + (ecc + cosineExit) * transverse)).
}

LOCAL FUNCTION _rdAcceleration {
    PARAMETER pos.
    PARAMETER ctx.
    PARAMETER program.
    PARAMETER planeNormal.
    PARAMETER elapsed.
    LOCAL radial IS pos:NORMALIZED.
    LOCAL tangent IS VCRS(planeNormal, radial):NORMALIZED.
    LOCAL fraction IS MAX(0, elapsed - ctx["CLEAR_TIME"]) / program["TURN"].
    LOCAL pitchDeg IS program["FLOOR"] + (90 - program["FLOOR"])
        * CONSTANT:E ^ (-(fraction ^ program["POWER"])).
    LOCAL acc IS ctx["ACC"] / (1 - ctx["ACC"] * elapsed / ctx["VE"]).
    RETURN acc * (SIN(pitchDeg) * radial + COS(pitchDeg) * tangent)
        - ctx["MU"] * radial / pos:MAG ^ 2.
}

// RK4 variable-mass powered ascent, with no parking-orbit constraint.
LOCAL FUNCTION rdPredict {
    PARAMETER ctx.
    PARAMETER program.
    PARAMETER stepSec.
    LOCAL out IS LEXICON("VALID", FALSE, "REASON", "fuel-or-parameters", "SCORE", 3000000000).
    IF program["DV"] <= 0 OR program["DV"] > ctx["BUDGET"]
            OR program["TURN"] <= 0 OR program["POWER"] <= 0 OR stepSec <= 0 { RETURN out. }
    LOCAL pos IS ctx["POS"].
    LOCAL vel IS ctx["VEL"].
    LOCAL planeNormal IS VCRS(pos, ctx["NORTH"] * COS(program["AZ"])
        + ctx["EAST"] * SIN(program["AZ"])):NORMALIZED.
    LOCAL duration IS ctx["VE"] / ctx["ACC"] * (1 - CONSTANT:E ^ (-program["DV"] / ctx["VE"])).
    LOCAL elapsed IS 0.
    UNTIL elapsed >= duration {
        LOCAL dt IS MIN(stepSec, duration - elapsed).
        LOCAL acc1 IS _rdAcceleration(pos, ctx, program, planeNormal, elapsed).
        LOCAL vel2 IS vel + acc1 * dt / 2.
        LOCAL acc2 IS _rdAcceleration(pos + vel * dt / 2, ctx, program, planeNormal, elapsed + dt / 2).
        LOCAL vel3 IS vel + acc2 * dt / 2.
        LOCAL acc3 IS _rdAcceleration(pos + vel2 * dt / 2, ctx, program, planeNormal, elapsed + dt / 2).
        LOCAL vel4 IS vel + acc3 * dt.
        LOCAL acc4 IS _rdAcceleration(pos + vel3 * dt, ctx, program, planeNormal, elapsed + dt).
        SET pos TO pos + (vel + 2 * vel2 + 2 * vel3 + vel4) * dt / 6.
        SET vel TO vel + (acc1 + 2 * acc2 + 2 * acc3 + acc4) * dt / 6.
        SET elapsed TO elapsed + dt.
        IF pos:MAG < ctx["POS"]:MAG - 1 {
            SET out["REASON"] TO "below-starting-surface-radius".
            RETURN out.
        }
    }
    LOCAL coast IS rdCoastToSoi(pos, vel, ctx["MU"], ctx["SOI"]).
    IF NOT coast["VALID"] {
        LOCAL energy IS vel:MAG ^ 2 / 2 - ctx["MU"] / pos:MAG.
        LOCAL angular IS VCRS(pos, vel).
        LOCAL needed IS angular:MAG ^ 2 / (2 * ctx["SOI"] ^ 2) - ctx["MU"] / ctx["SOI"].
        SET out["SCORE"] TO 1000000 + MAX(0, needed - energy) / 10
            + MAX(0, -VDOT(pos, vel) / pos:MAG) * 100.
        SET out["REASON"] TO "no-outbound-SOI-crossing".
        RETURN out.
    }
    LOCAL phaseDeg IS 360 * (duration + coast["TIME"]) / ctx["PERIOD"].
    LOCAL parentPos IS ctx["MOON_RADIUS"] * V(COS(phaseDeg), SIN(phaseDeg), 0) + coast["POS"].
    LOCAL parentVel IS 2 * CONSTANT:PI * ctx["MOON_RADIUS"] / ctx["PERIOD"]
        * V(-SIN(phaseDeg), COS(phaseDeg), 0) + coast["VEL"].
    LOCAL parentEnergy IS parentVel:MAG ^ 2 / 2 - ctx["PARENT_MU"] / parentPos:MAG.
    IF parentEnergy >= 0 {
        SET out["REASON"] TO "unbound-Kerbin-orbit".
        SET out["SCORE"] TO 1000000 + parentEnergy / 10.
        RETURN out.
    }
    LOCAL eccentricVec IS ((parentVel:MAG ^ 2 - ctx["PARENT_MU"] / parentPos:MAG) * parentPos
        - VDOT(parentPos, parentVel) * parentVel) / ctx["PARENT_MU"].
    LOCAL angular IS VCRS(parentPos, parentVel).
    LOCAL pe IS angular:MAG ^ 2 / (ctx["PARENT_MU"] * (1 + eccentricVec:MAG)) - ctx["PARENT_RADIUS"].
    RETURN LEXICON("VALID", TRUE, "REASON", "model-candidate", "PE", pe,
        "SCORE", program["DV"] + ABS(pe - ctx["TARGET_PE"]) * 0.02,
        "BURN_TIME", duration, "COAST_TIME", coast["TIME"], "BURNOUT_ALT", pos:MAG - ctx["RADIUS"]).
}

LOCAL FUNCTION _rdProgram {
    PARAMETER azimuth.
    PARAMETER turnTime.
    PARAMETER power_.
    PARAMETER pitchFloor.
    PARAMETER impulse.
    RETURN LEXICON("AZ", azimuth, "TURN", turnTime, "POWER", power_, "FLOOR", pitchFloor, "DV", impulse).
}

LOCAL FUNCTION _rdTuneEntry {
    PARAMETER ctx.
    PARAMETER program.
    LOCAL base IS rdPredict(ctx, program, 0.25).
    LOCAL iter IS 0.
    UNTIL iter >= 8 OR NOT base["VALID"] {
        IF ABS(base["PE"] - ctx["TARGET_PE"]) <= 100 { BREAK. }
        LOCAL probe IS _rdProgram(program["AZ"], program["TURN"], program["POWER"], program["FLOOR"], program["DV"] - MIN(1, program["DV"] / 2)).
        LOCAL response IS rdPredict(ctx, probe, 0.25).
        IF NOT response["VALID"] { BREAK. }
        LOCAL slope IS (response["PE"] - base["PE"]) / (probe["DV"] - program["DV"]).
        IF ABS(slope) < 1 { BREAK. }
        LOCAL oldDv IS program["DV"].
        SET program["DV"] TO MAX(0.1, MIN(ctx["BUDGET"], oldDv
            + MAX(-20, MIN(20, (ctx["TARGET_PE"] - base["PE"]) / slope)))).
        LOCAL trial IS rdPredict(ctx, program, 0.25).
        IF NOT trial["VALID"] { SET program["DV"] TO oldDv. BREAK. }
        IF ABS(trial["PE"] - ctx["TARGET_PE"]) >= ABS(base["PE"] - ctx["TARGET_PE"]) {
            SET program["DV"] TO oldDv. BREAK.
        }
        SET base TO trial.
        SET iter TO iter + 1.
    }
    RETURN program.
}

LOCAL FUNCTION _rdRestoreIpu {
    PARAMETER priorIpu.
    SET CONFIG:IPU TO priorIpu.
    IF priorIpu < 2000 { stateRemove("burn_prior_ipu"). }
}

GLOBAL FUNCTION previewDirectReturn {
    PARAMETER targetPe IS 53000.
    PARAMETER reserveDv IS 20.
    PARAMETER search IS TRUE.
    IF targetPe < 0 OR reserveDv < 0 { PRINT "Target Pe and reserve must be nonnegative.". RETURN FALSE. }
    IF ABORT OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 OR WARP <> 0 {
        PRINT "Stop automation with zero throttle/thrust and warp before previewing.". RETURN FALSE.
    }
    LOCAL ctx IS _rdSnapshot().
    IF NOT ctx["VALID"] { PRINT "Direct return preview: " + ctx["REASON"]. RETURN FALSE. }
    SET ctx["BUDGET"] TO MAX(0, ctx["AVAILABLE"] - reserveDv).
    SET ctx["TARGET_PE"] TO targetPe.
    IF ctx["BUDGET"] <= 0 { PRINT "No current-stage fuel beyond the requested reserve.". RETURN FALSE. }
    PRINT "DIRECT RETURN PREVIEW ONLY: no launch, node, staging or mission change".
    PRINT "Current stage dV=" + ROUND(ctx["AVAILABLE"],1) + " reserve=" + reserveDv
        + " acc=" + ROUND(ctx["ACC"],3) + " Isp=" + ROUND(ctx["VE"]/CONSTANT:G0,1).
    LOCAL snapshotText IS "STATS direct-return snapshot body=" + SHIP:BODY:NAME
        + " epoch=" + ctx["EPOCH"] + " stage=" + STAGE:NUMBER
        + " lat=" + SHIP:LATITUDE + " lng=" + SHIP:LONGITUDE
        + " available=" + ctx["AVAILABLE"] + " acc=" + ctx["ACC"] + " ve=" + ctx["VE"]
        + " pos=" + ctx["POS"] + " vel=" + ctx["VEL"]
        + " north=" + ctx["NORTH"] + " east=" + ctx["EAST"]
        + " mu=" + ctx["MU"] + " radius=" + ctx["RADIUS"] + " soi=" + ctx["SOI"]
        + " parentMu=" + ctx["PARENT_MU"] + " parentRadius=" + ctx["PARENT_RADIUS"]
        + " moonRadius=" + ctx["MOON_RADIUS"] + " period=" + ctx["PERIOD"].
    mLog(snapshotText).
    IF NOT search { PRINT snapshotText. RETURN FALSE. }
    PRINT "Searching headings and finite-burn profiles for Kerbin Pe " + targetPe/1000 + " km...".
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < 2000 { stateSet("burn_prior_ipu", priorIpu). SET CONFIG:IPU TO 2000. }
    LOCAL best IS LEXICON("SCORE", 3000000001).
    LOCAL selected IS _rdProgram(90, 60, 1, 25, ctx["BUDGET"]).
    LOCAL cancelled IS FALSE.
    LOCAL azimuth IS 0.
    UNTIL azimuth >= 360 OR cancelled {
        FOR turnTime IN LIST(10, 60, 180) {
            FOR power_ IN LIST(1, 2) {
                FOR pitchFloor IN LIST(0, 25, 50) {
                    FOR fuelFraction IN LIST(0.6, 0.8, 1) {
                        IF ABORT OR SHIP:STATUS <> "LANDED" OR SHIP:THRUST > 0.001 {
                            SET cancelled TO TRUE. BREAK.
                        }
                        LOCAL program IS _rdProgram(azimuth, turnTime, power_, pitchFloor, ctx["BUDGET"] * fuelFraction).
                        LOCAL trial IS rdPredict(ctx, program, 3).
                        IF trial["SCORE"] < best["SCORE"] { SET best TO trial. SET selected TO program. }
                    }
                    IF cancelled { BREAK. }
                }
                IF cancelled { BREAK. }
            }
            IF cancelled { BREAK. }
        }
        PRINT "  Heading " + azimuth + " deg searched.".
        SET azimuth TO azimuth + 45.
        WAIT 0.
    }
    // Bounded coordinate refinement. This is a local search within one
    // pitch-program family, never a claim of a globally minimal ascent.
    FOR scale IN LIST(1, 0.3, 0.1, 0.03) {
        IF cancelled { BREAK. }
        FOR key IN LIST("AZ", "TURN", "POWER", "FLOOR", "DV") {
            LOCAL delta IS 30 * scale.
            IF key = "POWER" { SET delta TO 0.5 * scale. }
            IF key = "DV" { SET delta TO 60 * scale. }
            FOR sign_ IN LIST(-1, 1) {
                IF ABORT OR SHIP:STATUS <> "LANDED" OR SHIP:THRUST > 0.001 {
                    SET cancelled TO TRUE. BREAK.
                }
                LOCAL program IS _rdProgram(selected["AZ"], selected["TURN"], selected["POWER"], selected["FLOOR"], selected["DV"]).
                SET program[key] TO program[key] + sign_ * delta.
                SET program["AZ"] TO MOD(program["AZ"] + 360, 360).
                SET program["TURN"] TO MAX(5, MIN(240, program["TURN"])).
                SET program["POWER"] TO MAX(0.5, MIN(3, program["POWER"])).
                SET program["FLOOR"] TO MAX(0, MIN(60, program["FLOOR"])).
                SET program["DV"] TO MIN(ctx["BUDGET"], program["DV"]).
                LOCAL trial IS rdPredict(ctx, program, 3).
                IF trial["SCORE"] < best["SCORE"] { SET best TO trial. SET selected TO program. }
            }
            IF cancelled { BREAK. }
        }
        WAIT 0.
    }
    IF cancelled {
        _rdRestoreIpu(priorIpu).
        PRINT "Preview cancelled; flight controls and mission retained.". RETURN FALSE.
    }
    // Re-read live geometry after a potentially lengthy ground search.
    SET ctx TO _rdSnapshot().
    IF NOT ctx["VALID"] {
        _rdRestoreIpu(priorIpu).
        PRINT "Vehicle changed: " + ctx["REASON"]. RETURN FALSE.
    }
    SET ctx["BUDGET"] TO MAX(0, ctx["AVAILABLE"] - reserveDv).
    SET ctx["TARGET_PE"] TO targetPe.
    SET selected TO _rdTuneEntry(ctx, selected).
    LOCAL fine IS rdPredict(ctx, selected, 0.25).
    LOCAL finer IS rdPredict(ctx, selected, 0.125).
    _rdRestoreIpu(priorIpu).
    LOCAL found IS FALSE.
    LOCAL resultText IS finer["REASON"].
    IF fine["VALID"] AND finer["VALID"] {
        SET found TO ABS(finer["PE"] - targetPe) <= 1000 AND ABS(fine["PE"] - finer["PE"]) <= 100.
        SET resultText TO "predictedPeKm=" + ROUND(finer["PE"]/1000,3)
            + " integrationDifferenceM=" + ROUND(ABS(fine["PE"] - finer["PE"]),2).
    }
    IF ABORT OR SHIP:STATUS <> "LANDED" OR SHIP:THRUST > 0.001
            OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        SET found TO FALSE.
        SET resultText TO "vehicle-changed-during-preview".
    }
    PRINT "Model candidate at " + targetPe/1000 + " km +/-1 km: " + found + ".".
    PRINT "  " + resultText.
    PRINT "  dV=" + ROUND(selected["DV"],2) + " az=" + ROUND(selected["AZ"],2)
        + " turnTime=" + selected["TURN"] + " power=" + selected["POWER"] + " pitchFloor=" + selected["FLOOR"].
    IF NOT found { PRINT "No affordable candidate established by this search; this is not an impossibility proof.". }
    PRINT "Preview did not install flight guidance; the existing surface-return sequence is unchanged.".
    PRINT "Terrain, attitude and native KSP escape/entry still require validation.".
    mLog("STATS direct-return preview found=" + found + " epoch=" + ctx["EPOCH"]
        + " available=" + ctx["AVAILABLE"] + " reserve=" + reserveDv
        + " acc=" + ctx["ACC"] + " ve=" + ctx["VE"] + " dv=" + selected["DV"]
        + " az=" + selected["AZ"] + " turn=" + selected["TURN"]
        + " power=" + selected["POWER"] + " floor=" + selected["FLOOR"] + " " + resultText).
    RETURN found.
}
