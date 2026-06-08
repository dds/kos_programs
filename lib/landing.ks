// ============================================================
// landing.ks  —  Suicide burn landing  (0:/lib/landing.ks)
//
// Clean single-file landing library built around suicide burn
// physics. Handles powered descent from suborbital trajectory
// to touchdown, with optional carrier handoff post-landing.
//
// Entry point: landExecute()
// Also exports: landingResolveTarget(), landingTargetedDeorbit(),
//               landingImpactWithinTolerance(),
//               landingImpactAcceptableForAssist()
// ============================================================

// ------------------------------------------------------------
// Configuration
// ------------------------------------------------------------
GLOBAL LAND_CFG IS LEXICON(
    // Descent parameters
    "TOUCHDOWN_SPEED",    2.0,    // target vertical speed at ground (m/s)
    "HOVER_ALT",        100,      // alt to transition from full-brake to constant-decel
    "UPRIGHT_ALT",       10,      // alt to go pure vertical and hover to touchdown
    "BURN_MARGIN",        1.05,   // safety factor: start burn when TTI <= SBD * margin
    "MAX_TILT",          15,      // max steering lean during descent (degrees)

    // Target resolution
    "TARGET_LAT",           0,
    "TARGET_LNG",           0,
    "TARGET_BODY",         "",
    "TARGET_WAYPOINT",     "",
    "TARGET_LOCK",      FALSE,
    "TARGET_TOLERANCE",  2500,

    // Deorbit
    "DEORBIT_PE",       -3000,
    "DEORBIT_OVERSHOOT",    0,    // meters to overshoot target for carrier braking
    "DEORBIT_OVERSHOOT_TOLERANCE", 1200,
    "GUIDANCE_ALT",      5000,    // alt below which descent guidance stops (commit to SB)
    "GUIDANCE_CORRECTION_THRESHOLD", 500, // meters — don't correct if impact closer than this
    "GUIDANCE_MAX_DV",     15,    // m/s total correction budget for descent guidance

    // Carrier handoff (empty tag = no handoff)
    "CARRIER_TAG",       "",      // decoupler tag for carrier release
    "CARRIER_TIP",     TRUE,      // tip carrier sideways before release
    "CARRIER_TIP_TIME",  1.5,     // seconds to hold tip
    "CARRIER_SETTLE",    2.0,     // seconds to wait after touchdown before handoff
    "ROVER_ORIENT",    TRUE,      // orient rover upright after release
    "ROVER_ORIENT_TIME", 8.0,    // seconds to hold upright orientation
    "ROVER_BRAKE",     TRUE       // engage brakes after rover lands on wheels
).

// Backward-compat alias: code that checks DEFINED LANDING_CFG still works
GLOBAL LANDING_CFG IS LAND_CFG.

GLOBAL landingAbortFlag IS FALSE.

// ------------------------------------------------------------
// Core physics helpers
// ------------------------------------------------------------

// Effective gravity accounting for centrifugal force from ground speed
LOCAL FUNCTION _grav {
    LOCAL _r IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL g IS mu / (_r^2).
    LOCAL gs IS SHIP:GROUNDSPEED.
    IF gs > 1 AND _r > 0 {
        SET g TO g - (gs^2) / _r.
    }
    RETURN MAX(0.01, g).
}

// Maximum acceleration available (m/s^2)
LOCAL FUNCTION _maxAcc {
    IF SHIP:MASS <= 0 { RETURN 0. }
    RETURN SHIP:AVAILABLETHRUST / SHIP:MASS.
}

// Duration of a full-thrust suicide burn to kill current surface speed
LOCAL FUNCTION _suicideBurnDuration {
    LOCAL acc IS _maxAcc().
    LOCAL g IS _grav().
    LOCAL spd IS SHIP:VELOCITY:SURFACE:MAG.
    LOCAL vs IS SHIP:VERTICALSPEED.
    IF acc <= g { RETURN 99999. }
    // Project gravity along velocity vector for more accurate estimate
    IF spd < 0.1 { RETURN 0. }
    RETURN spd / (acc - g * ABS(vs) / spd).
}

// Time to impact assuming constant gravity, current vertical speed and alt
LOCAL FUNCTION _timeToImpact {
    LOCAL g IS _grav().
    LOCAL vs IS SHIP:VERTICALSPEED.
    LOCAL alt_ IS ALT:RADAR.
    IF alt_ <= 0 { RETURN 0. }
    // Quadratic: alt = vs*t + 0.5*g*t^2 (vs negative when descending)
    LOCAL disc IS vs^2 + 2 * alt_ * g.
    IF disc < 0 { RETURN 99999. }
    RETURN (SQRT(disc) + vs) / g.
}

// Target descent speed (positive, m/s) based on radar altitude.
// Schedule: >1000m = 20, 100-1000 = lerp 20->8, 10-100 = lerp 8->3, <10 = touchdown
LOCAL FUNCTION _descentSpeed {
    PARAMETER alt_.
    IF alt_ > 1000 { RETURN 20. }
    IF alt_ > 100 {
        RETURN 8 + (alt_ - 100) / 900 * 12.
    }
    IF alt_ > LAND_CFG["UPRIGHT_ALT"] {
        RETURN LAND_CFG["TOUCHDOWN_SPEED"] + (alt_ - LAND_CFG["UPRIGHT_ALT"])
            / (100 - LAND_CFG["UPRIGHT_ALT"]) * (8 - LAND_CFG["TOUCHDOWN_SPEED"]).
    }
    RETURN LAND_CFG["TOUCHDOWN_SPEED"].
}

