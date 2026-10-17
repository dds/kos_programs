// Read-only snapshot. Keep the suspect node attached; run in manual mode.
// RUNPATH("0:/cmd/deorbitcheck.ks").
@LAZYGLOBAL OFF.
PARAMETER samples IS 3.

LOCAL FUNCTION _cmdDeorbitcheck {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("landing_deorbit").
    bootLibLoad("deorbit_targeting").
    LOCAL profilePath IS "1:/missions/" + stateGet("vehicle", "")
        + "/" + stateGet("mission_id", "") + ".ks".
    IF NOT EXISTS(profilePath) {
        PRINT "Cached mission profile missing; cannot report the active landing policy.".
        RETURN.
    }
    RUNPATH(profilePath).
    applyMissionOverrides().

    LOCAL reportDir IS "1:/run".
    IF HOMECONNECTION:ISCONNECTED { SET reportDir TO "0:/logs". }
    IF NOT EXISTS(reportDir) { CREATEDIR(reportDir). }
    LOCAL reportPath IS reportDir + "/deorbitcheck_" + slug() + "_"
        + ROUND(TIME:SECONDS,0) + ".log".
    LOCAL FUNCTION report {
        PARAMETER row.
        PRINT row.
        IF reportPath:STARTSWITH("0:") AND NOT HOMECONNECTION:ISCONNECTED {
            SET reportPath TO "1:/run/deorbitcheck.log".
        }
        IF reportPath:STARTSWITH("0:")
                OR CORE:VOLUME:FREESPACE > MAX(150, LOG_FILE_RESERVE_BYTES) + row:LENGTH + 100 {
            LOG row TO reportPath.
        } ELSE { PRINT "Storage reserve reached; this row is console-only.". }
    }
    LOCAL FUNCTION lightRow {
        PARAMETER label.
        PARAMETER lat.
        PARAMETER lng.
        PARAMETER ut.
        LOCAL light IS landingLightAt(lat, lng, ut).
        report("STATS deorbit-check light point=" + label + " ut=" + ut
            + " lat=" + lat + " lng=" + lng + " ok=" + light["OK"]
            + " reason=" + light["REASON"] + " sun=" + light["SUN"]
            + " kerbin=" + light["KERBIN"]).
    }
    LOCAL FUNCTION _deorbitCheckGeometry {
        PARAMETER impactGeo.
        PARAMETER impactUT.
        LOCAL world IS SHIP:BODY.
        LOCAL inertialPos IS POSITIONAT(SHIP, impactUT) - world:POSITION.
        LOCAL groundGeo IS lmGroundGeoAt(impactUT).
        LOCAL groundVel IS lmGroundVelocityAt(impactUT).
        // Independent transform matching Trajectories' quaternion code.
        LOCAL rotatedPos IS inertialPos.
        IF world:ANGULARVEL:MAG > 0.00000001 {
            SET rotatedPos TO ANGLEAXIS(-(impactUT - TIME:SECONDS)
                * world:ANGULARVEL:MAG * 180 / CONSTANT:PI, world:ANGULARVEL) * inertialPos.
        }
        LOCAL rotatedGeo IS world:GEOPOSITIONOF(rotatedPos + world:POSITION).
        LOCAL impactUp IS impactGeo:ALTITUDEPOSITION(0) - world:POSITION.
        LOCAL nativeUp IS groundGeo:ALTITUDEPOSITION(0) - world:POSITION.
        LOCAL rotateUp IS rotatedGeo:ALTITUDEPOSITION(0) - world:POSITION.
        RETURN LEXICON("GEO", groundGeo, "QUATERNION", rotatedGeo,
            "POSITION", inertialPos, "VELOCITY", groundVel,
            "TR_NATIVE_GAP", VANG(impactUp, nativeUp) * world:RADIUS * CONSTANT:PI / 180,
            "TR_QUATERNION_GAP", VANG(impactUp, rotateUp) * world:RADIUS * CONSTANT:PI / 180).
    }

    report("STATS deorbit-check schema=1 code=" + codeVersion() + " ut=" + TIME:SECONDS
        + " vessel=" + SHIP:NAME + " phase=" + stateGet("phase", "")
        + " mission=" + stateGet("mission_id", "") + " profile=" + profilePath
        + " burnStarted=" + stateGet("deorbit_burn_started", "false")).
    report("STATS deorbit-check controls thrust=" + SHIP:THRUST
        + " throttle=" + SHIP:CONTROL:MAINTHROTTLE
        + " pilot=" + SHIP:CONTROL:PILOTMAINTHROTTLE + " abort=" + ABORT
        + " warp=" + WARP + " ipu=" + CONFIG:IPU).
    LOCAL bdy IS SHIP:BODY.
    report("STATS deorbit-check body name=" + bdy:NAME + " radius=" + bdy:RADIUS
        + " mu=" + bdy:MU + " period=" + bdy:ROTATIONPERIOD
        + " angularVel=" + bdy:ANGULARVEL + " pos=" + bdy:POSITION).
    report("STATS deorbit-check orbit status=" + SHIP:STATUS + " pe=" + SHIP:PERIAPSIS
        + " ap=" + SHIP:APOAPSIS + " inc=" + SHIP:ORBIT:INCLINATION
        + " lan=" + SHIP:ORBIT:LAN + " aop=" + SHIP:ORBIT:ARGUMENTOFPERIAPSIS
        + " ecc=" + SHIP:ORBIT:ECCENTRICITY + " period=" + SHIP:ORBIT:PERIOD
        + " sma=" + SHIP:ORBIT:SEMIMAJORAXIS + " trueAnomaly=" + SHIP:ORBIT:TRUEANOMALY).
    report("STATS deorbit-check current lat=" + SHIP:GEOPOSITION:LAT
        + " lng=" + SHIP:GEOPOSITION:LNG + " alt=" + SHIP:ALTITUDE
        + " relativePos=" + (SHIP:POSITION - bdy:POSITION)
        + " orbitalVel=" + SHIP:VELOCITY:ORBIT + " surfaceVel=" + SHIP:VELOCITY:SURFACE
        + " remainingDv=" + SHIP:DELTAV:VACUUM).
    report("STATS deorbit-check policy flexible=" + LANDING_FLEXIBLE_SITE
        + " auto=" + LANDING_AUTO_TARGET + " light=" + LANDING_LIGHT_MODE
        + " minSun=" + LANDING_SUN_MIN_ELEV + " requireKerbin=" + LANDING_REQUIRE_KERBIN
        + " minKerbin=" + LANDING_KERBIN_MIN_ELEV + " preferredKerbin=" + LANDING_KERBIN_PREFERRED_ELEV
        + " normalCap=" + TARGET_DEORBIT_NORMAL_DV_CAP
        + " crossCapKm=" + DEORBIT_CROSSTRACK_AUTHORITY_KM
        + " maxTrials=" + TARGET_DEORBIT_MAX_EVALUATIONS
        + " requireSite=" + LANDING_REQUIRE_SITE + " scan=" + LANDING_SITE_SCAN_ENABLE).
    LOCAL targetInfo IS landingResolveTarget().
    report("STATS deorbit-check target found=" + targetInfo["FOUND"]
        + " source=" + targetInfo["SOURCE"] + " locked=" + TARGET_LOCK
        + " configuredLat=" + TARGET_LAT + " configuredLng=" + TARGET_LNG).
    IF targetInfo["FOUND"] {
        lightRow("target-now", targetInfo["LAT"], targetInfo["LNG"], TIME:SECONDS).
        report("STATS deorbit-check target terrain="
            + LATLNG(targetInfo["LAT"], targetInfo["LNG"]):TERRAINHEIGHT
            + " liveKerbin=" + landingKerbinElevationNow(targetInfo["LAT"], targetInfo["LNG"])).
    }
    report("STATS deorbit-check addons tr=" + ADDONS:TR:AVAILABLE
        + " scansat=" + ADDONS:AVAILABLE("SCANSAT")).
    IF ADDONS:TR:AVAILABLE { report("STATS deorbit-check trVersion=" + ADDONS:TR:GETVERSION). }
    IF HASNODE {
        LOCAL nd IS NEXTNODE.
        report("STATS deorbit-check node ut=" + nd:TIME + " eta=" + nd:ETA
            + " prograde=" + nd:PROGRADE + " normal=" + nd:NORMAL + " radial=" + nd:RADIALOUT
            + " dv=" + nd:DELTAV:MAG + " pe=" + nd:ORBIT:PERIAPSIS
            + " ap=" + nd:ORBIT:APOAPSIS + " inc=" + nd:ORBIT:INCLINATION
            + " lan=" + nd:ORBIT:LAN + " aop=" + nd:ORBIT:ARGUMENTOFPERIAPSIS).
    } ELSE { report("STATS deorbit-check node=none"). }

    LOCAL index IS 0.
    UNTIL index >= MAX(1, MIN(5, samples)) {
        IF index > 0 { WAIT 1. }
        SET index TO index + 1.
        IF NOT ADDONS:TR:AVAILABLE { BREAK. }
        IF NOT ADDONS:TR:ISVERTWOTWO { BREAK. }
        IF NOT ADDONS:TR:HASIMPACT {
            report("STATS deorbit-check sample=" + index + " ut=" + TIME:SECONDS + " hasImpact=false").
        } ELSE {
            LOCAL impactGeo IS ADDONS:TR:IMPACTPOS.
            LOCAL impactUT IS TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT.
            LOCAL patch IS ORBITAT(SHIP, impactUT).
            report("STATS deorbit-check sample=" + index + " ut=" + TIME:SECONDS
                + " impactUT=" + impactUT + " impactLat=" + impactGeo:LAT
                + " impactLng=" + impactGeo:LNG + " nativeBody=" + patch:BODY:NAME
                + " nativePe=" + patch:PERIAPSIS).
            IF patch:BODY:NAME = bdy:NAME {
                LOCAL geometry IS _deorbitCheckGeometry(impactGeo, impactUT).
                LOCAL groundGeo IS geometry["GEO"].
                LOCAL groundVel IS geometry["VELOCITY"].
                LOCAL rotatedGeo IS geometry["QUATERNION"].
                report("STATS deorbit-check native lat=" + groundGeo:LAT + " lng=" + groundGeo:LNG
                    + " quaternionLat=" + rotatedGeo:LAT + " quaternionLng=" + rotatedGeo:LNG
                    + " trNativeGapM=" + geometry["TR_NATIVE_GAP"]
                    + " trQuaternionGapM=" + geometry["TR_QUATERNION_GAP"]
                    + " radius=" + geometry["POSITION"]:MAG + " terrain=" + groundGeo:TERRAINHEIGHT
                    + " relativePos=" + geometry["POSITION"] + " groundVel=" + groundVel).
                IF targetInfo["FOUND"] {
                    LOCAL offset IS lmSurfaceTrackOffset(targetInfo["LAT"], targetInfo["LNG"],
                        impactGeo:LAT, impactGeo:LNG, groundVel).
                    LOCAL nativeOffset IS lmSurfaceTrackOffset(targetInfo["LAT"], targetInfo["LNG"],
                        groundGeo:LAT, groundGeo:LNG, groundVel).
                    report("STATS deorbit-check corridor valid=" + offset["VALID"]
                        + " trDownfieldM=" + offset["DOWNFIELD"] + " trCrossM=" + offset["CROSS"]
                        + " nativeDownfieldM=" + nativeOffset["DOWNFIELD"]
                        + " nativeCrossM=" + nativeOffset["CROSS"]).
                    lightRow("target-at-impact", targetInfo["LAT"], targetInfo["LNG"], impactUT).
                }
                lightRow("tr-impact", impactGeo:LAT, impactGeo:LNG, impactUT).
                lightRow("native-impact", groundGeo:LAT, groundGeo:LNG, impactUT).
            }
        }
    }
    report("STATS deorbit-check complete ut=" + TIME:SECONDS + " file=" + reportPath).
    PRINT "Snapshot saved to " + reportPath + ". Node, phase and flight controls preserved.".
}

_cmdDeorbitcheck().
