// ============================================================
// landing_light_search.ks — optional orbital Sun/radio ground-track search
// (0:/lib/landing_light_search.ks)
// Runtime regional/node validation remains in landing_light.ks.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL FUNCTION landingLitGroundTrack {
    PARAMETER forecast IS FALSE.
    LOCAL out IS LEXICON("FOUND", FALSE, "LAT", 0, "LNG", 0,
        "UT", 0, "SUN", -90, "KERBIN", -90, "REASON", "no-reachable-window",
        "SCAN_END", 0, "STEP", 0).
    IF SHIP:ORBIT:ECCENTRICITY >= 1 OR SHIP:PERIAPSIS <= 0 { RETURN out. }
    LOCAL period IS SHIP:ORBIT:PERIOD.
    IF NOT (period > 0 AND period < 1e30) { RETURN out. }
    // Site selection precedes the deorbit solver's CPU scope, and operator
    // previews call us directly. Share its capped, reboot-recoverable budget.
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) {
        stateSet("landing_prior_ipu", priorIpu).
        SET CONFIG:IPU TO MIN(2000, LANDING_MIN_IPU).
    }
    LOCAL startUT IS TIME:SECONDS + MAX(600, period * 0.35).
    LOCAL endUT IS startUT + period * MAX(1, MIN(8, LANDING_LIGHT_SCAN_ORBITS)).
    LOCAL stepSec IS period / MAX(64, MIN(512, LANDING_LIGHT_SCAN_SAMPLES)).
    IF forecast {
        // Sparse long-range estimate only. The near-term search must run
        // again after waiting; these samples never authorize a deorbit.
        SET startUT TO endUT.
        LOCAL span IS MAX(8 * period, ABS(SHIP:BODY:ROTATIONPERIOD)).
        IF SHIP:BODY:HASBODY {
            SET span TO MAX(span, 2 * SHIP:BODY:ORBIT:PERIOD).
        }
        SET endUT TO startUT + span.
        SET stepSec TO span / 512.
    }
    LOCAL sampleUT IS startUT.
    LOCAL beganUT IS TIME:SECONDS.
    LOCAL bestScore IS 999999999.
    LOCAL preferredSun IS LANDING_SUN_PREFERRED_ELEV.
    IF LANDING_LIGHT_MODE = "AFTERNOON" { SET preferredSun TO LANDING_AFTERNOON_PREFERRED_ELEV. }
    LOCAL samples IS 0.
    LOCAL eligible IS 0.
    LOCAL windowChecks IS 0.
    mLog("STATS landing-light search-start mode=" + LANDING_LIGHT_MODE
        + " forecast=" + forecast
        + " requireKerbin=" + landingRequireKerbin()
        + " orbits=" + MAX(1, MIN(8, LANDING_LIGHT_SCAN_ORBITS))
        + " samplesPerOrbit=" + MAX(64, MIN(512, LANDING_LIGHT_SCAN_SAMPLES))
        + " startUT=" + startUT + " endUT=" + endUT + " stepSec=" + stepSec
        + " siteRadius=" + landingPlanningRadius() + " ipu=" + CONFIG:IPU).
    UNTIL sampleUT > endUT OR ABORT OR (forecast AND (out["FOUND"] OR samples >= 512)) {
        LOCAL geo IS lmGroundGeoAt(sampleUT).
        LOCAL light IS landingPlanningLight(geo:LAT, geo:LNG, sampleUT).
        IF light["OK"] {
            SET eligible TO eligible + 1.
            LOCAL score IS MAX(0, LANDING_LIGHT_SUN_WEIGHT)
                * ABS(light["SUN"] - light["SUN_REGION_MARGIN"] - preferredSun)
                + 0.1 * (sampleUT - startUT) / period.
            IF landingRequireKerbin() > 0 {
                SET score TO score + MAX(0, LANDING_LIGHT_KERBIN_WEIGHT)
                    * MAX(0, LANDING_KERBIN_PREFERRED_ELEV
                        - (light["KERBIN"] - light["KERBIN_REGION_MARGIN"])).
            }
            IF light["SETTING"] {
                SET score TO score + MAX(0, LANDING_LIGHT_SETTING_PENALTY).
            }
            IF score < bestScore {
                SET windowChecks TO windowChecks + 1.
                SET light TO landingPlanningLight(geo:LAT, geo:LNG, sampleUT, TRUE).
                IF light["OK"] {
                    SET bestScore TO score.
                    SET out TO LEXICON("FOUND", TRUE, "LAT", geo:LAT, "LNG", geo:LNG,
                        "UT", sampleUT, "SUN", light["SUN"], "KERBIN", light["KERBIN"], "REASON", "ok").
                }
            }
        } ELSE IF NOT out["FOUND"] { SET out["REASON"] TO light["REASON"]. }
        SET sampleUT TO sampleUT + stepSec.
        SET samples TO samples + 1.
        IF MOD(samples, 64) = 0 {
            mLog("STATS landing-light search-progress samples=" + samples
                + " elapsed=" + ROUND(TIME:SECONDS - beganUT,1)
                + " eligible=" + eligible + " windows=" + windowChecks
                + " found=" + out["FOUND"] + " lastReason=" + out["REASON"]).
        }
        IF MOD(samples, 8) = 0 { WAIT 0. }
    }
    IF ABORT { SET out["FOUND"] TO FALSE. SET out["REASON"] TO "aborted". }
    SET out["SCAN_END"] TO endUT.
    SET out["STEP"] TO stepSec.
    SET CONFIG:IPU TO priorIpu.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) { stateRemove("landing_prior_ipu"). }
    mLog("STATS landing-light search mode=" + LANDING_LIGHT_MODE + " requireKerbin=" + landingRequireKerbin()
        + " forecast=" + forecast
        + " minKerbin=" + LANDING_KERBIN_MIN_ELEV
        + " preferredKerbin=" + LANDING_KERBIN_PREFERRED_ELEV
        + " siteRadius=" + landingPlanningRadius()
        + " found=" + out["FOUND"] + " lastReason=" + out["REASON"]
        + " samples=" + samples + " elapsed=" + ROUND(TIME:SECONDS - beganUT,1)
        + " eligible=" + eligible + " windows=" + windowChecks
        + " lat=" + out["LAT"] + " lng=" + out["LNG"]
        + " passUT=" + ROUND(out["UT"],1)
        + " sun=" + out["SUN"] + " kerbin=" + out["KERBIN"]).
    RETURN out.
}