// Horizontal surface velocity vector (surface velocity minus vertical component)
LOCAL FUNCTION _hVel {
    LOCAL upVec IS SHIP:UP:VECTOR.
    RETURN SHIP:VELOCITY:SURFACE - (VDOT(SHIP:VELOCITY:SURFACE, upVec) * upVec).
}

// ------------------------------------------------------------
// Steering helpers
// ------------------------------------------------------------

// Steering vector that is mostly retrograde but leans up to MAX_TILT
// toward killing horizontal velocity. Transitions smoothly to
// UP-biased steering as speed drops to avoid retrograde jitter.
LOCAL FUNCTION _burnSteering {
    LOCAL sVel IS SHIP:VELOCITY:SURFACE.
    LOCAL spd IS sVel:MAG.
    // Below 15 m/s the retrograde vector is too unstable on a
    // high-TWR vessel — switch to hover steering which is UP-biased
    IF spd < 15 { RETURN _hoverSteering(). }
    LOCAL retro IS (-sVel):NORMALIZED.
    LOCAL hv IS _hVel().
    IF hv:MAG < 0.5 { RETURN retro. }
    LOCAL maxLean IS SIN(LAND_CFG["MAX_TILT"]).
    LOCAL lean IS MIN(maxLean, hv:MAG / 20).
    RETURN (retro + SHIP:UP:VECTOR * lean):NORMALIZED.
}

// Hover steering: mostly UP with lean to cancel horizontal drift
LOCAL FUNCTION _hoverSteering {
    LOCAL hv IS _hVel().
    IF hv:MAG < 0.3 { RETURN SHIP:UP:VECTOR. }
    LOCAL maxLean IS SIN(LAND_CFG["MAX_TILT"]).
    LOCAL lean IS MIN(maxLean, hv:MAG / 10).
    RETURN (SHIP:UP:VECTOR + (-hv):NORMALIZED * lean):NORMALIZED.
}

// ------------------------------------------------------------
// Descent guidance — mid-course corrections during coast
// ------------------------------------------------------------
// Called during Phase 2 coast above GUIDANCE_ALT. Uses Trajectories
// to read predicted impact and fires small correction burns to
// steer impact toward the target. Tracks cumulative dV and stops
// when the budget (GUIDANCE_MAX_DV) is exhausted.

LOCAL FUNCTION _descentGuidance {
    PARAMETER targetLat.
    PARAMETER targetLng.

    IF NOT ADDONS:TR:AVAILABLE { RETURN. }

    LOCAL maxDv IS LAND_CFG["GUIDANCE_MAX_DV"].
    LOCAL threshold IS LAND_CFG["GUIDANCE_CORRECTION_THRESHOLD"].
    LOCAL guidanceAlt IS LAND_CFG["GUIDANCE_ALT"].
    LOCAL usedDv IS 0.
    LOCAL lastCheck IS 0.

    mLog("Descent guidance active. Budget=" + ROUND(maxDv,1)
        + "m/s  threshold=" + ROUND(threshold,0) + "m.").

    UNTIL usedDv >= maxDv OR ALT:RADAR <= guidanceAlt OR landingAbortFlag {
        // Check every ~5 seconds
        IF TIME:SECONDS - lastCheck < 5 { WAIT 0.2. }
        ELSE {
            SET lastCheck TO TIME:SECONDS.

            // Also check suicide burn trigger — don't miss it
            LOCAL tti IS _timeToImpact().
            LOCAL sbd IS _suicideBurnDuration().
            IF tti <= sbd * LAND_CFG["BURN_MARGIN"] { BREAK. }

            IF NOT ADDONS:TR:HASIMPACT { WAIT 0.2. }
            ELSE {
                LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
                LOCAL dist IS _geoDistance(impactPos:LAT, impactPos:LNG,
                    targetLat, targetLng).

                HUDTEXT("Guidance: err=" + ROUND(dist,0)
                    + "m  dV=" + ROUND(usedDv,1) + "/" + ROUND(maxDv,0),
                    2, 2, 13, CYAN, FALSE).

                IF dist > threshold {
                    // Compute correction: bearing from impact to target
                    // as a surface-relative direction vector
                    LOCAL impactGeo IS LATLNG(impactPos:LAT, impactPos:LNG).
                    LOCAL targetGeo IS LATLNG(targetLat, targetLng).
                    LOCAL toTarget IS (targetGeo:POSITION - impactGeo:POSITION):NORMALIZED.
                    // Project onto surface plane (remove radial component)
                    LOCAL upVec IS SHIP:UP:VECTOR.
                    LOCAL corrVec IS VXCL(upVec, toTarget):NORMALIZED.

                    // Scale burn: proportional to error, capped at 3 m/s per correction
                    LOCAL burnDv IS MIN(3.0, dist / 500).
                    SET burnDv TO MIN(burnDv, maxDv - usedDv).
                    IF burnDv < 0.2 { WAIT 0.2. }  // too small, skip
                    ELSE {
                        // Orient toward correction vector
                        LOCK STEERING TO corrVec.
                        LOCAL orientEnd IS TIME:SECONDS + 8.
                        UNTIL VANG(SHIP:FACING:FOREVECTOR, corrVec) < 5
                                OR TIME:SECONDS > orientEnd {
                            WAIT 0.1.
                        }

                        // Execute short burn
                        LOCAL burnTime IS burnDv / MAX(0.1, _maxAcc()).
                        LOCAL v0 IS SHIP:VELOCITY:SURFACE:MAG.
                        LOCK THROTTLE TO 0.2.  // gentle — low throttle for precision
                        LOCAL burnEnd IS TIME:SECONDS + burnTime * 5.  // 0.2 throttle = 5x duration
                        UNTIL TIME:SECONDS >= burnEnd OR landingAbortFlag {
                            WAIT 0.05.
                        }
                        LOCK THROTTLE TO 0.
                        LOCAL actualDv IS ABS(SHIP:VELOCITY:SURFACE:MAG - v0).
                        // Estimate from throttle fraction and time
                        SET actualDv TO burnDv.  // approximate — speed change includes gravity
                        SET usedDv TO usedDv + actualDv.

                        mLog("Guidance correction: err=" + ROUND(dist,0)
                            + "m  burn=" + ROUND(burnDv,1) + "m/s"
                            + "  used=" + ROUND(usedDv,1) + "/" + ROUND(maxDv,0) + "m/s.").

                        // Return to retrograde hold and let Trajectories settle
                        LOCK STEERING TO _burnSteering().
                        WAIT 2.
                    }
                }
            }
        }
    }

    mLog("Descent guidance complete. Total dV=" + ROUND(usedDv,1) + "m/s.").
}

