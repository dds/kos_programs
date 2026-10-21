// cmd/landingcheck.ks - Print and archive landing readiness from the active vessel.
// Usage: RUNPATH("0:/cmd/landingcheck.ks").

LOCAL FUNCTION _cmdLandingcheck {
    IF NOT HOMECONNECTION:ISCONNECTED {
        PRINT "Landing capture requires an archive link. Re-run when connected; no report recorded.".
        RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("vessel_hardware").
    vesselLandingPrepareRoles().
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    LOCAL reportState IS diagnosticArchiveOpen("landingcheck").
    IF NOT reportState["READY"] { RETURN. }
    LOCAL FUNCTION report {
        PARAMETER row.
        RETURN diagnosticArchiveLine(reportState, row).
    }

    LOCAL radiusMag IS SHIP:BODY:RADIUS + SHIP:ALTITUDE.
    LOCAL grav IS SHIP:BODY:MU / (radiusMag * radiusMag).
    LOCAL surfaceGrav IS SHIP:BODY:MU / (SHIP:BODY:RADIUS ^ 2).
    LOCAL maxAcc IS 0.
    IF SHIP:MASS > 0 {
        SET maxAcc TO SHIP:AVAILABLETHRUST / SHIP:MASS.
    }

    report("STATS landing-check schema=1 code=" + codeVersion() + " ut=" + TIME:SECONDS
        + " phase=" + stateGet("phase", "") + " mission=" + stateGet("mission_id", "")).
    report("LANDING CHECK").
    report(stateGet("last_landing_brake", "No saved landing brake decision (older code or no ignition yet).")).
    report("  Vessel   " + SHIP:NAME).
    report("  Body     " + SHIP:BODY:NAME + "  status=" + SHIP:STATUS).
    report("  Orbit    Pe=" + ROUND(SHIP:PERIAPSIS/1000,2)
        + " Ap=" + ROUND(SHIP:APOAPSIS/1000,2)
        + " inc=" + ROUND(SHIP:ORBIT:INCLINATION,2)).
    report("  Surface  radar=" + ROUND(ALT:RADAR,1)
        + " h=" + ROUND(SHIP:VELOCITY:SURFACE:MAG,2)
        + " v=" + ROUND(SHIP:VERTICALSPEED,2)).
    report("  Thrust   mass=" + ROUND(SHIP:MASS,3)
        + "t avail=" + ROUND(SHIP:AVAILABLETHRUST,2)
        + "kN TWR here=" + ROUND(maxAcc / grav,2)
        + " surface=" + ROUND(maxAcc / surfaceGrav,2)).
    report("  Fuel     remaining vacuum dV=" + ROUND(SHIP:DELTAV:VACUUM,1)
        + "m/s current stage=" + ROUND(STAGE:DELTAV:VACUUM,1) + "m/s").
    report("  Staging  current=" + STAGE:NUMBER
        + " landingFloor=" + vesselLandingStageFloor()
        + " roleReason=" + landingRolePolicy["REASON"]
        + " next engine=" + vesselLandingNextEngineStage()
        + " next-stage surface TWR=" + ROUND(vesselLandingReserveAcc() / surfaceGrav,2)).
    report("  Guidance activeAcc=" + (vesselLandingThrust() / MAX(0.01, SHIP:MASS))
        + " reserveAcc=" + vesselLandingReserveAcc() + "m/s2").
    report("  Attitude pitch=" + ROUND(SHIP:FACING:PITCH,1)
        + " roll=" + ROUND(SHIP:FACING:ROLL,1)).

    LOCAL selected IS 0.
    FOR wp IN ALLWAYPOINTS() {
        IF wp:ISSELECTED {
            IF wp:BODY:NAME = SHIP:BODY:NAME {
                SET selected TO wp.
                BREAK.
            }
        }
    }
    IF selected <> 0 {
        LOCAL reachInc IS SHIP:ORBIT:INCLINATION.
        IF reachInc > 90 { SET reachInc TO 180 - reachInc. }
        report("  Target   selected waypoint: " + selected:NAME).
        report("           lat=" + ROUND(selected:GEOPOSITION:LAT,4)
            + " lng=" + ROUND(selected:GEOPOSITION:LNG,4)).
        report("           reachableLat=" + (ABS(selected:GEOPOSITION:LAT) <= reachInc + 0.5)
            + " orbitLatLimit=" + ROUND(reachInc,2)).
    } ELSE {
        report("  Target   no selected waypoint on " + SHIP:BODY:NAME + ".").
    }

    LOCAL assistTag IS "landing_assist_decoupler".
    LOCAL decouplers IS SHIP:PARTSTAGGED(assistTag).
    report("  Assist   decouplers tagged " + assistTag + "=" + decouplers:LENGTH).
    report("           Landing uses KSP staging order; this legacy tag does not trigger separation.").
    report("  Addons   TR=" + ADDONS:TR:AVAILABLE
        + " KE=" + ADDONS:KE:AVAILABLE
        + " SCANsat=" + ADDONS:AVAILABLE("SCANSAT")).
    FOR eng IN SHIP:ENGINES {
        report("  Engine   " + eng:NAME + " stage=" + eng:STAGE + " decoupledIn=" + eng:DECOUPLEDIN
            + " ignition=" + eng:IGNITION + " flameout=" + eng:FLAMEOUT
            + " limit=" + ROUND(eng:THRUSTLIMIT,1)
            + " available=" + ROUND(eng:AVAILABLETHRUST,2)
            + " possible=" + ROUND(eng:POSSIBLETHRUST,2)
            + " vacuumIsp=" + eng:VISP + " throttleLock=" + eng:THROTTLELOCK).
    }

    IF HASNODE {
        report("  Node     dV=" + ROUND(NEXTNODE:DELTAV:MAG,2)
            + " ETA=" + ROUND(NEXTNODE:ETA,1)).
    } ELSE {
        report("  Node     none").
    }
    diagnosticArchiveClose(reportState, "STATS landing-check").
}

_cmdLandingcheck().
