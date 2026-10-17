// Archive-only terrain/reachability snapshot; no flight control or landing.
// RUNPATH("0:/cmd/divertcheck.ks").
// Optional: sample limit (1..81), spacing in metres (20..100).
// Sampling checks a six-game-second deadline between points; loading and
// export take additional time. Use a saved test state or maintain flight
// control separately: this command does not hover or land the craft.
@LAZYGLOBAL OFF.
PARAMETER samples IS 81, spacing IS 50.

LOCAL FUNCTION _cmdDivertcheck {
    IF NOT HOMECONNECTION:ISCONNECTED { PRINT "Archive link required.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("landing_light_math").
    bootLibLoad("vessel_hardware").
    LOCAL profilePath IS "1:/missions/" + stateGet("vehicle", "")
        + "/" + stateGet("mission_id", "") + ".ks".
    IF NOT EXISTS(profilePath) { PRINT "Cached mission profile missing.". RETURN. }
    RUNPATH(profilePath).
    applyMissionOverrides().
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    LOCAL capture IS diagnosticArchiveOpen("divertcheck").
    IF NOT capture["READY"] { RETURN. }
    LOCAL FUNCTION report {
        PARAMETER row.
        RETURN diagnosticArchiveLine(capture, row).
    }

    LOCAL began IS TIME:SECONDS.
    LOCAL centerLat IS SHIP:LATITUDE.
    LOCAL centerLng IS SHIP:LONGITUDE.
    LOCAL altDatum IS SHIP:ALTITUDE.
    LOCAL grav IS localGravity().
    LOCAL acc IS vesselLandingThrust() / MAX(0.01, SHIP:MASS).
    LOCAL reserveAcc IS vesselLandingReserveAcc().
    LOCAL lateralAcc IS lmApproachAcceleration(acc, grav).
    LOCAL hs IS lmHorizontalVelocity():MAG.
    LOCAL stepM IS MAX(20, MIN(100, spacing)).
    LOCAL count IS MAX(1, MIN(81, FLOOR(samples))).
    LOCAL priorIpu IS CONFIG:IPU.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) {
        stateSet("landing_prior_ipu", priorIpu).
        SET CONFIG:IPU TO MIN(2000, LANDING_MIN_IPU).
    }
    report("STATS divert-check schema=1 code=" + codeVersion() + " ut=" + began
        + " vessel=" + SHIP:NAME + " body=" + SHIP:BODY:NAME
        + " phase=" + stateGet("phase", "") + " mission=" + stateGet("mission_id", "")).
    report("STATS divert-check current lat=" + centerLat + " lng=" + centerLng
        + " altitude=" + altDatum + " radar=" + ALT:RADAR
        + " bottom=" + SHIP:BOUNDS:BOTTOMALTRADAR + " hs=" + hs + " vs=" + SHIP:VERTICALSPEED
        + " remainingDv=" + SHIP:DELTAV:VACUUM + " stageDv=" + STAGE:DELTAV:VACUUM).
    report("STATS divert-check physics radius=" + SHIP:BODY:RADIUS + " mu=" + SHIP:BODY:MU
        + " rotationPeriod=" + SHIP:BODY:ROTATIONPERIOD + " angularVel=" + SHIP:BODY:ANGULARVEL
        + " pos=" + (SHIP:POSITION - SHIP:BODY:POSITION)
        + " surfaceVel=" + SHIP:VELOCITY:SURFACE + " orbitalVel=" + SHIP:VELOCITY:ORBIT
        + " mass=" + SHIP:MASS + " acc=" + acc + " reserveAcc=" + reserveAcc
        + " currentStage=" + STAGE:NUMBER + " grav=" + grav + " lateralAcc=" + lateralAcc).
    report("STATS divert-check policy economy=" + LANDING_ECONOMY_BRAKE
        + " flexible=" + LANDING_FLEXIBLE_SITE + " normalSlope=" + LANDING_TERRAIN_MAX_SLOPE
        + " emergencySlope=" + LANDING_DIVERT_EMERGENCY_SLOPE + " tilt=" + MAX_TILT
        + " maxTime=" + LANDING_APPROACH_MAX_TIME + " clearance=" + LANDING_BRAKE_CLEARANCE
        + " light=" + LANDING_LIGHT_MODE + " requireKerbin=" + LANDING_DIVERT_REQUIRE_KERBIN
        + " tolerance=" + LANDING_DIVERT_KERBIN_TOLERANCE
        + " targetLat=" + TARGET_LAT + " targetLng=" + TARGET_LNG).
    LOCAL targetInfo IS landingResolveTarget().
    report("STATS divert-check target found=" + targetInfo["FOUND"] + " source=" + targetInfo["SOURCE"]
        + " lat=" + targetInfo["LAT"] + " lng=" + targetInfo["LNG"]
        + " sunVector=" + (SUN:POSITION - SHIP:POSITION)
        + " kerbinVector=" + (BODY("Kerbin"):POSITION - SHIP:POSITION)).
    IF targetInfo["FOUND"] {
        LOCAL targetElevation IS LATLNG(targetInfo["LAT"], targetInfo["LNG"]):TERRAINHEIGHT.
        report("STATS divert-check target-elevation terrain=" + targetElevation
            + " height=" + (altDatum - targetElevation)
            + " distance=" + geoDistance(centerLat, centerLng, targetInfo["LAT"], targetInfo["LNG"])).
    }
    FOR eng IN SHIP:ENGINES {
        report("STATS divert-check engine name=" + eng:NAME + " stage=" + eng:STAGE
            + " ignition=" + eng:IGNITION + " flameout=" + eng:FLAMEOUT
            + " available=" + eng:AVAILABLETHRUST + " limit=" + eng:THRUSTLIMIT + " isp=" + eng:VISP).
    }
    report("STATS divert-check grid spacing=" + stepM + " requested=" + count
        + " normalGrade=" + TAN(LANDING_TERRAIN_MAX_SLOPE)
        + " emergencyGrade=" + TAN(MIN(15, LANDING_DIVERT_EMERGENCY_SLOPE))).

    LOCAL FUNCTION _divertCheckPoint {
        PARAMETER northM.
        PARAMETER eastM.
        LOCAL degPerM IS 180 / (SHIP:BODY:RADIUS * CONSTANT:PI).
        LOCAL lat IS centerLat + northM * degPerM.
        LOCAL lng IS centerLng + eastM * degPerM / MAX(0.01, COS(centerLat)).
        IF ABS(lat) > 90 { RETURN LEXICON("VALID", FALSE). }
        LOCAL geo IS LATLNG(lat, lng).
        LOCAL delta IS 20 * degPerM.
        LOCAL lonDelta IS delta / MAX(0.01, COS(lat)).
        LOCAL hN IS LATLNG(lat + delta, lng):TERRAINHEIGHT.
        LOCAL hS IS LATLNG(lat - delta, lng):TERRAINHEIGHT.
        LOCAL hE IS LATLNG(lat, lng + lonDelta):TERRAINHEIGHT.
        LOCAL hW IS LATLNG(lat, lng - lonDelta):TERRAINHEIGHT.
        LOCAL independent IS SQRT(((hN - hS) / 40) ^ 2 + ((hE - hW) / 40) ^ 2).
        LOCAL grade IS landingTerrainGrade(lat, lng, 20).
        LOCAL distance IS geoDistance(centerLat, centerLng, lat, lng).
        LOCAL transit IS 2 * SQRT(MAX(0, distance) / MAX(0.01, lateralAcc))
            + hs / MAX(0.01, lateralAcc).
        RETURN LEXICON("VALID", TRUE, "LAT", lat, "LNG", lng, "ELEVATION", geo:TERRAINHEIGHT,
            "N", hN, "S", hS, "E", hE, "W", hW, "GRADE", grade, "INDEPENDENT", independent,
            "SLOPE", ARCTAN2(grade,1), "DIST", distance, "TRANSIT", transit,
            "CLEARANCE", altDatum - geo:TERRAINHEIGHT).
    }
    // Center first, then nearest square rings, respecting the six-second
    // sampling deadline even if archive I/O consumed most of the budget.
    LOCAL index IS 0.
    LOCAL recorded IS 0.
    UNTIL recorded >= count OR index > 80 OR TIME:SECONDS - began >= 6
            OR NOT capture["COMPLETE"] OR ABORT {
        LOCAL ring IS 0.
        UNTIL index < (2 * ring + 1) ^ 2 { SET ring TO ring + 1. }
        LOCAL northM IS 0.
        LOCAL eastM IS 0.
        IF ring > 0 {
            LOCAL side IS index - (2 * ring - 1) ^ 2.
            IF side < 2 * ring { SET northM TO -ring. SET eastM TO -ring + side. }
            ELSE IF side < 4 * ring { SET northM TO -ring + side - 2 * ring. SET eastM TO ring. }
            ELSE IF side < 6 * ring { SET northM TO ring. SET eastM TO ring - (side - 4 * ring). }
            ELSE { SET northM TO ring - (side - 6 * ring). SET eastM TO -ring. }
        }
        LOCAL point IS _divertCheckPoint(northM * stepM, eastM * stepM).
        IF point["VALID"] {
            report("STATS divert-check point north=" + northM * stepM + " east=" + eastM * stepM
                + " lat=" + point["LAT"] + " lng=" + point["LNG"] + " elevation=" + point["ELEVATION"]
                + " hN=" + point["N"] + " hS=" + point["S"] + " hE=" + point["E"] + " hW=" + point["W"]
                + " grade=" + point["GRADE"] + " independent=" + point["INDEPENDENT"] + " slope=" + point["SLOPE"]
                + " distance=" + point["DIST"] + " transit=" + point["TRANSIT"]
                + " clearance=" + point["CLEARANCE"]).
            SET recorded TO recorded + 1.
        }
        SET index TO index + 1.
        WAIT 0.
    }
    SET CONFIG:IPU TO priorIpu.
    IF priorIpu < MIN(2000, LANDING_MIN_IPU) { stateRemove("landing_prior_ipu"). }
    report("STATS divert-check sampled=" + recorded + " requested=" + count
        + " elapsed=" + (TIME:SECONDS - began) + " ipuRestored=" + CONFIG:IPU).
    IF HOMECONNECTION:ISCONNECTED AND EXISTS(flightLogPath()) {
        LOCAL sidecar IS capture["PATH"] + ".boot.log".
        IF NOT EXISTS(sidecar) { COPYPATH(flightLogPath(), sidecar). }
        report("STATS divert-check flightLog=" + sidecar).
    }
    diagnosticArchiveClose(capture, "STATS divert-check").
}

_cmdDivertcheck().