// ------------------------------------------------------------
// Terrain survey — one-shot flat spot check near impact point
// ------------------------------------------------------------
// Surveys a grid around the predicted impact and shifts the target
// if a significantly flatter spot is found. Uses raw TERRAINHEIGHT
// queries — independent of SCANsat coverage.

LOCAL FUNCTION _descentTerrainCheck {
    PARAMETER targetLat.
    PARAMETER targetLng.

    // Survey grid: 500m radius, 100m steps → 11x11 = 121 samples
    LOCAL radius IS 500.
    LOCAL step IS 100.
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(targetLat)).

    LOCAL bestLat IS targetLat.
    LOCAL bestLng IS targetLng.
    LOCAL bestScore IS 999999.
    LOCAL centerTerrain IS LATLNG(targetLat, targetLng):TERRAINHEIGHT.

    LOCAL northM IS -radius.
    UNTIL northM > radius {
        LOCAL eastM IS -radius.
        UNTIL eastM > radius {
            LOCAL sLat IS targetLat + northM * degPerM.
            LOCAL sLng IS targetLng + eastM * degPerM / lonScale.
            LOCAL h IS LATLNG(sLat, sLng):TERRAINHEIGHT.

            // Estimate slope from cardinal neighbors (±step)
            LOCAL hN IS LATLNG(sLat + step * degPerM, sLng):TERRAINHEIGHT.
            LOCAL hS IS LATLNG(sLat - step * degPerM, sLng):TERRAINHEIGHT.
            LOCAL hE IS LATLNG(sLat, sLng + step * degPerM / lonScale):TERRAINHEIGHT.
            LOCAL hW IS LATLNG(sLat, sLng - step * degPerM / lonScale):TERRAINHEIGHT.
            LOCAL slopeNS IS ABS(hN - hS) / (2 * step).
            LOCAL slopeEW IS ABS(hE - hW) / (2 * step).
            LOCAL slopePenalty IS (slopeNS + slopeEW) * 500.  // heavily penalize slope

            // Distance from original target penalized lightly
            LOCAL dist IS SQRT(northM^2 + eastM^2).
            LOCAL score IS dist / 100 + slopePenalty.

            IF score < bestScore {
                SET bestScore TO score.
                SET bestLat TO sLat.
                SET bestLng TO sLng.
            }
            SET eastM TO eastM + step.
        }
        SET northM TO northM + step.
    }

    LOCAL shiftDist IS _geoDistance(targetLat, targetLng, bestLat, bestLng).
    mLog("Terrain check: center elev=" + ROUND(centerTerrain,1)
        + "m  best score=" + ROUND(bestScore,1)
        + "  shift=" + ROUND(shiftDist,0) + "m.").

    // Only shift if the improvement is meaningful (>50m away, score much better)
    IF shiftDist > 50 {
        mLog("Shifting target by " + ROUND(shiftDist,0) + "m to flatter terrain"
            + " lat=" + ROUND(bestLat,4) + " lng=" + ROUND(bestLng,4) + ".").
        SET LAND_CFG["TARGET_LAT"] TO bestLat.
        SET LAND_CFG["TARGET_LNG"] TO bestLng.
        IF ADDONS:TR:AVAILABLE {
            ADDONS:TR:SETTARGET(LATLNG(bestLat, bestLng)).
        }
        RETURN LEXICON("LAT", bestLat, "LNG", bestLng, "SHIFTED", TRUE).
    }

    RETURN LEXICON("LAT", targetLat, "LNG", targetLng, "SHIFTED", FALSE).
}

// ------------------------------------------------------------
// Guided hover steering — Phase 4 target-aware descent
// ------------------------------------------------------------
// Adds a horizontal bias toward the target on top of the base
// hover steering logic. Above UPRIGHT_ALT and more than 50m from
// target: lean toward the target proportional to distance, capped
// by MAX_TILT. Close in or low altitude: pure _hoverSteering().

