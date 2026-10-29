// ============================================================
// deorbit_targeting.ks  —  Precision deorbit targeting  (0:/lib/deorbit_targeting.ks)
// ============================================================

@CLOBBERBUILTINS ON.

// --- Config defaults owned by this file ---
GLOBAL PROBE_TARGET_WAYPOINT IS "".
GLOBAL PROBE_TARGET_LAT IS 90.
GLOBAL PROBE_TARGET_LNG IS 0.
GLOBAL TARGET_DEORBIT_SCAN_ORBITS IS 0.
GLOBAL TARGET_DEORBIT_SCAN_SAMPLES IS 128.
GLOBAL TARGET_DEORBIT_SCAN_CENTER_MINUTES IS 0.
GLOBAL TARGET_DEORBIT_SCAN_WINDOW_MINUTES IS 0.
GLOBAL TARGET_TOLERANCE IS 5000.
GLOBAL TARGET_DEORBIT_MIN_LEAD IS 0.
GLOBAL TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM IS 0.
GLOBAL LANDING_SIM_MODE IS 0.
GLOBAL DEORBIT_CROSSTRACK_AUTHORITY_KM IS 0.
GLOBAL DEORBIT_MIN_FPA IS 0.
// Opt-in small lateral correction combined with the retrograde burn.
GLOBAL TARGET_DEORBIT_NORMAL_DV_CAP IS 0.
GLOBAL TARGET_DEORBIT_MAX_EVALUATIONS IS 64.
// Fixed sites may need to rotate back under the orbit after a missed pass.
// Zero retains the consecutive-window search. Survey geometry, not TR nodes.
GLOBAL TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS IS 0.
LOCAL _deorbitEvaluations IS 0.
LOCAL _deorbitLastCheck IS LEXICON("VALID",FALSE).

GLOBAL FUNCTION targetedDeorbit {
    LOCAL targetInfo IS targetResolveDeorbitTarget().
    IF NOT targetInfo["FOUND"] {
        mLogError("No deorbit target set. Configure PROBE_TARGET_LAT/LNG or select a waypoint.").
        RETURN FALSE.
    }

    mLog("Deorbit target source: " + targetInfo["SOURCE"] + ".").
    RETURN targetedDeorbitAt(targetInfo["LAT"], targetInfo["LNG"]).
}

GLOBAL FUNCTION targetResolveDeorbitTarget {
    LOCAL result IS LEXICON(
        "FOUND", FALSE,
        "LAT", 0,
        "LNG", 0,
        "SOURCE", "none"
    ).

    IF PROBE_TARGET_WAYPOINT <> "" {
        LOCAL namedWp IS waypointNamed(PROBE_TARGET_WAYPOINT).
        IF namedWp <> 0 {
            SET result["FOUND"] TO TRUE.
            SET result["LAT"] TO namedWp:GEOPOSITION:LAT.
            SET result["LNG"] TO namedWp:GEOPOSITION:LNG.
            SET result["SOURCE"] TO "waypoint:" + namedWp:NAME.
            RETURN result.
        }
        mLogWarn("Probe waypoint '" + PROBE_TARGET_WAYPOINT
            + "' not found on " + SHIP:BODY:NAME + ".").
    }

    LOCAL selectedWp IS selectedWaypoint().
    IF selectedWp <> 0 {
        SET result["FOUND"] TO TRUE.
        SET result["LAT"] TO selectedWp:GEOPOSITION:LAT.
        SET result["LNG"] TO selectedWp:GEOPOSITION:LNG.
        SET result["SOURCE"] TO "selected waypoint:" + selectedWp:NAME.
        RETURN result.
    }

    SET result["FOUND"] TO TRUE.
    SET result["LAT"] TO PROBE_TARGET_LAT.
    SET result["LNG"] TO PROBE_TARGET_LNG.
    SET result["SOURCE"] TO "PROBE_TARGET_LAT/LNG".
    RETURN result.
}