LOCAL FUNCTION _guidedHoverSteering {
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL alt_ IS ALT:RADAR.
    // Close to ground or no target: fall back to pure hover
    IF alt_ <= LAND_CFG["UPRIGHT_ALT"] {
        RETURN SHIP:UP:VECTOR.
    }

    LOCAL targetGeo IS LATLNG(targetLat, targetLng).
    LOCAL dist IS _geoDistance(SHIP:LATITUDE, SHIP:LONGITUDE, targetLat, targetLng).

    // Within 50m or very low: pure hover, prioritize safe touchdown
    IF dist <= 50 {
        RETURN _hoverSteering().
    }

    // Base hover component: kill existing horizontal drift
    LOCAL hv IS _hVel().
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL maxLean IS SIN(LAND_CFG["MAX_TILT"]).

    // Direction toward target projected onto surface plane
    LOCAL toTarget IS VXCL(upVec, targetGeo:POSITION - SHIP:POSITION):NORMALIZED.

    // Blend: cancel drift + bias toward target
    // Drift cancellation (same as _hoverSteering)
    LOCAL driftLean IS V(0,0,0).
    IF hv:MAG > 0.3 {
        SET driftLean TO (-hv):NORMALIZED * MIN(maxLean, hv:MAG / 10).
    }

    // Target bias: proportional to distance, 0.5 lean per 200m, max half of maxLean
    LOCAL targetBias IS toTarget * MIN(maxLean * 0.5, dist / 400).

    LOCAL totalLean IS driftLean + targetBias.
    // Clamp total lean to MAX_TILT
    IF totalLean:MAG > maxLean {
        SET totalLean TO totalLean:NORMALIZED * maxLean.
    }

    RETURN (upVec + totalLean):NORMALIZED.
}

// ------------------------------------------------------------
// Hardware helpers
// ------------------------------------------------------------

LOCAL FUNCTION _deployGear {
    // Landing legs (stock + modded)
    FOR m IN SHIP:MODULESNAMED("ModuleWheelDeployment") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    FOR m IN SHIP:MODULESNAMED("ModuleLandingLeg") {
        IF m:HASEVENT("Extend") { m:DOEVENT("Extend"). }
    }
    GEAR ON.
}

LOCAL FUNCTION _deployAntennas {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableAntenna") {
        IF m:HASEVENT("Extend Antenna") { m:DOEVENT("Extend Antenna"). }
    }
}

LOCAL FUNCTION _deploySolarPanels {
    FOR m IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
        IF m:HASEVENT("Extend Solar Panel") { m:DOEVENT("Extend Solar Panel"). }
    }
}

LOCAL FUNCTION _setReactionWheelAuthority {
    PARAMETER pct.  // 0-100
    FOR m IN SHIP:MODULESNAMED("ModuleReactionWheel") {
        IF m:HASFIELD("Authority Limiter") {
            m:SETFIELD("Authority Limiter", MAX(0, MIN(100, pct))).
        }
    }
}

LOCAL FUNCTION _taggedDecoupler {
    PARAMETER tagName.
    FOR p IN SHIP:PARTS {
        IF p:TAG = tagName {
            IF p:HASMODULE("ModuleDecouple")
                    OR p:HASMODULE("ModuleAnchoredDecoupler") {
                RETURN p.
            }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _decouplePart {
    PARAMETER partRef.
    IF partRef:HASMODULE("ModuleDecouple") {
        partRef:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF partRef:HASMODULE("ModuleAnchoredDecoupler") {
        partRef:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        mLogWarn("Decoupler tag found, but no decouple module. Trying STAGE.").
        STAGE.
    }
}

LOCAL FUNCTION _needsStage {
    LOCAL engs IS LIST().
    LIST ENGINES IN engs.
    FOR eng IN engs { IF eng:FLAMEOUT { RETURN TRUE. } }
    IF SHIP:MAXTHRUST = 0 { RETURN TRUE. }
    RETURN FALSE.
}

// ------------------------------------------------------------
// Main entry point
// ------------------------------------------------------------

GLOBAL FUNCTION landExecute {
    mLogPhase("LANDING").
    SET landingAbortFlag TO FALSE.

    // Log KE availability for telemetry (not gating on it)
    IF ADDONS:KE:AVAILABLE {
        mLog("KerbalEngineer available — will log SB countdown for telemetry.").
    }

    // Resolve landing target
    LOCAL landingTarget IS landingResolveTarget().
    IF landingTarget["FOUND"] {
        mLog("Landing target: " + ROUND(landingTarget["LAT"],4)
            + "," + ROUND(landingTarget["LNG"],4)
            + " from " + landingTarget["SOURCE"] + ".").
        IF ADDONS:TR:AVAILABLE {
            ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
        }
    }

    // Phase 1: Orient retrograde, deploy gear
    SET SAS TO FALSE.
    LOCK STEERING TO _burnSteering().
    _deployGear().
    mLog("Oriented retrograde, gear deployed. Coasting to burn point.").
    HUDTEXT("Coast to burn point", 3, 2, 14, WHITE, FALSE).

    // Phase 2: Coast — descent guidance corrections, then wait for burn trigger
    // Run descent guidance above GUIDANCE_ALT if we have a target
    LOCAL guidanceDone IS FALSE.
    LOCAL terrainCheckDone IS FALSE.
    IF landingTarget["FOUND"] AND ALT:RADAR > LAND_CFG["GUIDANCE_ALT"] {
        _descentGuidance(landingTarget["LAT"], landingTarget["LNG"]).
        SET guidanceDone TO TRUE.
    }

    // One-shot terrain check after guidance finishes (or immediately if no guidance)
    IF landingTarget["FOUND"] AND NOT terrainCheckDone
            AND ALT:RADAR > LAND_CFG["GUIDANCE_ALT"] {
        LOCAL terrainResult IS _descentTerrainCheck(
            LAND_CFG["TARGET_LAT"], LAND_CFG["TARGET_LNG"]).
        SET terrainCheckDone TO TRUE.
        IF terrainResult["SHIFTED"] {
            SET landingTarget["LAT"] TO terrainResult["LAT"].
            SET landingTarget["LNG"] TO terrainResult["LNG"].
        }
    }

    // Coast remainder — wait until TTI <= SBD * BURN_MARGIN
    LOCK STEERING TO _burnSteering().
    UNTIL landingAbortFlag {
        LOCAL tti IS _timeToImpact().
        LOCAL sbd IS _suicideBurnDuration().
        LOCAL margin IS LAND_CFG["BURN_MARGIN"].

        // Log KE telemetry if available
        IF ADDONS:KE:AVAILABLE AND ALT:RADAR < 20000 {
            HUDTEXT("TTI:" + ROUND(tti,1) + " SBD:" + ROUND(sbd,1)
                + " KE:" + ROUND(ADDONS:KE:SUICIDEBURNCOUNTDOWN,1),
                1, 2, 13, WHITE, FALSE).
        } ELSE {
            HUDTEXT("TTI:" + ROUND(tti,1) + " SBD:" + ROUND(sbd,1),
                1, 2, 13, WHITE, FALSE).
        }

        IF tti <= sbd * margin { BREAK. }
        IF _needsStage() { STAGE. WAIT 0.5. }
        WAIT 0.1.
    }
    IF landingAbortFlag { _landCleanup(). RETURN. }

    mLog("Burn start. Alt=" + ROUND(ALT:RADAR,0)
        + "m  spd=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,1) + "m/s.").
    HUDTEXT("SUICIDE BURN", 3, 2, 16, YELLOW, FALSE).

    // Phase 3: Suicide burn — full throttle until altitude OR speed is low
    // enough to transition to controlled hover descent
    LOCK THROTTLE TO 1.0.
    UNTIL ALT:RADAR <= LAND_CFG["HOVER_ALT"]
            OR SHIP:VELOCITY:SURFACE:MAG < 15
            OR landingAbortFlag {
        LOCK STEERING TO _burnSteering().

        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
            LOCK THROTTLE TO 1.0.
        }

        HUDTEXT("Alt:" + ROUND(ALT:RADAR,0) + "m  Spd:"
            + ROUND(SHIP:VELOCITY:SURFACE:MAG,1)
            + "  Vspd:" + ROUND(SHIP:VERTICALSPEED,1) + "m/s",
            1, 2, 13, YELLOW, FALSE).
        WAIT 0.05.
    }
    IF landingAbortFlag { _landCleanup(). RETURN. }

    mLog("Hover descent. Alt=" + ROUND(ALT:RADAR,0)
        + "m  vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s.").

    // Phase 4: Controlled descent to touchdown
    // Target vspeed schedule based on altitude:
    //   > 1000m  ->  -20 m/s   (fast descent)
    //   100-1000 ->  lerp -20 to -8 m/s
    //   10-100   ->  lerp -8 to -3 m/s
    //   < 10m    ->  -TOUCHDOWN_SPEED (final creep)
    LOCAL useGuidedHover IS landingTarget["FOUND"].
    UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" OR landingAbortFlag {
        LOCAL alt_ IS ALT:RADAR.
        LOCAL targetVs IS -_descentSpeed(alt_).

        // Guided hover steers toward target; falls back to pure hover when close/low
        IF useGuidedHover {
            LOCK STEERING TO _guidedHoverSteering(
                LAND_CFG["TARGET_LAT"], LAND_CFG["TARGET_LNG"]).
        } ELSE IF alt_ <= LAND_CFG["UPRIGHT_ALT"] {
            LOCK STEERING TO SHIP:UP.
        } ELSE {
            LOCK STEERING TO _hoverSteering().
        }

        LOCAL acc IS _maxAcc().
        LOCAL g IS _grav().
        IF acc > 0 {
            LOCAL vs IS SHIP:VERTICALSPEED.
            LOCAL err IS targetVs - vs.
            LOCK THROTTLE TO MAX(0, MIN(1.0, (g / acc) + (err * 0.3))).
        }

        IF _needsStage() {
            LOCK THROTTLE TO 0.
            WAIT 0.2.
            STAGE.
            WAIT 0.5.
        }

        HUDTEXT("Alt:" + ROUND(alt_,0) + "m  Vspd:"
            + ROUND(SHIP:VERTICALSPEED,1) + "/" + ROUND(targetVs,1) + "m/s",
            1, 2, 13, GREEN, FALSE).
        WAIT 0.05.
    }
    IF landingAbortFlag { _landCleanup(). RETURN. }

    // Phase 6: Touchdown — max reaction wheels to stay upright
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
    _setReactionWheelAuthority(100).
    mLog("TOUCHDOWN. vspd=" + ROUND(SHIP:VERTICALSPEED,1) + "m/s"
        + "  lat=" + ROUND(SHIP:LATITUDE,4)
        + "  lng=" + ROUND(SHIP:LONGITUDE,4)).
    HUDTEXT("TOUCHDOWN!", 8, 2, 20, GREEN, FALSE).
    stateSet("landing_lat",  SHIP:LATITUDE).
    stateSet("landing_lng",  SHIP:LONGITUDE).
    stateSet("landing_time", TIME:SECONDS).
    _deployAntennas().
    _deploySolarPanels().

    // Phase 7: Carrier handoff (optional)
    IF LAND_CFG["CARRIER_TAG"] <> "" {
        _carrierHandoff().
    }
}

// Backward-compat wrapper — old code calls landingExecute()
GLOBAL FUNCTION landingExecute {
    landExecute().
}

// ------------------------------------------------------------
// Carrier handoff
// ------------------------------------------------------------

LOCAL FUNCTION _carrierHandoff {
    LOCAL decoupler IS _taggedDecoupler(LAND_CFG["CARRIER_TAG"]).
    IF decoupler = 0 {
        mLogWarn("No decoupler tagged '" + LAND_CFG["CARRIER_TAG"]
            + "' — skipping carrier handoff.").
        RETURN.
    }

    // Step 1: Settle on the bell after touchdown
    mLog("Carrier handoff: settling " + ROUND(LAND_CFG["CARRIER_SETTLE"],1) + "s.").
    WAIT LAND_CFG["CARRIER_SETTLE"].
    mLogWarn("STATS carrier settled status=" + SHIP:STATUS
        + " alt=" + ROUND(ALT:RADAR,1)
        + " v=" + ROUND(SHIP:VERTICALSPEED,1)).

    // Step 2: Survey terrain in 8 directions and pick the flattest
    LOCAL tipDir IS _bestTipDirection().
    mLogWarn("STATS tip direction heading=" + ROUND(tipDir,1)).

    // Step 3: Tip gently toward the chosen direction and decouple mid-tip
    IF LAND_CFG["CARRIER_TIP"] {
        mLog("Tipping carrier heading " + ROUND(tipDir,0) + " deg.").
        SET SAS TO FALSE.
        // Build a direction: lean the nose toward the chosen compass heading
        LOCAL tipVec IS HEADING(tipDir, 0):VECTOR.
        LOCK STEERING TO tipVec.

        // Wait for the carrier to start leaning, then decouple while falling
        LOCAL tipEnd IS TIME:SECONDS + LAND_CFG["CARRIER_TIP_TIME"].
        LOCAL decoupled IS FALSE.
        UNTIL TIME:SECONDS >= tipEnd {
            LOCAL tilt IS VANG(SHIP:FACING:FOREVECTOR, SHIP:UP:VECTOR).
            HUDTEXT("Tipping: " + ROUND(tilt,1) + " deg from vertical",
                0.5, 2, 13, YELLOW, FALSE).
            // Decouple once we're leaning past 30 degrees
            IF NOT decoupled AND tilt > 30 {
                mLog("Decoupling rover at tilt=" + ROUND(tilt,1) + " deg.").
                _decouplePart(decoupler).
                SET decoupled TO TRUE.
                WAIT 0.1.
                UNLOCK STEERING.
                // Now control is on the rover — immediately orient flat
                BREAK.
            }
            WAIT 0.05.
        }
        // If we timed out without reaching 30 deg, decouple anyway
        IF NOT decoupled {
            LOCAL tilt IS VANG(SHIP:FACING:FOREVECTOR, SHIP:UP:VECTOR).
            mLog("Tip timeout — decoupling at tilt=" + ROUND(tilt,1) + " deg.").
            _decouplePart(decoupler).
            WAIT 0.1.
            UNLOCK STEERING.
        }
        mLogWarn("STATS carrier tipped and decoupled").
    } ELSE {
        // No tip — just decouple
        mLog("Decoupling rover from carrier.").
        _decouplePart(decoupler).
        WAIT 0.5.
    }

    // Step 4: Rover is now the active vessel — orient wheels-down.
    // LOCK re-evaluates every tick so the target stays stable even
    // while tumbling. We use SHIP:NORTH:VECTOR as a fixed horizontal
    // reference rather than the tumbling FOREVECTOR.
    mLog("Orienting rover wheels-down.").
    SET SAS TO FALSE.
    LOCK STEERING TO LOOKDIRUP(SHIP:NORTH:VECTOR, SHIP:UP:VECTOR).

    // Keep orienting until wheels-down AND on the ground, with a hard timeout
    LOCAL orientEnd IS TIME:SECONDS + LAND_CFG["ROVER_ORIENT_TIME"] + 12.
    UNTIL TIME:SECONDS >= orientEnd {
        LOCAL topErr IS VANG(SHIP:FACING:TOPVECTOR, SHIP:UP:VECTOR).
        LOCAL onGround IS SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED".
        LOCAL onGroundStr IS "".
        IF onGround {
            SET onGroundStr TO " LANDED".
        }
        HUDTEXT("Rover orient: alt=" + ROUND(ALT:RADAR,1)
            + "m  topErr=" + ROUND(topErr,1)
            + "deg" + onGroundStr,
            0.5, 2, 13, CYAN, FALSE).
        // Done when upright and on the ground
        IF onGround AND topErr < 15 { BREAK. }
        WAIT 0.05.
    }
    UNLOCK STEERING.
    mLogWarn("STATS rover oriented topErr="
        + ROUND(VANG(SHIP:FACING:TOPVECTOR, SHIP:UP:VECTOR),1)
        + " alt=" + ROUND(ALT:RADAR,1)
        + " status=" + SHIP:STATUS).

    // Step 6: Engage brakes, lower reaction wheel authority for light rover
    SET BRAKES TO TRUE.
    SET SAS TO TRUE.
    _setReactionWheelAuthority(25).
    mLog("Brakes engaged, reaction wheels at 25%.").

    _deployAntennas().
    _deploySolarPanels().

    mLogWarn("STATS carrier handoff complete status=" + SHIP:STATUS
        + " lat=" + ROUND(SHIP:LATITUDE,4)
        + " lng=" + ROUND(SHIP:LONGITUDE,4)
        + " alt=" + ROUND(ALT:RADAR,1)).
    mLog("Carrier handoff complete. Rover on surface, ready for operations.").
}

// Survey terrain in 8 compass directions at one ship-height distance.
// Returns the compass heading (0-360) of the flattest direction —
// the direction with the smallest absolute terrain height difference
// from the landing site.
LOCAL FUNCTION _bestTipDirection {
    LOCAL hereTerrain IS SHIP:GEOPOSITION:TERRAINHEIGHT.
    LOCAL herePos IS SHIP:GEOPOSITION.
    // Sample distance: approximate ship height (conservative)
    LOCAL sampleDist IS MAX(5, ALT:RADAR + 2).
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(herePos:LAT)).

    LOCAL bestHeading IS 0.
    LOCAL bestDiff IS 999999.

    LOCAL hdg IS 0.
    UNTIL hdg >= 360 {
        LOCAL northM IS COS(hdg) * sampleDist.
        LOCAL eastM IS SIN(hdg) * sampleDist.
        LOCAL sampleLat IS herePos:LAT + northM * degPerM.
        LOCAL sampleLng IS herePos:LNG + eastM * degPerM / lonScale.
        LOCAL sampleTerrain IS LATLNG(sampleLat, sampleLng):TERRAINHEIGHT.
        LOCAL diff IS ABS(sampleTerrain - hereTerrain).

        mLogWarn("STATS terrain hdg=" + ROUND(hdg,0)
            + " elev=" + ROUND(sampleTerrain,1)
            + " diff=" + ROUND(diff,1)).

        IF diff < bestDiff {
            SET bestDiff TO diff.
            SET bestHeading TO hdg.
        }
        SET hdg TO hdg + 45.
    }

    mLog("Best tip direction: heading " + ROUND(bestHeading,0)
        + " deg, terrain diff=" + ROUND(bestDiff,1) + "m.").
    RETURN bestHeading.
}

// Assist stage descent: land the whole stack, then decouple + rover release.
// This replaces the old landingAssistStage() — identical contract.
GLOBAL FUNCTION landingAssistStage {
    mLogPhase("LANDING ASSIST").
    SET landingAbortFlag TO FALSE.

    // Ensure carrier tag is set so landExecute triggers _carrierHandoff
    IF LAND_CFG["CARRIER_TAG"] = "" {
        SET LAND_CFG["CARRIER_TAG"] TO "landing_assist_decoupler".
    }

    // Execute the suicide burn landing (includes carrier handoff at the end)
    landExecute().

    IF NOT (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED") {
        mLogWarn("Not on surface after assist descent.").
        RETURN FALSE.
    }
    RETURN TRUE.
}

// ------------------------------------------------------------
// Cleanup helper
// ------------------------------------------------------------

LOCAL FUNCTION _landCleanup {
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET SAS TO TRUE.
}

// ------------------------------------------------------------
// Target resolution
// ------------------------------------------------------------

GLOBAL FUNCTION landingResolveTarget {
    LOCAL result IS LEXICON().
    result:ADD("FOUND", FALSE).
    result:ADD("LAT", 0).
    result:ADD("LNG", 0).
    result:ADD("SOURCE", "none").

    IF LAND_CFG["TARGET_WAYPOINT"] <> "" {
        LOCAL namedWp IS _waypointNamed(LAND_CFG["TARGET_WAYPOINT"]).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Landing waypoint '" + LAND_CFG["TARGET_WAYPOINT"]
            + "' not found on " + SHIP:BODY:NAME + ".").
    }

    IF LAND_CFG["TARGET_LOCK"]
            AND (LAND_CFG["TARGET_LAT"] <> 0 OR LAND_CFG["TARGET_LNG"] <> 0) {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LAND_CFG["TARGET_LAT"].
        SET result["LNG"] TO LAND_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "locked LAND_CFG".
        RETURN result.
    }

    LOCAL selectedWp IS _selectedWaypoint().
    IF selectedWp <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO selectedWp:GEOPOSITION:LAT.
        SET result["LNG"] TO selectedWp:GEOPOSITION:LNG.
        SET result["SOURCE"] TO "selected waypoint:" + selectedWp:NAME.
        RETURN result.
    }

    IF LAND_CFG["TARGET_LAT"] <> 0 OR LAND_CFG["TARGET_LNG"] <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO LAND_CFG["TARGET_LAT"].
        SET result["LNG"] TO LAND_CFG["TARGET_LNG"].
        SET result["SOURCE"] TO "LAND_CFG".
        RETURN result.
    }

    RETURN result.
}