GLOBAL FUNCTION targetedDeorbitAt {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER overrideTolerance IS 0.
    PARAMETER overrideOvershoot IS 0.
    PARAMETER refineSite IS TRUE.
    PARAMETER targetPassUT IS 0.

    IF NOT ADDONS:TR:AVAILABLE {
        mLogError("Trajectories not available; targeted landing deorbit requires TR.").
        RETURN FALSE.
    }
    IF NOT ADDONS:TR:ISVERTWOTWO {
        mLogError("Targeted deorbit requires Trajectories 2.2+ impact timing.").
        RETURN FALSE.
    }

    IF NOT vesselLandingPrepareRoles() { RETURN FALSE. }
    IF NOT targetReachable(targetLat) {
        mLogError("Target latitude is not reachable from this orbit inclination.").
        RETURN FALSE.
    }
    SET _deorbitEvaluations TO 0.

    LOCAL site IS LEXICON("FOUND", FALSE).
    IF refineSite AND DEFINED BOOT_LIB_RAN AND BOOT_LIB_RAN:CONTAINS("landing_site") {
        SET site TO selectScanSatLandingSite(targetLat, targetLng).
    }
    IF site["FOUND"] {
        SET targetLat TO site["LAT"].
        SET targetLng TO site["LNG"].
    }

    LOCAL targetGeo IS LATLNG(targetLat, targetLng).
    LOCAL tolerance IS TARGET_TOLERANCE.
    IF overrideTolerance > 0 { SET tolerance TO overrideTolerance. }
    LOCAL seedPolicy IS landingDeorbitLegacyLead(overrideOvershoot).
    LOCAL desiredDownfield IS seedPolicy["AIM"].
    LOCAL minDownfield IS seedPolicy["MIN"].
    LOCAL maxDownfield IS seedPolicy["MAX"].
    LOCAL minRetroDv IS 2.
    LOCAL seedRetroDv IS 15.
    LOCAL maxRetroDv IS 120.
    ADDONS:TR:SETTARGET(targetGeo).

    mLog("Targeted deorbit: target=" + ROUND(targetLat,4) + ","
        + ROUND(targetLng,4)
        + "  nodeAngles=50,35,65,20,80deg"
        + "  downfield=" + ROUND(desiredDownfield/1000,1) + "km"
        + " band=" + ROUND(minDownfield/1000,1)
        + "-" + ROUND(maxDownfield/1000,1) + "km.").
    HUDTEXT("Solving geometric deorbit...", 3, 2, 13, CYAN, FALSE).
    mLog("STATS deorbit policy normalCap=" + TARGET_DEORBIT_NORMAL_DV_CAP
        + " preferredCrossKm=" + TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM
        + " crossCapKm=" + DEORBIT_CROSSTRACK_AUTHORITY_KM
        + " maxTrials=" + TARGET_DEORBIT_MAX_EVALUATIONS + " ipu=" + CONFIG:IPU
        + " targetPassUT=" + ROUND(targetPassUT,1)).

    LOCAL nowUt IS TIME:SECONDS.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL minLead IS _targetDeorbitMinLead().
    // Trial predictions each wait 0.5s; reserve their bounded planning time
    // before choosing an otherwise imminent node.
    LOCAL planningMargin IS MAX(5, TARGET_DEORBIT_MAX_EVALUATIONS * 0.5 + 5).
    LOCAL scanOrbits IS 4.
    IF TARGET_DEORBIT_SCAN_ORBITS > 0 {
        SET scanOrbits TO TARGET_DEORBIT_SCAN_ORBITS.
    }
    IF LANDING_SIM_MODE > 0 {
        IF scanOrbits > 2 { SET scanOrbits TO 2. }
    }

    LOCAL stepA IS period / MAX(128, TARGET_DEORBIT_SCAN_SAMPLES).
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL rankedPasses IS LIST().
    IF targetPassUT <= 0 AND TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS > 0 {
        IF SHIP:STATUS <> "ORBITING" OR SHIP:ORBIT:HASNEXTPATCH
                OR NOT (SHIP:PERIAPSIS > 0 AND SHIP:ORBIT:ECCENTRICITY < 1
                    AND period > 0 AND period < 1e30) {
            mLogError("STATS deorbit result=hold reason=fixed-pass-survey-needs-bound-orbit").
            RETURN FALSE.
        }
        SET rankedPasses TO _targetDeorbitFixedPasses(targetLat,targetLng,
            TIME:SECONDS+minLead+planningMargin+period*80/360,period,scanOrbits).
        IF ABORT { RETURN FALSE. }
        IF rankedPasses:LENGTH = 0 {
            mLogError("STATS deorbit result=hold reason=no-fixed-site-pass-found").
            RETURN FALSE.
        }
    }
    LOCAL searchWindows IS scanOrbits.
    IF rankedPasses:LENGTH > 0 { SET searchWindows TO rankedPasses:LENGTH. }
    LOCAL geometry IS LEXICON(
        "VALID", FALSE,
        "UT", nowUt + minLead,
        "ANGLE", 999999999,
        "ERR", 999999999,
        "LAT", 0,
        "LNG", 0
    ).
    LOCAL solved IS LEXICON(
        "VALID", FALSE,
        "DV", seedRetroDv,
        "DIST", 999999999,
        "DOWNFIELD", -999999999,
        "ERR", 999999999,
        "PE", 999999999,
        "ANGLE", -1,
        "HAS_IMPACT", FALSE,
        "LAT", 0,
        "LNG", 0,
        "TTI", 0
    ).
    LOCAL foundGeometry IS FALSE.
    LOCAL acceptedSolution IS FALSE.
    LOCAL bestAccepted IS LEXICON("VALID", FALSE).
    LOCAL bestAcceptedGeometry IS LEXICON("VALID", FALSE).
    LOCAL bestAcceptedCross IS 999999999.
    LOCAL preferredCrossTrack IS 0.
    IF TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM > 0 {
        SET preferredCrossTrack TO TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM * 1000.
    }
    LOCAL orbitScan IS 0.
    LOCAL candidatesTried IS 0.
    LOCAL windowsTried IS 0.
    LOCAL closestRejected IS LEXICON("VALID", FALSE).
    LOCAL closestMerit IS 1e30.
    LOCAL closestWindow IS 0.
    LOCAL closestNodeAngle IS 0.
    LOCAL closestLight IS "not-checked".

    // Spread the first burn angle across passes before spending trials on
    // alternate angles of the same pass. Every candidate keeps the global
    // evaluation limit and the same physical acceptance gates.
    FOR candidateAngle IN LIST(50, 35, 65, 20, 80) {
        SET orbitScan TO 0.
        UNTIL orbitScan >= searchWindows OR acceptedSolution
                OR ABORT
                OR _deorbitEvaluations >= TARGET_DEORBIT_MAX_EVALUATIONS {
            IF acceptedSolution OR ABORT OR _deorbitEvaluations >= TARGET_DEORBIT_MAX_EVALUATIONS { BREAK. }
            SET windowsTried TO MAX(windowsTried, orbitScan + 1).
            LOCAL passUT IS targetPassUT.
            LOCAL windowIndex IS orbitScan.
            IF rankedPasses:LENGTH > 0 {
                SET passUT TO rankedPasses[orbitScan]["UT"].
                SET windowIndex TO 0.
            }
            LOCAL window_ IS _targetDeorbitScanWindow(nowUt, period,
                minLead, planningMargin, windowIndex, passUT).
            SET geometry TO _findDeorbitGeometryNode(targetLat, targetLng,
                window_["START"], window_["END"], stepA, candidateAngle).

            IF geometry["VALID"] {
                SET foundGeometry TO TRUE.
                SET candidatesTried TO candidatesTried + 1.
                LOCAL candidateUT IS geometry["UT"].
                mLog("Geometry node window " + (orbitScan + 1)
                    + "/" + scanOrbits
                    + ": T+" + ROUND(candidateUT - nowUt,0)
                    + "s angle=" + ROUND(geometry["ANGLE"],2)
                    + " scanStart=" + ROUND(window_["START"],1)
                    + " scanEnd=" + ROUND(window_["END"],1)
                    + " passUT=" + ROUND(passUT,1)
                    + " subpoint=" + ROUND(geometry["LAT"],4)
                    + "," + ROUND(geometry["LNG"],4) + ".").

                SET solved TO _solveGeometricDeorbitDv(candidateUT,
                    targetLat, targetLng,
                    minLead, minRetroDv, maxRetroDv, seedRetroDv,
                    desiredDownfield, minDownfield, maxDownfield).
                LOCAL newClosest IS FALSE.
                LOCAL merit IS _targetDeorbitMerit(solved, minDownfield, maxDownfield).
                IF merit < closestMerit {
                    SET newClosest TO TRUE.
                    SET closestRejected TO solved.
                    SET closestMerit TO merit.
                    SET closestWindow TO orbitScan + 1.
                    SET closestNodeAngle TO candidateAngle.
                    SET closestLight TO "not-checked".
                }
                IF NOT solved["VALID"] {
                    mLogDetail("Window " + (orbitScan + 1)
                        + " geometry did not solve a valid deorbit.").
                } ELSE IF _targetDeorbitSolutionAccepted(solved,
                        minDownfield, maxDownfield) {
                    // Correction may move the burn time. Geometry must pass
                    // before spending ephemeris work on sunlight/radio.
                    SET geometry["UT"] TO solved["UT"].
                    LOCAL lightAllowed IS _targetDeorbitLightAccepted(solved, solved["UT"], targetLat, targetLng).
                    IF newClosest {
                        SET closestLight TO "rejected".
                        IF lightAllowed { SET closestLight TO "accepted". }
                    }
                    IF NOT lightAllowed {
                        mLogWarn("Deorbit candidate rejected by light/Kerbin policy; scanning later passes.").
                    } ELSE {
                        LOCAL crossTrack IS _targetCrossTrackFromSolved(solved).
                        IF NOT bestAccepted["VALID"]
                                OR crossTrack < bestAcceptedCross {
                            SET bestAccepted TO solved.
                            SET bestAcceptedGeometry TO geometry.
                            SET bestAcceptedCross TO crossTrack.
                        }

                        IF _targetDeorbitRefineDone(solved,minDownfield,maxDownfield) {
                            SET acceptedSolution TO TRUE.
                            IF LANDING_POWERED_LEAD > 0 {
                                mLog("STATS deorbit seed crossM=" + ROUND(crossTrack,0)
                                    + " preferredCrossM=" + ROUND(preferredCrossTrack,0)
                                    + " hardCrossM=" + ROUND(_targetDeorbitCrossAuthority(solved),0)
                                    + " trialsLeft=" + (TARGET_DEORBIT_MAX_EVALUATIONS-_deorbitEvaluations)
                                    + " next=powered-validation").
                            }
                        } ELSE {
                            mLogDetail("Window " + (orbitScan + 1)
                                + " solution accepted but wide: cross="
                                + ROUND(crossTrack/1000,2)
                                + "km preferred<="
                                + ROUND(preferredCrossTrack/1000,2)
                                + "km; scanning later orbit(s).").
                        }
                    }
                } ELSE {
                    LOCAL crossTrack IS _targetCrossTrackFromSolved(solved).
                    LOCAL crossAuth IS _targetDeorbitCrossAuthority(solved).
                    mLogDetail("STATS deorbit candidate window=" + (orbitScan + 1)
                        + " nodeAngle=" + candidateAngle
                        + " dv=" + ROUND(solved["DV"],2)
                        + " reason=" + _targetDeorbitRejection(solved, minDownfield, maxDownfield)
                        + " solution outside deorbit band: dist="
                        + ROUND(solved["DIST"]/1000,2)
                        + "km downfield="
                        + ROUND(solved["DOWNFIELD"]/1000,2)
                        + "km cross="
                        + ROUND(crossTrack/1000,2)
                        + "/" + ROUND(crossAuth/1000,2)
                        + "km fpa=" + ROUND(solved["ANGLE"],1) + ".").
                }
            } ELSE {
                mLogDetail("No deorbit node found at ground angle "
                    + ROUND(candidateAngle,0) + "deg during window "
                    + (orbitScan + 1) + "/" + scanOrbits + ".").
            }
            SET orbitScan TO orbitScan + 1.
            WAIT 0.
        }
    }

    LOCAL searchStop IS "search-horizon".
    IF ABORT { SET searchStop TO "abort". }
    ELSE IF acceptedSolution {
        SET searchStop TO "preferred-solution".
        IF LANDING_POWERED_LEAD > 0 { SET searchStop TO "powered-seed". }
    }
    ELSE IF _deorbitEvaluations >= TARGET_DEORBIT_MAX_EVALUATIONS { SET searchStop TO "trial-budget". }
    mLog("STATS deorbit search evaluations=" + _deorbitEvaluations
        + "/" + TARGET_DEORBIT_MAX_EVALUATIONS
        + " windowsTried=" + windowsTried + "/" + scanOrbits
        + " candidatesTried=" + candidatesTried + " stop=" + searchStop
        + " stopBudget=" + (_deorbitEvaluations >= TARGET_DEORBIT_MAX_EVALUATIONS)).
    IF ABORT { RETURN FALSE. }

    IF NOT acceptedSolution AND bestAccepted["VALID"] {
        SET solved TO bestAccepted.
        SET geometry TO bestAcceptedGeometry.
        SET acceptedSolution TO TRUE.
        mLogWarn("No later pass met preferred cross-track <= "
            + ROUND(preferredCrossTrack/1000,2)
            + "km; using best acceptable cross="
            + ROUND(bestAcceptedCross/1000,2) + "km.").
    }

    IF NOT acceptedSolution {
        IF closestRejected["VALID"] {
            mLogWarn("STATS deorbit best-rejected window=" + closestWindow
                + " nodeAngle=" + closestNodeAngle
                + " geometryReason=" + _targetDeorbitRejection(closestRejected,minDownfield,maxDownfield)
                + " light=" + closestLight
                + " retro=" + ROUND(closestRejected["RETRO"],2)
                + " normal=" + ROUND(closestRejected["NORMAL"],2)
                + " dv=" + ROUND(closestRejected["DV"],2)
                + " downfieldKm=" + ROUND(closestRejected["DOWNFIELD"]/1000,3)
                + " crossKm=" + ROUND(closestRejected["CROSS"]/1000,3)
                + " crossCapKm=" + ROUND(_targetDeorbitCrossAuthority(closestRejected)/1000,3)
                + " fpa=" + ROUND(closestRejected["ANGLE"],2)
                + " PeKm=" + ROUND(closestRejected["PE"]/1000,3)
                + " burnUT=" + closestRejected["UT"]).
        } ELSE {
            mLogWarn("STATS deorbit best-rejected geometryReason=no-valid-impact-prediction candidates=" + candidatesTried).
        }
        IF NOT foundGeometry {
            mLogError("STATS deorbit result=hold: no approaching burn geometry; stop="
                + searchStop + " windowsTried=" + windowsTried + "/" + scanOrbits + ".").
        } ELSE {
            mLogError("STATS deorbit result=hold: search found no validated TR footprint "
                + ROUND(minDownfield/1000,1) + "-"
                + ROUND(maxDownfield/1000,1)
                + "km downfield with acceptable cross-track; retro=" + minRetroDv
                + "-" + maxRetroDv + "m/s normalCap=" + TARGET_DEORBIT_NORMAL_DV_CAP
                + "m/s stop=" + searchStop + " windowsTried=" + windowsTried + "/" + scanOrbits
                + " trials=" + _deorbitEvaluations + "/" + TARGET_DEORBIT_MAX_EVALUATIONS + ".").
        }
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    // A geometric seed is not yet a powered landing solution. Refit its
    // phantom impact to this stack's braking travel, under the SAME native
    // trial cap and normal/cross limits. Every changed node needs a fresh
    // model check, including the last refinement; leave one trial for it.
    LOCAL poweredPass IS 0.
    LOCAL poweredAccepted IS LANDING_POWERED_LEAD <= 0.
    LOCAL poweredStop IS "trial-budget".
    LOCAL poweredReason IS "not-checked".
    LOCAL previousPoweredDownfield IS 0.
    LOCAL previousPoweredResidual IS 0.
    LOCAL hasPoweredHistory IS FALSE.
    LOCAL lastPoweredDiagnostic IS "".
    UNTIL poweredAccepted OR ABORT
            OR _deorbitEvaluations >= TARGET_DEORBIT_MAX_EVALUATIONS {
        SET _deorbitEvaluations TO _deorbitEvaluations+1.
        LOCAL probeNode IS _planRetroNode(solved["UT"],solved["RETRO"],solved["NORMAL"]).
        WAIT 0.5.
        // Geometry and powered travel must describe the same attached node.
        SET solved TO _readGeometricDeorbitNode(probeNode,targetLat,targetLng,desiredDownfield).
        IF NOT solved["VALID"] OR NOT solved["HAS_IMPACT"] {
            REMOVE probeNode.
            mLogWarn("STATS deorbit result=hold reason=powered-lead-no-impact-prediction").
            RETURN FALSE.
        }
        LOCAL leadPolicy IS landingDeorbitLeadPolicy(probeNode,targetLat,targetLng).
        REMOVE probeNode.
        IF NOT leadPolicy["VALID"] {
            mLogWarn("STATS deorbit result=hold reason=powered-lead-" + leadPolicy["REASON"]).
            RETURN FALSE.
        }
        SET desiredDownfield TO leadPolicy["AIM"].
        IF leadPolicy:HASKEY("DIAGNOSTIC") { SET lastPoweredDiagnostic TO leadPolicy["DIAGNOSTIC"]. }
        SET minDownfield TO leadPolicy["MIN"].
        SET maxDownfield TO leadPolicy["MAX"].
        SET solved["ERR"] TO solved["DOWNFIELD"]-desiredDownfield.
        SET poweredPass TO poweredPass+1.
        SET poweredReason TO _targetDeorbitRejection(solved,minDownfield,maxDownfield).
        mLog("STATS deorbit powered-fit pass=" + poweredPass
            + " downfieldM=" + ROUND(solved["DOWNFIELD"],0) + " aimM=" + ROUND(desiredDownfield,0)
            + " residualM=" + ROUND(solved["ERR"],0) + " crossM=" + ROUND(solved["CROSS"],0)
            + " reason=" + poweredReason + " trials=" + _deorbitEvaluations
            + "/" + TARGET_DEORBIT_MAX_EVALUATIONS).
        IF _targetDeorbitSolutionAccepted(solved,minDownfield,maxDownfield) {
            SET poweredAccepted TO TRUE.
        } ELSE {
            // A coupled step needs two probes; a near-root scalar polish
            // needs one. Both reserve a trial and a fresh powered forecast.
            LOCAL neededTrials IS 4.
            IF _targetDeorbitLocalAlongTrack(solved,minDownfield,maxDownfield) { SET neededTrials TO 3. }
            IF _deorbitEvaluations+neededTrials > TARGET_DEORBIT_MAX_EVALUATIONS { BREAK. }
            LOCAL priorUT IS solved["UT"].
            LOCAL priorRetro IS solved["RETRO"].
            LOCAL priorNormal IS solved["NORMAL"].
            LOCAL stepAim IS _targetPoweredStepAim(solved,desiredDownfield,
                previousPoweredDownfield,previousPoweredResidual,hasPoweredHistory,
                (maxDownfield-minDownfield)/2).
            SET previousPoweredDownfield TO solved["DOWNFIELD"].
            SET previousPoweredResidual TO solved["ERR"].
            SET hasPoweredHistory TO TRUE.
            LOCAL stepTolerance IS (maxDownfield-minDownfield)/2.
            mLogDetail("STATS deorbit powered-step mode=" + stepAim["MODE"]
                + " goalM=" + ROUND(stepAim["AIM"],0) + " slope=" + stepAim["SLOPE"]
                + " acceptedStepLimit=1 reserveValidation=1").
            // This goal is a proposal only. The next powered forecast must
            // still pass its own fresh lead, geometry and fuel constraints.
            SET solved["ERR"] TO solved["DOWNFIELD"]-stepAim["AIM"].
            SET solved TO _refineDeorbitFootprint(solved,targetLat,targetLng,minLead,
                stepAim["AIM"],MAX(0,stepAim["AIM"]-stepTolerance),
                stepAim["AIM"]+stepTolerance,minRetroDv,maxRetroDv,1,1).
            SET solved["ERR"] TO solved["DOWNFIELD"]-desiredDownfield.
            IF stepAim["MODE"] = "secant" AND _deorbitEvaluations+4 <= TARGET_DEORBIT_MAX_EVALUATIONS
                    AND ABS(solved["UT"]-priorUT) < 0.001 AND ABS(solved["RETRO"]-priorRetro) < 0.001
                    AND ABS(solved["NORMAL"]-priorNormal) < 0.001 {
                // A bounded extrapolation can miss a nonlinear branch.
                // Fall back to the measured model goal, not a wider gate.
                SET solved TO _refineDeorbitFootprint(solved,targetLat,targetLng,minLead,
                    desiredDownfield,minDownfield,maxDownfield,minRetroDv,maxRetroDv,1,1).
            }
            IF ABS(solved["UT"]-priorUT) < 0.001 AND ABS(solved["RETRO"]-priorRetro) < 0.001
                    AND ABS(solved["NORMAL"]-priorNormal) < 0.001 {
                SET poweredStop TO "no-improving-step".
                BREAK.
            }
        }
    }
    IF ABORT OR NOT poweredAccepted {
        IF ABORT { SET poweredStop TO "abort". }
        LOCAL holdReason IS "powered-lead-not-converged".
        IF poweredPass = 0 AND NOT ABORT { SET holdReason TO "powered-validation-budget-exhausted". }
        mLogWarn("STATS deorbit result=hold reason=" + holdReason + " trials="
            + _deorbitEvaluations + "/" + TARGET_DEORBIT_MAX_EVALUATIONS
            + " stop=" + poweredStop + " passes=" + poweredPass
            + " geometryReason=" + poweredReason + " downfieldM=" + ROUND(solved["DOWNFIELD"],0)
            + " aimM=" + ROUND(desiredDownfield,0) + " residualM=" + ROUND(solved["ERR"],0)
            + " toleranceM=" + ROUND((maxDownfield-minDownfield)/2,0)
            + " crossM=" + ROUND(solved["CROSS"],0)).
        IF lastPoweredDiagnostic <> "" { mLogSummary(lastPoweredDiagnostic). }
        RETURN FALSE.
    }
    IF lastPoweredDiagnostic <> "" { mLogSummary(lastPoweredDiagnostic). }
    SET geometry["UT"] TO solved["UT"].
    LOCAL bestUT IS geometry["UT"].
    LOCAL bestRetroDv IS solved["RETRO"].
    LOCAL bestNormalDv IS solved["NORMAL"].
    LOCAL bestDist IS solved["DIST"].
    LOCAL bestAngle IS solved["ANGLE"].
    LOCAL bestDownfield IS solved["DOWNFIELD"].
    LOCAL bestPe IS solved["PE"].
    LOCAL bestCross IS _targetCrossTrackFromSolved(solved).
    LOCAL bestCrossAuthority IS _targetDeorbitCrossAuthority(solved).

    LOCAL solvedImpactText IS " impact=none".
    IF solved["HAS_IMPACT"] {
        SET solvedImpactText TO " impact=" + ROUND(solved["LAT"],4)
            + "," + ROUND(solved["LNG"],4)
            + " dist=" + ROUND(bestDist/1000,2) + "km"
            + " downfield=" + ROUND(bestDownfield/1000,2) + "km"
            + " cross=" + ROUND(bestCross/1000,2)
            + "/" + ROUND(bestCrossAuthority/1000,2) + "km".
    }
    mLogSummary("STATS deorbit solved: T+" + ROUND(bestUT - nowUt,0)
        + "s dv=" + ROUND(solved["DV"],2)
        + " targetLat=" + ROUND(targetLat,4)
        + " targetLng=" + ROUND(targetLng,4)
        + " orbitInc=" + ROUND(SHIP:ORBIT:INCLINATION,2)
        + " retro=" + ROUND(bestRetroDv,2)
        + " normal=" + ROUND(bestNormalDv,2)
        + solvedImpactText
        + " Pe=" + ROUND(bestPe/1000,2) + "km"
        + " fpa=" + ROUND(bestAngle,1) + ".").
    IF NOT solved["HAS_IMPACT"] {
        mLogError("Solved node has no Trajectories impact.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF bestDownfield < 0 {
        mLogError("Solved node impacts upfield of target: downfield="
            + ROUND(bestDownfield/1000,2) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF bestDownfield < minDownfield OR bestDownfield > maxDownfield {
        mLogError("Solved node impact is outside downfield band: "
            + ROUND(bestDownfield/1000,2) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF bestCross > bestCrossAuthority {
        mLogError("Solved node impact exceeds cross-track authority: "
            + ROUND(bestCross/1000,2) + "km > "
            + ROUND(bestCrossAuthority/1000,2) + "km.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }
    IF DEORBIT_MIN_FPA > 0
            AND (bestAngle < 0 OR bestAngle < DEORBIT_MIN_FPA) {
        mLogError("Solved node impact FPA below safe floor: "
            + ROUND(bestAngle,1) + "deg < "
            + ROUND(DEORBIT_MIN_FPA,1) + "deg.").
        UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
        RETURN FALSE.
    }

    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    IF bestUT <= TIME:SECONDS + minLead {
        mLogWarn("STATS deorbit result=hold reason=planning-window-expired").
        RETURN FALSE.
    }
    LOCAL realNode IS _planRetroNode(bestUT, bestRetroDv, bestNormalDv).
    _logDeorbitNode("Selected deorbit node", realNode).
    WAIT 0.5.
    LOCAL finalCheck IS _readGeometricDeorbitNode(realNode,
        targetLat, targetLng, desiredDownfield).
    mLogSummary("STATS deorbit final valid=" + finalCheck["VALID"]
        + " dv=" + ROUND(solved["DV"],2)
        + " downfieldKm=" + ROUND(finalCheck["DOWNFIELD"]/1000,2)
        + " crossKm=" + ROUND(finalCheck["CROSS"]/1000,2)
        + " reason=" + _targetDeorbitRejection(finalCheck, minDownfield, maxDownfield)).
    IF NOT _targetDeorbitSolutionAccepted(finalCheck, minDownfield, maxDownfield) {
        mLogWarn("Final deorbit prediction failed revalidation; retaining orbit.").
        REMOVE realNode.
        RETURN FALSE.
    }
    IF NOT _targetDeorbitLightAccepted(finalCheck, bestUT, targetLat, targetLng) {
        REMOVE realNode.
        RETURN FALSE.
    }

    IF NOT landingDeorbitNodeAccepted(realNode,targetLat,targetLng) {
        REMOVE realNode.
        RETURN FALSE.
    }

    IF bestUT <= TIME:SECONDS + minLead {
        mLogWarn("STATS deorbit result=hold reason=validation-window-expired").
        REMOVE realNode.
        RETURN FALSE.
    }
    mLog("Executing deorbit burn at T+" + ROUND(bestUT - TIME:SECONDS,0) + "s.").
    archiveLog().
    HUDTEXT("Deorbit burn in " + ROUND(bestUT - TIME:SECONDS,0) + "s",
        3, 2, 13, CYAN, FALSE).
    IF NOT executeDeorbitNode(realNode, targetLat, targetLng, landingDeorbitNodeReady@) { RETURN FALSE. }

    WAIT 2.
    IF ADDONS:TR:HASIMPACT {
        LOCAL postImpact IS ADDONS:TR:IMPACTPOS.
        LOCAL postDist IS _targetDeorbitDistance(postImpact:LAT,
            postImpact:LNG, targetLat, targetLng).
        LOCAL postDownfield IS _targetDownfieldDistance(postImpact:LAT,
            postImpact:LNG, targetLat, targetLng,
            TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT).
        mLog("Post-burn impact prediction: "
            + ROUND(postImpact:LAT,4) + "," + ROUND(postImpact:LNG,4)
            + " dist=" + ROUND(postDist/1000,1) + "km"
            + " downfield=" + ROUND(postDownfield/1000,1) + "km.").
    } ELSE {
        mLogWarn("Post-burn: Trajectories has no impact prediction.").
    }
    RETURN TRUE.
}

// Find local minima of range on the unburned, rotating ground track.
// These are seeds only: all TR/terrain/light/fuel checks still follow.
LOCAL FUNCTION _targetDeorbitFixedPasses {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER earliestPass.
    PARAMETER period.
    PARAMETER keepCount.
    LOCAL span IS MAX(period * keepCount,
        ABS(SHIP:BODY:ROTATIONPERIOD) * MIN(2, TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS)).
    LOCAL stepSec IS MAX(period/64,span/4096).
    LOCAL endUT IS earliestPass + span.
    LOCAL passes IS LIST().
    LOCAL surveyStart IS TIME:SECONDS.
    LOCAL previous IS _targetGroundAngleAt(earliestPass,targetLat,targetLng).
    LOCAL beforeUT IS earliestPass.
    LOCAL beforeAngle IS previous["ANGLE"].
    LOCAL sampleUT IS earliestPass + stepSec.
    LOCAL samples IS 0.
    mLog("STATS deorbit pass-survey begin startUT=" + earliestPass
        + " endUT=" + endUT + " stepSec=" + stepSec).
    UNTIL sampleUT > endUT OR ABORT OR samples >= 4096 {
        LOCAL sample IS _targetGroundAngleAt(sampleUT,targetLat,targetLng).
        IF previous["ANGLE"] <= sample["ANGLE"] AND beforeUT < previous["UT"] {
            // Only refine a descending-to-ascending minimum, not a flat
            // pole-distance plateau or an already receding boundary.
            IF beforeAngle > previous["ANGLE"] {
                LOCAL lo IS beforeUT.
                LOCAL hi IS sampleUT.
                LOCAL iter IS 0.
                UNTIL hi-lo <= 0.5 OR iter >= 16 OR ABORT {
                    LOCAL leftUT IS lo + (hi-lo)/3.
                    LOCAL rightUT IS hi - (hi-lo)/3.
                    LOCAL left IS _targetGroundAngleAt(leftUT,targetLat,targetLng).
                    LOCAL right IS _targetGroundAngleAt(rightUT,targetLat,targetLng).
                    IF left["ANGLE"] <= right["ANGLE"] { SET hi TO rightUT. }
                    ELSE { SET lo TO leftUT. }
                    SET iter TO iter + 1.
                }
                LOCAL passInfo IS _targetGroundAngleAt((lo+hi)/2,targetLat,targetLng).
                passes:ADD(passInfo).
                IF passes:LENGTH > keepCount {
                    LOCAL worst IS 0.
                    LOCAL i IS 1.
                    UNTIL i >= passes:LENGTH {
                        IF passes[i]["ANGLE"] > passes[worst]["ANGLE"] { SET worst TO i. }
                        SET i TO i+1.
                    }
                    passes:REMOVE(worst).
                }
            }
        }
        SET beforeUT TO previous["UT"].
        SET beforeAngle TO previous["ANGLE"].
        SET previous TO sample.
        SET sampleUT TO sampleUT+stepSec.
        SET samples TO samples+1.
        IF MOD(samples,16) = 0 { WAIT 0. }
    }
    LOCAL ordered IS LIST().
    UNTIL passes:LENGTH = 0 OR ABORT {
        LOCAL best IS 0.
        LOCAL i IS 1.
        UNTIL i >= passes:LENGTH {
            IF passes[i]["ANGLE"] < passes[best]["ANGLE"] { SET best TO i. }
            SET i TO i+1.
        }
        LOCAL passInfo IS passes[best].
        ordered:ADD(passInfo).
        passes:REMOVE(best).
        LOCAL rankLine IS "STATS deorbit fixed-pass rank=" + ordered:LENGTH
            + " passUT=" + passInfo["UT"] + " eta=" + (passInfo["UT"]-TIME:SECONDS)
            + " unburnedMissKm=" + passInfo["ANGLE"]*SHIP:BODY:RADIUS*CONSTANT:PI/180000.
        IF ordered:LENGTH <= 3 { mLog(rankLine). }
        ELSE { mLogDetail(rankLine). }
    }
    mLog("STATS deorbit pass-survey complete samples=" + samples
        + " ranked=" + ordered:LENGTH + " nativeTrials=" + _deorbitEvaluations
        + " elapsedSec=" + ROUND(TIME:SECONDS-surveyStart,1)).
    RETURN ordered.
}

LOCAL FUNCTION _targetCrossTrackFromSolved {
    PARAMETER solved.
    IF NOT solved["HAS_IMPACT"] { RETURN 999999999. }
    RETURN solved["CROSS"].
}

GLOBAL FUNCTION landingDeorbitNodeAccepted {
    PARAMETER nd.
    PARAMETER targetLat.
    PARAMETER targetLng.
    SET _deorbitLastCheck TO LEXICON("VALID",FALSE).
    WAIT 0.5.
    IF ABORT OR NOT HASNODE { RETURN FALSE. }
    LOCAL leadPolicy IS landingDeorbitLeadPolicy(nd,targetLat,targetLng).
    IF NOT leadPolicy["VALID"] {
        mLogWarn("STATS deorbit retained-node geometryReason=powered-lead-" + leadPolicy["REASON"]).
        RETURN FALSE.
    }
    LOCAL solved IS _readGeometricDeorbitNode(nd, targetLat, targetLng, leadPolicy["AIM"]).
    LOCAL reason IS _targetDeorbitRejection(solved, leadPolicy["MIN"], leadPolicy["MAX"]).
    SET _deorbitLastCheck TO LEXICON("VALID",TRUE,"REASON",reason,"ERR",solved["ERR"]).
    mLogSummary("STATS deorbit retained-node geometryReason=" + reason
        + " targetLat=" + targetLat + " targetLng=" + targetLng
        + " downfieldM=" + solved["DOWNFIELD"] + " crossM=" + solved["CROSS"]
        + " aimM=" + leadPolicy["AIM"] + " minM=" + leadPolicy["MIN"]
        + " maxM=" + leadPolicy["MAX"] + " residualM=" + solved["ERR"]
        + " nodeUt=" + nd:TIME + " nodeDv=" + nd:DELTAV:MAG).
    IF reason <> "accepted" AND leadPolicy:HASKEY("DIAGNOSTIC") { mLogSummary(leadPolicy["DIAGNOSTIC"]). }
    IF reason <> "accepted" { RETURN FALSE. }
    RETURN _targetDeorbitTerrainAccepted(nd:TIME, targetLat, targetLng).
}

// A late forecast can change even with an unchanged TR impact. Refit ONLY
// its along-track residual, at the same epoch and with the same normal/radial
// components. Never replace/detach the executor's node or relax admission.
// This is a separate bounded pre-burn pass, not a reset of the orbital search.
GLOBAL FUNCTION landingDeorbitNodeReady {
    PARAMETER nd.
    PARAMETER targetLat.
    PARAMETER targetLng.
    IF landingDeorbitNodeAccepted(nd,targetLat,targetLng) { RETURN TRUE. }
    IF LANDING_POWERED_LEAD <= 0 { RETURN FALSE. }
    IF NOT _deorbitLastCheck["VALID"] { RETURN FALSE. }
    LOCAL reason IS _deorbitLastCheck["REASON"].
    IF reason <> "insufficient-braking-lead" AND reason <> "excessive-braking-lead" { RETURN FALSE. }
    IF ABORT OR NOT HASNODE OR SHIP:STATUS <> "ORBITING" OR SHIP:PERIAPSIS <= 0
            OR stateGet("deorbit_burn_started","false") = "true"
            OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 { RETURN FALSE. }
    LOCAL originalPro IS nd:PROGRADE.
    IF originalPro > -2 OR originalPro < -120 OR ABS(nd:RADIALOUT) > 0.001 { RETURN FALSE. }
    LOCAL originalBody IS SHIP:BODY.
    LOCAL baseRetro IS -originalPro.
    LOCAL baseError IS _deorbitLastCheck["ERR"].
    LOCAL deadline IS MIN(TIME:SECONDS+160,nd:TIME-90).
    LOCAL iteration IS 0.
    LOCAL checks IS 1.
    LOCAL admitted IS FALSE.
    mLogWarn("STATS deorbit preburn-refit status=begin residualM=" + ROUND(baseError,0)
        + " retro=" + baseRetro + " eta=" + ROUND(nd:ETA,1) + " maxForecasts=7").
    UNTIL iteration >= 3 OR ABORT OR NOT HASNODE OR SHIP:BODY <> originalBody OR TIME:SECONDS+25 >= deadline {
        LOCAL probeRetro IS MIN(120,baseRetro+0.5).
        IF probeRetro-baseRetro < 0.01 { SET probeRetro TO MAX(2,baseRetro-0.5). }
        SET probeRetro TO MAX(-originalPro-10,MIN(-originalPro+10,probeRetro)).
        LOCAL probeDv IS probeRetro-baseRetro.
        IF ABS(probeDv) < 0.01 { BREAK. }
        SET nd:PROGRADE TO -probeRetro.
        SET checks TO checks+1.
        SET admitted TO landingDeorbitNodeAccepted(nd,targetLat,targetLng).
        IF admitted { BREAK. }
        IF ABORT OR NOT HASNODE OR SHIP:BODY <> originalBody OR NOT _deorbitLastCheck["VALID"] { BREAK. }
        SET reason TO _deorbitLastCheck["REASON"].
        IF reason <> "insufficient-braking-lead" AND reason <> "excessive-braking-lead" { BREAK. }
        LOCAL slope IS (_deorbitLastCheck["ERR"]-baseError)/probeDv.
        IF NOT (ABS(slope) >= 1 AND ABS(slope) < 1e30) OR TIME:SECONDS+25 >= deadline { BREAK. }
        LOCAL trialRetro IS MAX(2,MIN(120,baseRetro+MAX(-5,MIN(5,-baseError/slope)))).
        SET trialRetro TO MAX(-originalPro-10,MIN(-originalPro+10,trialRetro)).
        IF ABS(trialRetro-baseRetro) < 0.001 { BREAK. }
        SET nd:PROGRADE TO -trialRetro.
        SET checks TO checks+1.
        SET admitted TO landingDeorbitNodeAccepted(nd,targetLat,targetLng).
        IF admitted { BREAK. }
        IF ABORT OR NOT HASNODE OR SHIP:BODY <> originalBody OR NOT _deorbitLastCheck["VALID"] { BREAK. }
        SET reason TO _deorbitLastCheck["REASON"].
        IF reason <> "insufficient-braking-lead" AND reason <> "excessive-braking-lead" { BREAK. }
        IF NOT (ABS(_deorbitLastCheck["ERR"]) < ABS(baseError)) { BREAK. }
        SET baseRetro TO trialRetro.
        SET baseError TO _deorbitLastCheck["ERR"].
        SET iteration TO iteration+1.
    }
    // REASON alone cannot approve terrain or a cancelled/deadline-late check.
    IF admitted AND NOT ABORT AND HASNODE AND TIME:SECONDS < deadline
            AND SHIP:BODY = originalBody AND SHIP:STATUS = "ORBITING" AND SHIP:PERIAPSIS > 0
            AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
            AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0
            AND landingLightNodeAllowed(nd,targetLat,targetLng) {
        mLog("STATS deorbit preburn-refit status=accepted forecasts=" + checks
            + " retro=" + -nd:PROGRADE + " residualM=" + ROUND(_deorbitLastCheck["ERR"],0)).
        RETURN TRUE.
    }
    IF HASNODE { SET nd:PROGRADE TO originalPro. WAIT 0.5. }
    mLogWarn("STATS deorbit preburn-refit status=hold forecasts=" + checks + " originalNodeRestored=" + HASNODE).
    RETURN FALSE.
}

LOCAL FUNCTION _targetDeorbitTerrainAccepted {
    PARAMETER burnUT.
    PARAMETER targetLat.
    PARAMETER targetLng.
    IF NOT TERRAIN_VALIDATE { RETURN TRUE. }
    LOCAL crashInfo IS lmTerrainClearanceInfo(targetLat, targetLng, burnUT,
        burnUT + 30, burnUT + 1800, 2, TERRAIN_MIN_CLEARANCE, TERRAIN_SAFE_ALT).
    IF crashInfo["HIT"] AND crashInfo["DOWNFIELD"] < 0 {
        mLogError("TERRAIN CHECK FAILED: trajectory hits terrain before target pass "
            + "downfield=" + ROUND(crashInfo["DOWNFIELD"],0)
            + "m dist=" + ROUND(crashInfo["DIST"],0)
            + "m clearance=" + ROUND(crashInfo["CLEARANCE"],1) + "m.").
        RETURN FALSE.
    }
    IF crashInfo["HIT"] {
        mLogWarn("Terrain contact beyond target (expected ballistic overshoot): hitLat="
            + ROUND(crashInfo["LAT"],4) + " hitLng=" + ROUND(crashInfo["LNG"],4)
            + " downfield=" + ROUND(crashInfo["DOWNFIELD"],0)
            + "m dist=" + ROUND(crashInfo["DIST"],0)
            + "m clearance=" + ROUND(crashInfo["CLEARANCE"],1) + "m.").
    } ELSE { mLog("Terrain check passed."). }
    RETURN TRUE.
}

LOCAL FUNCTION _targetDeorbitSolutionAccepted {
    PARAMETER solved.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    RETURN _targetDeorbitRejection(solved, minDownfield, maxDownfield) = "accepted".
}

LOCAL FUNCTION _targetDeorbitRejection {
    PARAMETER solved.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    IF NOT solved["VALID"] OR NOT solved["HAS_IMPACT"] { RETURN "no-impact-prediction". }
    // NaN is neither below nor above a band; it must not fall through as
    // accepted when a native predictor/probe returns invalid geometry.
    IF NOT (ABS(solved["DOWNFIELD"]) < 1e30
            AND minDownfield >= 0 AND maxDownfield >= minDownfield AND maxDownfield < 1e30
            AND solved["CROSS"] >= 0 AND solved["CROSS"] < 1e30
            AND solved["DV"] >= 0 AND solved["DV"] < 1e30) { RETURN "invalid-impact-geometry". }
    IF solved["DV"] > SHIP:DELTAV:VACUUM { RETURN "fuel". }
    IF ABS(solved["NORMAL"]) > MAX(0, TARGET_DEORBIT_NORMAL_DV_CAP) + 0.001 { RETURN "normal-cap". }
    IF solved["DOWNFIELD"] < minDownfield { RETURN "insufficient-braking-lead". }
    IF solved["DOWNFIELD"] > maxDownfield { RETURN "excessive-braking-lead". }
    IF DEORBIT_MIN_FPA > 0
            AND (solved["ANGLE"] < 0 OR solved["ANGLE"] < DEORBIT_MIN_FPA) {
        RETURN "impact-angle".
    }
    IF _targetCrossTrackFromSolved(solved) > _targetDeorbitCrossAuthority(solved) {
        RETURN "cross-track".
    }
    RETURN "accepted".
}

LOCAL FUNCTION _targetDeorbitCrossAuthority {
    PARAMETER solved.
    IF DEORBIT_CROSSTRACK_AUTHORITY_KM > 0 {
        RETURN DEORBIT_CROSSTRACK_AUTHORITY_KM * 1000.
    }

    LOCAL maxAcc IS 0.
    IF SHIP:MASS > 0 {
        SET maxAcc TO MAX(SHIP:AVAILABLETHRUST, SHIP:MAXTHRUST)
            / SHIP:MASS.
    }
    IF maxAcc <= 0 { RETURN 0. }

    LOCAL tti IS 0.
    IF solved:HASKEY("TTI") { SET tti TO solved["TTI"]. }
    LOCAL mccWindow IS tti
        - LANDING_COAST_MCC_MIN_BRAKE_ETA
        - LANDING_BRAKE_ALIGN_LEAD.
    IF mccWindow < 0 { SET mccWindow TO 0. }

    LOCAL pulseCycle IS LANDING_COAST_MCC_PULSE_TIME
        + LANDING_COAST_MCC_SETTLE_TIME.
    LOCAL duty IS 1.
    IF pulseCycle > 0 {
        SET duty TO LANDING_COAST_MCC_PULSE_TIME / pulseCycle.
    }
    LOCAL mccAcc IS maxAcc * LANDING_COAST_MCC_THROTTLE_MAX * duty.
    LOCAL mccAuthority IS 0.5 * mccAcc * mccWindow ^ 2.

    LOCAL brakeWindow IS LANDING_COAST_MCC_MIN_BRAKE_ETA
        + LANDING_BRAKE_ALIGN_LEAD.
    LOCAL brakeBias IS MIN(TR_BRAKE_BIAS, ABS(SIN(CROSS_PID_MAX))).
    LOCAL brakeAcc IS maxAcc * LANDING_HKILL_THROTTLE_MIN * brakeBias.
    LOCAL brakeAuthority IS 0.5 * brakeAcc * brakeWindow ^ 2.

    RETURN mccAuthority + brakeAuthority.
}

LOCAL FUNCTION _targetDeorbitLightAccepted {
    PARAMETER solved.
    PARAMETER burnUT.
    PARAMETER targetLat.
    PARAMETER targetLng.
    IF NOT landingLightActive() { RETURN TRUE. }
    IF NOT solved["HAS_IMPACT"] { RETURN FALSE. }
    LOCAL light IS landingPlanningLight(targetLat, targetLng, burnUT + solved["TTI"], TRUE).
    mLog("STATS deorbit light ok=" + light["OK"] + " reason=" + light["REASON"]
        + " sun=" + ROUND(light["SUN"],2) + " kerbin=" + ROUND(light["KERBIN"],2)
        + " siteRadius=" + landingPlanningRadius()).
    RETURN light["OK"].
}

// An automatic site is underneath ONE particular future orbital pass.
// Searching earlier passes can require a large plane change on a rotating
// body, even though the latitude is within the inclination. Try its own
// approaching half-orbit first; only then consider later windows. Fixed
// targets without pass context retain the ordinary forward search.
LOCAL FUNCTION _targetDeorbitScanWindow {
    PARAMETER nowUT.
    PARAMETER period.
    PARAMETER minLead.
    PARAMETER planningMargin.
    PARAMETER orbitScan.
    PARAMETER targetPassUT.
    LOCAL earliest IS TIME:SECONDS + minLead + planningMargin.
    LOCAL startUT IS MAX(earliest, nowUT + minLead + orbitScan * period).
    LOCAL endUT IS startUT + period + 30.
    IF targetPassUT > 0 {
        IF orbitScan = 0 {
            SET startUT TO MAX(earliest, targetPassUT - period / 2).
            SET endUT TO targetPassUT.
        } ELSE {
            SET startUT TO MAX(earliest, targetPassUT + (orbitScan - 1) * period).
            SET endUT TO startUT + period + 30.
        }
    }
    RETURN LEXICON("START", startUT, "END", endUT).
}

LOCAL FUNCTION _findDeorbitGeometryNode {
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER scanStart.
    PARAMETER scanEnd.
    PARAMETER stepSec.
    PARAMETER desiredAngle.

    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "UT", scanStart,
        "ANGLE", 999999999,
        "ERR", 999999999,
        "LAT", 0,
        "LNG", 0
    ).
    IF scanStart >= scanEnd OR ABORT { RETURN result. }

    LOCAL prevT IS scanStart.
    LOCAL prevInfo IS _targetGroundAngleAt(prevT, targetLat, targetLng).
    LOCAL bestInfo IS prevInfo.
    LOCAL bestErr IS ABS(prevInfo["ANGLE"] - desiredAngle).
    LOCAL scanT IS scanStart + stepSec.
    LOCAL samplesSinceYield IS 0.

    UNTIL scanT > scanEnd OR ABORT {
        LOCAL info IS _targetGroundAngleAt(scanT, targetLat, targetLng).
        LOCAL err IS ABS(info["ANGLE"] - desiredAngle).
        IF err < bestErr {
            SET bestErr TO err.
            SET bestInfo TO info.
        }

        IF prevInfo["ANGLE"] >= desiredAngle
                AND info["ANGLE"] <= desiredAngle {
            LOCAL lo IS prevT.
            LOCAL hi IS scanT.
            LOCAL iter IS 0.
            // Sub-second timing is sufficient here; avoid refining a
            // coarse orbital seed to microseconds before consulting TR.
            UNTIL iter >= 24 OR hi - lo <= 0.25 {
                LOCAL mid IS (lo + hi) / 2.
                LOCAL midInfo IS _targetGroundAngleAt(mid,
                    targetLat, targetLng).
                IF midInfo["ANGLE"] > desiredAngle {
                    SET lo TO mid.
                } ELSE {
                    SET hi TO mid.
                }
                SET iter TO iter + 1.
            }

            SET result TO _targetGroundAngleAt((lo + hi) / 2,
                targetLat, targetLng).
            SET result["VALID"] TO TRUE.
            SET result["ERR"] TO ABS(result["ANGLE"] - desiredAngle).
            RETURN result.
        }

        SET prevT TO scanT.
        SET prevInfo TO info.
        SET scanT TO scanT + stepSec.
        // Pure geometry needs no physics update for each future sample.
        // Keep the UI responsive without spending 512 ticks per scan.
        SET samplesSinceYield TO samplesSinceYield + 1.
        IF samplesSinceYield >= 16 {
            WAIT 0.
            SET samplesSinceYield TO 0.
        }
    }

    IF NOT ABORT AND bestErr < 1 {
        SET result TO bestInfo.
        SET result["VALID"] TO TRUE.
        SET result["ERR"] TO bestErr.
    }
    RETURN result.
}

LOCAL FUNCTION _targetGroundAngleAt {
    PARAMETER ut.
    PARAMETER targetLat.
    PARAMETER targetLng.

    LOCAL geo IS lmGroundGeoAt(ut).
    RETURN LEXICON(
        "VALID", TRUE,
        "UT", ut,
        "ANGLE", _targetCentralAngle(geo:LAT, geo:LNG,
            targetLat, targetLng),
        "LAT", geo:LAT,
        "LNG", geo:LNG
    ).
}

LOCAL FUNCTION _targetCentralAngle {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    LOCAL bodyPos IS SHIP:BODY:POSITION.
    RETURN VANG(LATLNG(lat1, lng1):ALTITUDEPOSITION(0) - bodyPos,
        LATLNG(lat2, lng2):ALTITUDEPOSITION(0) - bodyPos).
}

LOCAL FUNCTION _targetDeorbitDistance {
    PARAMETER lat1.
    PARAMETER lng1.
    PARAMETER lat2.
    PARAMETER lng2.

    RETURN _targetCentralAngle(lat1, lng1, lat2, lng2)
        * SHIP:BODY:RADIUS * CONSTANT:PI / 180.
}

LOCAL FUNCTION _targetDownfieldDistance {
    PARAMETER impactLat.
    PARAMETER impactLng.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER impactUT.
    LOCAL offset IS lmSurfaceTrackOffset(targetLat, targetLng,
        impactLat, impactLng, lmGroundVelocityAt(impactUT)).
    RETURN offset["DOWNFIELD"].
}

LOCAL FUNCTION _solveGeometricDeorbitDv {
    PARAMETER burnUT.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER minDv.
    PARAMETER maxDv.
    PARAMETER seedDv.
    PARAMETER desiredDownfield.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    LOCAL maxAllowed IS MIN(maxDv, SHIP:DELTAV:VACUUM).
    IF maxAllowed < minDv { RETURN LEXICON("VALID", FALSE, "HAS_IMPACT", FALSE). }
    LOCAL currentDv IS MAX(minDv, MIN(maxAllowed, seedDv)).
    LOCAL iter IS 0.
    // Bootstrap an impact, then solve the footprint together. Do not polish
    // a downrange-only root while ignoring a large lateral miss.
    UNTIL iter >= 8 OR ABORT OR _deorbitEvaluations >= TARGET_DEORBIT_MAX_EVALUATIONS {
        IF burnUT <= TIME:SECONDS + minLead { BREAK. }
        LOCAL trial IS _evalGeometricDeorbitNode(burnUT, currentDv,
            targetLat, targetLng, minLead, desiredDownfield).
        IF trial["VALID"] {
            IF _targetDeorbitRefineDone(trial, minDownfield, maxDownfield) { RETURN trial. }
            SET trial TO _targetDeorbitRangeSeed(trial, targetLat, targetLng,
                minLead, desiredDownfield, minDownfield, maxDownfield, minDv, maxAllowed).
            RETURN _refineDeorbitFootprint(trial, targetLat, targetLng,
                minLead, desiredDownfield, minDownfield, maxDownfield, minDv, maxAllowed).
        }
        IF currentDv >= maxAllowed { BREAK. }
        SET currentDv TO MIN(maxAllowed, currentDv * 1.5).
        SET iter TO iter + 1.
    }
    RETURN LEXICON("VALID", FALSE, "HAS_IMPACT", FALSE).
}

// Precondition a far-downrange seed at fixed time before the coupled solve.
// Otherwise cross-track sensitivity can force tiny retro changes while timing
// runs against its limit. Every probe consumes the same native-trial budget.
LOCAL FUNCTION _targetDeorbitRangeSeed {
    PARAMETER best.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER desiredDownfield.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    PARAMETER minDv.
    PARAMETER maxDv.
    LOCAL iter IS 0.
    UNTIL iter >= 6 OR ABORT OR _deorbitEvaluations + 2 > TARGET_DEORBIT_MAX_EVALUATIONS {
        IF best["DOWNFIELD"] >= minDownfield AND best["DOWNFIELD"] <= maxDownfield { BREAK. }
        LOCAL probeDv IS MIN(1, maxDv-best["RETRO"]).
        IF probeDv < 0.01 { SET probeDv TO -MIN(1,best["RETRO"]-minDv). }
        IF ABS(probeDv) < 0.01 { BREAK. }
        LOCAL probe IS _evalGeometricDeorbitNode(best["UT"],best["RETRO"]+probeDv,
            targetLat,targetLng,minLead,desiredDownfield,best["NORMAL"]).
        IF NOT probe["VALID"] { BREAK. }
        LOCAL slope IS (probe["ERR"]-best["ERR"])/probeDv.
        IF ABS(slope) < 1 { BREAK. }
        LOCAL nextRetro IS MAX(minDv,MIN(maxDv,
            best["RETRO"]+MAX(-40,MIN(40,-best["ERR"]/slope)))).
        IF ABS(nextRetro-best["RETRO"]) < 0.001 { BREAK. }
        LOCAL trial IS _evalGeometricDeorbitNode(best["UT"],nextRetro,
            targetLat,targetLng,minLead,desiredDownfield,best["NORMAL"]).
        IF NOT trial["VALID"] OR ABS(trial["ERR"]) >= ABS(best["ERR"]) { BREAK. }
        SET best TO trial.
        mLogDetail("STATS deorbit range-seed retro=" + ROUND(best["RETRO"],2)
            + " downfieldM=" + ROUND(best["DOWNFIELD"],0)
            + " crossM=" + ROUND(best["CROSS"],0) + " evaluations=" + _deorbitEvaluations).
        SET iter TO iter+1.
    }
    RETURN best.
}

LOCAL FUNCTION _targetDeorbitRefineDone {
    PARAMETER solved.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    IF NOT _targetDeorbitSolutionAccepted(solved, minDownfield, maxDownfield) { RETURN FALSE. }
    // The preferred ballistic cross-track is an optimization, not admission.
    // Once a powered mission has a physically admissible seed, spend the
    // remaining trials on its mandatory finite-burn forecast and moving
    // downfield goal. This predicate also stops needless inner polishing;
    // the outer powered loop still requires its own fresh model acceptance.
    IF LANDING_POWERED_LEAD > 0 { RETURN TRUE. }
    LOCAL aim IS _targetDeorbitCrossAuthority(solved).
    IF TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM > 0 {
        SET aim TO MIN(aim, TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM * 1000).
    }
    RETURN solved["CROSS"] <= aim.
}

LOCAL FUNCTION _targetDeorbitMerit {
    PARAMETER solved.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    IF NOT solved["VALID"] OR NOT solved["HAS_IMPACT"] { RETURN 1e30. }
    LOCAL outsideBand IS MAX(0, MAX(minDownfield - solved["DOWNFIELD"], solved["DOWNFIELD"] - maxDownfield)).
    RETURN outsideBand ^ 2 + solved["CROSS"] ^ 2.
}

LOCAL FUNCTION _targetDeorbitCorrection {
    PARAMETER alongError.
    PARAMETER crossError.
    PARAMETER alongRetro.
    PARAMETER alongOther.
    PARAMETER crossRetro.
    PARAMETER crossOther.
    LOCAL determinant IS alongRetro * crossOther - alongOther * crossRetro.
    IF ABS(determinant) <= MAX(1, 0.000001 * (ABS(alongRetro * crossOther) + ABS(alongOther * crossRetro))) {
        RETURN LEXICON("VALID", FALSE).
    }
    RETURN LEXICON("VALID", TRUE,
        "RETRO", (-alongError * crossOther + alongOther * crossError) / determinant,
        "OTHER", (crossRetro * alongError - alongRetro * crossError) / determinant).
}

// A footprint already inside its downfield band need not be driven to the
// band's center to fix latitude. Reuse the measured normal probe for a
// bounded coordinate step when the coupled Newton response cannot improve.
LOCAL FUNCTION _targetDeorbitNormalCorrection {
    PARAMETER best.
    PARAMETER probe.
    PARAMETER probeDv.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    LOCAL invalid IS LEXICON("VALID",FALSE).
    IF NOT best["VALID"] OR NOT probe["VALID"] { RETURN invalid. }
    IF NOT best["HAS_IMPACT"] OR NOT probe["HAS_IMPACT"] { RETURN invalid. }
    IF NOT (best["DOWNFIELD"] >= minDownfield AND best["DOWNFIELD"] <= maxDownfield)
            OR ABS(probeDv) < 0.01 OR NOT (ABS(best["SIGNED_CROSS"]) < 1e30) { RETURN invalid. }
    LOCAL slope IS (probe["SIGNED_CROSS"]-best["SIGNED_CROSS"])/probeDv.
    IF NOT (ABS(slope) >= 1 AND ABS(slope) < 1e30) { RETURN invalid. }
    LOCAL stepDv IS -best["SIGNED_CROSS"]/slope.
    IF NOT (ABS(stepDv) < 1e30) { RETURN invalid. }
    RETURN LEXICON("VALID",TRUE,"RETRO",0,"OTHER",stepDv).
}

// At a normal/time bound, do not scale an otherwise useful retrograde step
// to zero just to chase cross-track zero. Existing acceptable cross-track
// may be retained while the powered along-track goal is still out of band.
LOCAL FUNCTION _targetDeorbitRetroCorrection {
    PARAMETER best.
    PARAMETER probe.
    PARAMETER probeDv.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    LOCAL invalid IS LEXICON("VALID",FALSE).
    IF LANDING_POWERED_LEAD <= 0 OR NOT best["VALID"] OR NOT probe["VALID"] { RETURN invalid. }
    IF NOT best["HAS_IMPACT"] OR NOT probe["HAS_IMPACT"] OR ABS(probeDv) < 0.01 { RETURN invalid. }
    IF NOT (best["CROSS"] <= _targetDeorbitCrossAuthority(best)) { RETURN invalid. }
    IF NOT (best["DOWNFIELD"] < minDownfield OR best["DOWNFIELD"] > maxDownfield) { RETURN invalid. }
    LOCAL slope IS (probe["ERR"]-best["ERR"])/probeDv.
    IF NOT (ABS(slope) >= 1 AND ABS(slope) < 1e30 AND ABS(best["ERR"]) < 1e30) { RETURN invalid. }
    RETURN LEXICON("VALID",TRUE,"RETRO",-best["ERR"]/slope).
}

// Estimate the root of actual powered capture residual versus downfield.
// Reject noisy/reversed slopes, and bound extrapolation to three current
// residuals. Native probes and a fresh full forecast still own acceptance.
LOCAL FUNCTION _targetPoweredStepAim {
    PARAMETER solved.
    PARAMETER modelAim.
    PARAMETER previousDownfield.
    PARAMETER previousResidual.
    PARAMETER hasHistory.
    PARAMETER localTolerance IS 0.
    LOCAL result IS LEXICON("AIM",modelAim,"MODE","model","SLOPE",0).
    // Near the actual capture goal, polish that goal directly. A secant
    // extrapolation can consume the remaining trials chasing a moving aim.
    IF localTolerance > 0 AND ABS(solved["ERR"]) <= 2*localTolerance {
        SET result["MODE"] TO "local". RETURN result.
    }
    IF NOT hasHistory { RETURN result. }
    LOCAL changeDownfield IS solved["DOWNFIELD"]-previousDownfield.
    LOCAL changeResidual IS solved["ERR"]-previousResidual.
    IF ABS(changeDownfield) < 250 OR ABS(changeResidual) < 250 { RETURN result. }
    LOCAL slope IS changeResidual/changeDownfield.
    IF NOT (slope >= 0.1 AND slope <= 2) { RETURN result. }
    LOCAL maxShift IS 3*ABS(solved["ERR"]).
    SET result["AIM"] TO MAX(250,solved["DOWNFIELD"]
        + MAX(-maxShift,MIN(maxShift,-solved["ERR"]/slope))).
    SET result["MODE"] TO "secant".
    SET result["SLOPE"] TO slope.
    RETURN result.
}

// With cross-track already controlled and powered capture close to its
// goal, a small retrograde change needs one probe and one trial. Do not
// spend two probes chasing exact cross-track zero with timing/normal.
LOCAL FUNCTION _targetDeorbitLocalAlongTrack {
    PARAMETER best.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    IF LANDING_POWERED_LEAD <= 0 OR NOT best["VALID"] OR NOT best["HAS_IMPACT"] { RETURN FALSE. }
    LOCAL crossLimit IS _targetDeorbitCrossAuthority(best).
    IF TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM > 0 {
        SET crossLimit TO MIN(crossLimit,1000*TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM).
    }
    RETURN ABS(best["ERR"]) <= MAX(250,maxDownfield-minDownfield)
        AND best["CROSS"] <= crossLimit
        AND (best["DOWNFIELD"] < minDownfield OR best["DOWNFIELD"] > maxDownfield).
}

LOCAL FUNCTION _targetDeorbitPolishAlongTrack {
    PARAMETER best.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER desiredDownfield.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    PARAMETER minDv.
    PARAMETER maxDv.
    PARAMETER trialLimit.
    IF ABORT OR _deorbitEvaluations+2 > trialLimit { RETURN best. }
    LOCAL probeDv IS MIN(0.25,maxDv-best["RETRO"]).
    IF probeDv < 0.01 { SET probeDv TO -MIN(0.25,best["RETRO"]-minDv). }
    IF ABS(probeDv) < 0.01 { RETURN best. }
    LOCAL probe IS _evalGeometricDeorbitNode(best["UT"],best["RETRO"]+probeDv,
        targetLat,targetLng,minLead,desiredDownfield,best["NORMAL"]).
    LOCAL correction IS _targetDeorbitRetroCorrection(best,probe,probeDv,minDownfield,maxDownfield).
    IF NOT correction["VALID"] { RETURN best. }
    LOCAL stepDv IS MAX(minDv-best["RETRO"],MIN(maxDv-best["RETRO"],
        MAX(-1,MIN(1,correction["RETRO"])))).
    FOR fraction IN LIST(1,0.5,0.25) {
        IF ABORT OR _deorbitEvaluations >= trialLimit { BREAK. }
        LOCAL trial IS _evalGeometricDeorbitNode(best["UT"],best["RETRO"]+stepDv*fraction,
            targetLat,targetLng,minLead,desiredDownfield,best["NORMAL"]).
        IF trial["VALID"] AND trial["HAS_IMPACT"]
                AND trial["CROSS"] <= _targetDeorbitCrossAuthority(trial)
                AND _targetDeorbitMerit(trial,minDownfield,maxDownfield)
                    < _targetDeorbitMerit(best,minDownfield,maxDownfield) {
            mLogDetail("STATS deorbit local-polish retroDelta=" + stepDv*fraction
                + " residualM=" + trial["ERR"] + " crossM=" + trial["CROSS"]
                + " evaluations=" + _deorbitEvaluations).
            RETURN trial.
        }
    }
    RETURN best.
}

LOCAL FUNCTION _refineDeorbitFootprint {
    PARAMETER base.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER desiredDownfield.
    PARAMETER minDownfield.
    PARAMETER maxDownfield.
    PARAMETER minDv.
    PARAMETER maxDv.
    PARAMETER reserveTrials IS 0.
    PARAMETER maxAcceptedSteps IS 0.
    LOCAL trialLimit IS MAX(0,TARGET_DEORBIT_MAX_EVALUATIONS-MAX(0,reserveTrials)).
    LOCAL best IS base.
    IF _targetDeorbitLocalAlongTrack(best,minDownfield,maxDownfield) {
        LOCAL polished IS _targetDeorbitPolishAlongTrack(best,targetLat,targetLng,minLead,
            desiredDownfield,minDownfield,maxDownfield,minDv,maxDv,trialLimit).
        IF polished["RETRO"] <> best["RETRO"] {
            SET best TO polished.
            IF maxAcceptedSteps > 0 OR _targetDeorbitRefineDone(best,minDownfield,maxDownfield) { RETURN best. }
        }
    }
    LOCAL admissible IS LEXICON("VALID", FALSE).
    IF _targetDeorbitSolutionAccepted(base, minDownfield, maxDownfield) { SET admissible TO base. }
    LOCAL originalUT IS base["UT"].
    LOCAL acceptedSteps IS 0.
    LOCAL capDv IS MAX(0, TARGET_DEORBIT_NORMAL_DV_CAP).
    // Try free timing changes before spending normal dV. Native finite
    // differences measure both residuals and the game's normal sign.
    FOR mode IN LIST("TIME", "NORMAL") {
        IF mode = "TIME" OR capDv > 0 {
            LOCAL iter IS 0.
            UNTIL iter >= 3 OR ABORT OR _deorbitEvaluations + 3 > trialLimit {
                IF _targetDeorbitRefineDone(best, minDownfield, maxDownfield) { RETURN best. }
                LOCAL retroProbe IS MIN(1, maxDv - best["RETRO"]).
                IF retroProbe < 0.01 { SET retroProbe TO -MIN(1, best["RETRO"] - minDv). }
                IF ABS(retroProbe) < 0.01 { BREAK. }
                LOCAL otherProbe IS 5.
                IF mode = "NORMAL" {
                    SET otherProbe TO MIN(1, capDv - best["NORMAL"]).
                    IF otherProbe < 0.01 { SET otherProbe TO -MIN(1, capDv + best["NORMAL"]). }
                } ELSE {
                    SET otherProbe TO MIN(5, originalUT + 120 - best["UT"]).
                    IF otherProbe < 0.01 {
                        SET otherProbe TO -MIN(5, best["UT"] - MAX(originalUT - 120, TIME:SECONDS + minLead + 1)).
                    }
                }
                IF ABS(otherProbe) < 0.01 { BREAK. }
                LOCAL retro IS _evalGeometricDeorbitNode(best["UT"], best["RETRO"] + retroProbe,
                    targetLat, targetLng, minLead, desiredDownfield, best["NORMAL"]).
                LOCAL otherUT IS best["UT"].
                LOCAL otherNormal IS best["NORMAL"].
                IF mode = "NORMAL" { SET otherNormal TO otherNormal + otherProbe. }
                ELSE { SET otherUT TO otherUT + otherProbe. }
                LOCAL other IS _evalGeometricDeorbitNode(otherUT, best["RETRO"],
                    targetLat, targetLng, minLead, desiredDownfield, otherNormal).
                IF NOT retro["VALID"] OR NOT other["VALID"] { BREAK. }
                LOCAL correction IS _targetDeorbitCorrection(best["ERR"], best["SIGNED_CROSS"],
                    (retro["ERR"] - best["ERR"]) / retroProbe,
                    (other["ERR"] - best["ERR"]) / otherProbe,
                    (retro["SIGNED_CROSS"] - best["SIGNED_CROSS"]) / retroProbe,
                    (other["SIGNED_CROSS"] - best["SIGNED_CROSS"]) / otherProbe).
                LOCAL stepMethod IS "coupled".
                IF NOT correction["VALID"] AND mode = "NORMAL" {
                    SET correction TO _targetDeorbitNormalCorrection(best,other,otherProbe,minDownfield,maxDownfield).
                    SET stepMethod TO "normal-only".
                }
                IF NOT correction["VALID"] {
                    LOCAL retroCorrection IS _targetDeorbitRetroCorrection(best,retro,retroProbe,minDownfield,maxDownfield).
                    IF retroCorrection["VALID"] {
                        SET correction TO LEXICON("VALID",TRUE,"RETRO",retroCorrection["RETRO"],"OTHER",0).
                        SET stepMethod TO "retro-only".
                    }
                }
                IF NOT correction["VALID"] {
                    mLogDetail("STATS deorbit refine-stop mode=" + mode + " reason=singular-response"
                        + " downfieldM=" + ROUND(best["DOWNFIELD"],0) + " crossM=" + ROUND(best["CROSS"],0)
                        + " retroDownfieldDelta=" + (retro["DOWNFIELD"]-best["DOWNFIELD"])
                        + " otherDownfieldDelta=" + (other["DOWNFIELD"]-best["DOWNFIELD"])
                        + " otherCrossDelta=" + (other["SIGNED_CROSS"]-best["SIGNED_CROSS"])).
                    BREAK.
                }
                LOCAL deltaRetro IS correction["RETRO"].
                LOCAL deltaOther IS correction["OTHER"].
                IF ABS(deltaRetro) < 0.001 AND ABS(deltaOther) < 0.001 { BREAK. }
                LOCAL otherLimit IS 60.
                IF mode = "NORMAL" { SET otherLimit TO 5. }
                // Scale the complete Newton direction to the trust region
                // and original bounds without changing its direction.
                LOCAL scale IS MIN(1, MIN(10 / MAX(0.001, ABS(deltaRetro)), otherLimit / MAX(0.001, ABS(deltaOther)))).
                IF deltaRetro > 0 { SET scale TO MIN(scale, (maxDv - best["RETRO"]) / deltaRetro). }
                IF deltaRetro < 0 { SET scale TO MIN(scale, (minDv - best["RETRO"]) / deltaRetro). }
                LOCAL otherValue IS best["NORMAL"].
                LOCAL otherMin IS -capDv.
                LOCAL otherMax IS capDv.
                IF mode = "TIME" {
                    SET otherValue TO best["UT"].
                    SET otherMin TO MAX(originalUT - 120, TIME:SECONDS + minLead + 1).
                    SET otherMax TO originalUT + 120.
                }
                IF deltaOther > 0 { SET scale TO MIN(scale, (otherMax - otherValue) / deltaOther). }
                IF deltaOther < 0 { SET scale TO MIN(scale, (otherMin - otherValue) / deltaOther). }
                LOCAL improved IS FALSE.
                IF scale >= 0.0001 {
                    FOR fraction IN LIST(1, 0.5, 0.25) {
                        IF ABORT OR _deorbitEvaluations >= trialLimit { BREAK. }
                        LOCAL trialUT IS best["UT"].
                        LOCAL trialNormal IS best["NORMAL"].
                        IF mode = "NORMAL" { SET trialNormal TO trialNormal + deltaOther * scale * fraction. }
                        ELSE { SET trialUT TO trialUT + deltaOther * scale * fraction. }
                        LOCAL trial IS _evalGeometricDeorbitNode(trialUT,
                            best["RETRO"] + deltaRetro * scale * fraction,
                            targetLat, targetLng, minLead, desiredDownfield, trialNormal).
                        IF _targetDeorbitMerit(trial, minDownfield, maxDownfield)
                                < _targetDeorbitMerit(best, minDownfield, maxDownfield)
                                AND (stepMethod <> "retro-only" OR trial["CROSS"] <= _targetDeorbitCrossAuthority(trial)) {
                            SET best TO trial.
                            SET improved TO TRUE.
                            BREAK.
                        }
                    }
                }
                IF NOT improved AND mode = "NORMAL" AND stepMethod = "coupled" {
                    LOCAL normalCorrection IS _targetDeorbitNormalCorrection(best,other,otherProbe,minDownfield,maxDownfield).
                    IF normalCorrection["VALID"] {
                        SET stepMethod TO "normal-only".
                        LOCAL normalStep IS MAX(-capDv-best["NORMAL"],MIN(capDv-best["NORMAL"],
                            MAX(-5,MIN(5,normalCorrection["OTHER"])))).
                        IF ABS(normalStep) >= 0.001 {
                            FOR fraction IN LIST(1,0.5,0.25) {
                                IF ABORT OR _deorbitEvaluations >= trialLimit { BREAK. }
                                LOCAL trial IS _evalGeometricDeorbitNode(best["UT"],best["RETRO"],
                                    targetLat,targetLng,minLead,desiredDownfield,best["NORMAL"]+normalStep*fraction).
                                IF _targetDeorbitMerit(trial,minDownfield,maxDownfield)
                                        < _targetDeorbitMerit(best,minDownfield,maxDownfield) {
                                    SET best TO trial.
                                    SET improved TO TRUE.
                                    BREAK.
                                }
                            }
                        }
                    }
                }
                IF NOT improved AND stepMethod <> "retro-only" {
                    LOCAL retroCorrection IS _targetDeorbitRetroCorrection(best,retro,retroProbe,minDownfield,maxDownfield).
                    IF retroCorrection["VALID"] {
                        SET stepMethod TO "retro-only".
                        LOCAL retroStep IS MAX(minDv-best["RETRO"],MIN(maxDv-best["RETRO"],
                            MAX(-10,MIN(10,retroCorrection["RETRO"])))).
                        FOR fraction IN LIST(1,0.5,0.25) {
                            IF ABORT OR _deorbitEvaluations >= trialLimit { BREAK. }
                            LOCAL trial IS _evalGeometricDeorbitNode(best["UT"],best["RETRO"]+retroStep*fraction,
                                targetLat,targetLng,minLead,desiredDownfield,best["NORMAL"]).
                            IF trial["VALID"] AND trial["HAS_IMPACT"]
                                    AND trial["CROSS"] <= _targetDeorbitCrossAuthority(trial)
                                    AND _targetDeorbitMerit(trial,minDownfield,maxDownfield)
                                        < _targetDeorbitMerit(best,minDownfield,maxDownfield) {
                                SET best TO trial.
                                SET improved TO TRUE.
                                BREAK.
                            }
                        }
                    }
                }
                IF NOT improved {
                    mLogDetail("STATS deorbit refine-stop mode=" + mode + " reason=no-improving-step method=" + stepMethod
                        + " downfieldM=" + ROUND(best["DOWNFIELD"],0) + " crossM=" + ROUND(best["CROSS"],0)
                        + " retro=" + best["RETRO"] + " normal=" + best["NORMAL"]
                        + " retroDownfieldDelta=" + (retro["DOWNFIELD"]-best["DOWNFIELD"])
                        + " otherDownfieldDelta=" + (other["DOWNFIELD"]-best["DOWNFIELD"])
                        + " otherCrossDelta=" + (other["SIGNED_CROSS"]-best["SIGNED_CROSS"])).
                    BREAK.
                }
                IF _targetDeorbitSolutionAccepted(best, minDownfield, maxDownfield) {
                    IF NOT admissible["VALID"] { SET admissible TO best. }
                    ELSE IF best["CROSS"] < admissible["CROSS"] { SET admissible TO best. }
                }
                mLogDetail("STATS deorbit step mode=" + mode + " ut=" + ROUND(best["UT"],1)
                    + " retro=" + ROUND(best["RETRO"],2) + " normal=" + ROUND(best["NORMAL"],2)
                    + " downfieldM=" + ROUND(best["DOWNFIELD"],0)
                    + " crossM=" + ROUND(best["CROSS"],0) + " evaluations=" + _deorbitEvaluations
                    + " method=" + stepMethod).
                SET acceptedSteps TO acceptedSteps+1.
                IF maxAcceptedSteps > 0 AND acceptedSteps >= maxAcceptedSteps { RETURN best. }
                SET iter TO iter + 1.
            }
        }
    }
    IF admissible["VALID"] { RETURN admissible. }
    RETURN best.
}

LOCAL FUNCTION _evalGeometricDeorbitNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER minLead.
    PARAMETER desiredDownfield.
    PARAMETER normalDv IS 0.

    IF ABORT OR burnUT <= TIME:SECONDS + minLead
            OR SQRT(retroDv ^ 2 + normalDv ^ 2) > SHIP:DELTAV:VACUUM
            OR _deorbitEvaluations >= TARGET_DEORBIT_MAX_EVALUATIONS {
        RETURN LEXICON("VALID", FALSE, "HAS_IMPACT", FALSE).
    }
    SET _deorbitEvaluations TO _deorbitEvaluations + 1.
    UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0. }
    LOCAL nd IS _planRetroNode(burnUT, retroDv, normalDv).
    WAIT 0.5.
    LOCAL result IS _readGeometricDeorbitNode(nd,
        targetLat, targetLng, desiredDownfield).
    REMOVE nd.
    RETURN result.
}

LOCAL FUNCTION _readGeometricDeorbitNode {
    PARAMETER nd.
    PARAMETER targetLat.
    PARAMETER targetLng.
    PARAMETER desiredDownfield.
    LOCAL result IS LEXICON(
        "VALID", FALSE,
        "UT", nd:TIME,
        "DV", nd:DELTAV:MAG,
        "RETRO", ABS(nd:PROGRADE),
        "NORMAL", nd:NORMAL,
        "DIST", 999999999,
        "DOWNFIELD", -999999999,
        "CROSS", 999999999,
        "ERR", 999999999,
        "PE", 999999999,
        "ANGLE", -1,
        "HAS_IMPACT", FALSE,
        "LAT", 0,
        "LNG", 0,
        "TTI", 0
    ).

    SET result["PE"] TO nd:ORBIT:PERIAPSIS.
    IF ADDONS:TR:HASIMPACT {
        LOCAL impactPos IS ADDONS:TR:IMPACTPOS.
        LOCAL impactUT IS TIME:SECONDS + ADDONS:TR:TIMETILLIMPACT.
        IF impactUT <= nd:TIME { RETURN result. }
        LOCAL offset IS lmSurfaceTrackOffset(targetLat, targetLng,
            impactPos:LAT, impactPos:LNG, lmGroundVelocityAt(impactUT)).
        IF NOT offset["VALID"] { RETURN result. }
        SET result["HAS_IMPACT"] TO TRUE.
        SET result["LAT"] TO impactPos:LAT.
        SET result["LNG"] TO impactPos:LNG.
        SET result["DIST"] TO offset["DIST"].
        SET result["DOWNFIELD"] TO offset["DOWNFIELD"].
        SET result["CROSS"] TO offset["CROSS"].
        SET result["SIGNED_CROSS"] TO offset["SIGNED_CROSS"].
        SET result["ERR"] TO offset["DOWNFIELD"] - desiredDownfield.
        SET result["ANGLE"] TO _nodeImpactAngle(impactUT).
        // Lateral guidance starts AFTER the burn, not while waiting for it.
        SET result["TTI"] TO impactUT - nd:TIME.
        SET result["VALID"] TO TRUE.
    }
    RETURN result.
}

LOCAL FUNCTION _nodeImpactAngle {
    PARAMETER impactUT.
    LOCAL impactVel IS lmGroundVelocityAt(impactUT).
    IF impactVel:MAG < 0.01 { RETURN -1. }
    LOCAL impactUp IS lmGroundPositionAt(impactUT):NORMALIZED.

    // Descent FPA magnitude: 0 is horizontal, 90 is vertical.
    LOCAL sinFpa IS VDOT(impactVel:NORMALIZED, impactUp).

    RETURN ABS(ARCSIN(MAX(-1, MIN(1, sinFpa)))).
}

LOCAL FUNCTION _planRetroNode {
    PARAMETER burnUT.
    PARAMETER retroDv.
    PARAMETER normalDv IS 0.

    LOCAL nd IS NODE(burnUT, 0, normalDv, -ABS(retroDv)).
    ADD nd.
    RETURN nd.
}

LOCAL FUNCTION _logDeorbitNode {
    PARAMETER label.
    PARAMETER nd.

    mLog(label + ": N("
        + ROUND(nd:PROGRADE,3) + " pro, "
        + ROUND(nd:NORMAL,3) + " norm, "
        + ROUND(nd:RADIALOUT,3) + " rad, "
        + ROUND(nd:TIME,3) + " UT)"
        + " dv=" + ROUND(nd:DELTAV:MAG,2)
        + " eta=" + ROUND(nd:ETA,1) + "s.").
}

LOCAL FUNCTION _targetDeorbitMinLead {
    LOCAL minLead IS 60.
    IF TARGET_DEORBIT_MIN_LEAD > 0 {
        SET minLead TO TARGET_DEORBIT_MIN_LEAD.
    }
    RETURN minLead.
}

GLOBAL FUNCTION targetReachable {
    PARAMETER targetLat.
    LOCAL inc IS SHIP:ORBIT:INCLINATION.
    IF inc > 90 { SET inc TO 180 - inc. }
    RETURN ABS(targetLat) <= inc + 0.5.
}