LOCAL FUNCTION _waypointNamed {
    PARAMETER waypointName.
    LOCAL allWps IS ALLWAYPOINTS().
    LOCAL targetName IS waypointName:TOUPPER.
    FOR wp IN allWps {
        IF wp:BODY:NAME = SHIP:BODY:NAME {
            IF wp:NAME:TOUPPER = targetName { RETURN wp. }
        }
    }
    RETURN 0.
}

LOCAL FUNCTION _selectedWaypoint {
    LOCAL allWps IS ALLWAYPOINTS().
    FOR wp IN allWps {
        IF wp:ISSELECTED {
            IF wp:BODY:NAME = SHIP:BODY:NAME { RETURN wp. }
        }
    }
    RETURN 0.
}

// ------------------------------------------------------------
// Deorbit and impact checking
// ------------------------------------------------------------

GLOBAL FUNCTION landingTargetedDeorbit {
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set — refusing blind landing deorbit.").
        RETURN FALSE.
    }

    mLogWarn("STATS landing target source=" + landingTarget["SOURCE"]
        + " lat=" + ROUND(landingTarget["LAT"],4)
        + " lng=" + ROUND(landingTarget["LNG"],4)).
    SET LAND_CFG["TARGET_LAT"] TO landingTarget["LAT"].
    SET LAND_CFG["TARGET_LNG"] TO landingTarget["LNG"].
    mLog("Landing deorbit target: " + ROUND(landingTarget["LAT"],4)
        + "," + ROUND(landingTarget["LNG"],4)
        + " from " + landingTarget["SOURCE"] + ".").

    LOCAL aimTarget IS _overshootTarget(landingTarget).
    RETURN targetedDeorbitAt(
        aimTarget["LAT"],
        aimTarget["LNG"],
        LAND_CFG["DEORBIT_PE"],
        LAND_CFG["TARGET_TOLERANCE"]).
}

LOCAL FUNCTION _overshootTarget {
    PARAMETER landingTarget.
    LOCAL out IS LEXICON(
        "LAT", landingTarget["LAT"],
        "LNG", landingTarget["LNG"]
    ).
    LOCAL overshoot IS LAND_CFG["DEORBIT_OVERSHOOT"].
    IF overshoot <= 0 { RETURN out. }

    LOCAL hv IS _hVel().
    IF hv:MAG < 0.1 { RETURN out. }
    LOCAL upVec IS SHIP:UP:VECTOR.
    LOCAL northVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE + 0.01, SHIP:LONGITUDE):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL eastVec IS VXCL(upVec,
        LATLNG(SHIP:LATITUDE, SHIP:LONGITUDE + 0.01):POSITION
            - SHIP:GEOPOSITION:POSITION):NORMALIZED.
    LOCAL northM IS VDOT(hv:NORMALIZED, northVec) * overshoot.
    LOCAL eastM IS VDOT(hv:NORMALIZED, eastVec) * overshoot.
    LOCAL shifted IS _offsetLatLng(landingTarget["LAT"], landingTarget["LNG"], northM, eastM).
    SET out["LAT"] TO shifted["LAT"].
    SET out["LNG"] TO shifted["LNG"].
    mLogWarn("STATS deorbit overshoot aim="
        + ROUND(out["LAT"],4) + "," + ROUND(out["LNG"],4)
        + " overshootM=" + ROUND(overshoot,0)).
    RETURN out.
}

LOCAL FUNCTION _offsetLatLng {
    PARAMETER lat.
    PARAMETER lng.
    PARAMETER northM.
    PARAMETER eastM.
    LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
    LOCAL lonScale IS MAX(0.01, COS(lat)).
    RETURN LEXICON(
        "LAT", lat + northM * degPerM,
        "LNG", lng + eastM * degPerM / lonScale
    ).
}

GLOBAL FUNCTION landingImpactWithinTolerance {
    IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" { RETURN TRUE. }

    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] {
        mLogError("No landing target set — refusing impact check.").
        RETURN FALSE.
    }
    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available — cannot verify landing impact.").
        RETURN FALSE.
    }

    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT {
        mLogWarn("STATS landing-impact status=no-impact").
        RETURN FALSE.
    }

    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _geoDistance(
        impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL ok IS dist <= LAND_CFG["TARGET_TOLERANCE"].
    mLogWarn("STATS landing-impact status=" + ok
        + " distKm=" + ROUND(dist/1000,2)
        + " toleranceKm=" + ROUND(LAND_CFG["TARGET_TOLERANCE"]/1000,2)).
    RETURN ok.
}

GLOBAL FUNCTION landingImpactAcceptableForAssist {
    IF LAND_CFG["DEORBIT_OVERSHOOT"] <= 0 { RETURN landingImpactWithinTolerance(). }
    IF NOT ADDONS:TR:AVAILABLE { RETURN FALSE. }
    LOCAL landingTarget IS landingResolveTarget().
    IF NOT landingTarget["FOUND"] { RETURN FALSE. }
    ADDONS:TR:SETTARGET(LATLNG(landingTarget["LAT"], landingTarget["LNG"])).
    WAIT 0.5.
    IF NOT ADDONS:TR:HASIMPACT { RETURN FALSE. }
    LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
    LOCAL dist IS _geoDistance(
        impactPos:LAT, impactPos:LNG,
        landingTarget["LAT"], landingTarget["LNG"]).
    LOCAL maxDist IS LAND_CFG["DEORBIT_OVERSHOOT"]
        + LAND_CFG["DEORBIT_OVERSHOOT_TOLERANCE"].
    LOCAL ok IS dist <= maxDist.
    mLogWarn("STATS landing-impact-assist status=" + ok
        + " distKm=" + ROUND(dist/1000,2)
        + " allowedKm=" + ROUND(maxDist/1000,2)).
    RETURN ok.
}

LOCAL FUNCTION _geoDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL oRad IS SHIP:BODY:RADIUS.
    LOCAL dLat IS lat2 - lat1.
    LOCAL dLng IS lng2 - lng1.
    LOCAL a IS SIN(dLat/2)^2
        + COS(lat1) * COS(lat2) * SIN(dLng/2)^2.
    LOCAL c IS 2 * ARCSIN(MIN(1, SQRT(a))).
    RETURN oRad * c * CONSTANT:PI / 180.
}
