// ============================================================
// arrival.ks — inspect, budget, preview, accept, or replan an arrival correction.
// Archive-only operator code; loads its own saved mission/band context.
// RUNPATH("0:/cmd/arrival.ks", "accept", 100).  // 100 km capture Ap
// RUNPATH("0:/cmd/arrival.ks", "budget", 100).  // 100 m/s further corrections
// RUNPATH("0:/cmd/arrival.ks", "plan").         // preview only, no burn
// ============================================================
@LAZYGLOBAL OFF.
PARAMETER action IS "review".
PARAMETER captureApKm IS -1.

LOCAL FUNCTION _cmdArrival {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().

    LOCAL FUNCTION _arrivalLoadContext {
        LOCAL phase IS stateGet("phase", "").
        IF phase <> "BPLANE" AND phase <> "REFINE_BPLANE" {
            PRINT "Arrival review requires BPLANE or REFINE_BPLANE.". RETURN FALSE.
        }
        LOCAL vehicle IS stateGet("vehicle", "").
        LOCAL mission IS stateGet("mission_id", "").
        IF vehicle = "" OR mission = "" {
            PRINT "Saved vehicle/mission missing; cannot load arrival context.". RETURN FALSE.
        }
        LOCAL hasLink IS HOMECONNECTION:ISCONNECTED.
        LOCAL craftScript IS bootResolveScript(vehicle, LIST("craft"), hasLink).
        IF craftScript = "" {
            PRINT "Saved craft script unavailable; cannot resume arrival.". RETURN FALSE.
        }
        // Follow normal boot ordering, without starting the phase machine:
        // profile for dependency planning, band libraries, then craft main.
        // boot_lib installs an empty default main, so the craft MUST run again.
        IF NOT bootApplyMissionConfig(vehicle, mission, hasLink) { RETURN FALSE. }
        bootLibLoadList(bootPlannedMissionLibs()).
        bootLibLoad(craftScript).
        bootLibLoad("resume").
        // Library/craft defaults must not erase fuel limits or accepted targets.
        // This also reapplies the persisted runtime overrides after the profile.
        IF NOT bootApplyMissionConfig(vehicle, mission, hasLink) { RETURN FALSE. }
        RETURN TRUE.
    }

    // Rewrite the full override file, replacing only the supplied keys.
    // Preserve unrelated runtime settings and use literals for offline reboots.
    LOCAL FUNCTION _arrivalWriteOverrides {
        PARAMETER values.
        LOCAL previous IS LIST().
        LOCAL path IS missionOverridePath().
        IF EXISTS(path) { SET previous TO OPEN(path):READALL:STRING:SPLIT(CHAR(10)). }
        LOCAL rewritten IS "1:/run/arrival_overrides.ks".
        IF EXISTS(rewritten) { DELETEPATH(rewritten). }
        FOR line IN previous {
            LOCAL keep IS TRUE.
            FOR key IN values:KEYS {
                IF line:TRIM:STARTSWITH("SET " + key + " TO ") { SET keep TO FALSE. }
            }
            IF keep AND line:TRIM <> "" { LOG line TO rewritten. }
        }
        FOR key IN values:KEYS {
            LOG "SET " + key + " TO " + configLiteral(values[key]) + "." TO rewritten.
        }
        COPYPATH(rewritten, path).
        DELETEPATH(rewritten).
        applyMissionOverrides().
    }

    LOCAL FUNCTION _bplaneWriteAcceptedTargets {
        PARAMETER pe, inc, apAlt.
        LOCAL values IS LEX("CAPTURE_PE", pe, "CAPTURE_INC", inc, "CAPTURE_DIR", "",
            "CAPTURE_LAN", -1, "TARGET_PE", pe, "TARGET_AP", apAlt,
            "CAPTURE_MIN_PE", MAX(BPLANE_REVIEW_MIN_PE, pe - BPLANE_PE_TOL),
            "CAPTURE_MAX_PE", pe + BPLANE_PE_TOL,
            "SHAPE_PE", pe, "SHAPE_AP", apAlt, "SHAPE_INC", inc, "SHAPE_LAN", -1).
        _arrivalWriteOverrides(values).
    }

    LOCAL FUNCTION _arrivalCommand {
        PARAMETER action IS "review", captureApKm IS -1.
        LOCAL phase IS stateGet("phase", "").
        IF phase <> "BPLANE" AND phase <> "REFINE_BPLANE" {
            PRINT "Arrival review requires BPLANE or REFINE_BPLANE.". RETURN.
        }
        IF action = "status" { bplaneArrivalStatus(). RETURN. }
        IF action = "budget" {
            // For this action the third argument is additional correction m/s,
            // not capture Ap. Changing the allowance never starts a burn.
            IF captureApKm <= 0 {
                PRINT "Budget action requires a positive additional correction allowance in m/s.". RETURN.
            }
            LOCAL values IS bplaneRecoveryBudgetValues(captureApKm).
            IF values:LENGTH = 0 { PRINT "No arrival target body.". RETURN. }
            _arrivalWriteOverrides(values).
            mLog("STATS bplane recovery-budget additionalDv=" + captureApKm
                + " totalCap=" + BPLANE_TRIM_TOTAL_DV_CAP
                + " captureReserve=" + BPLANE_CAPTURE_MARGIN).
            PRINT "Correction allowance saved. Capture/return reserves unchanged; no burn started.".
            PRINT "Use arrival action plan to preview a correction without executing it.".
            RETURN.
        }
        IF action = "plan" { bplanePreviewCorrection(). RETURN. }
        IF action = "replan" {
            IF ABORT { PRINT "Clear ABORT deliberately before replanning.". RETURN. }
            IF maneuverBurnInterrupted() {
                // Explicit operator replan of a correction, never an XING
                // departure. Use the flown orbit and keep the spent-dV ledger.
                bplaneArrivalStatus().
                mLogWarn("Discarding interrupted correction; replanning from the actual trajectory.").
                maneuverAcceptHandoff().
            }
            stateRemove("bplane_review").
            UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
            resumeMission(). RETURN.
        }
        LOCAL saved IS stateGet("bplane_review", LEXICON()).
        IF saved:LENGTH = 0 {
            PRINT "No retained candidate. Use arrival action replan to generate one.". RETURN.
        }
        IF action = "review" { bplanePauseForReview(). RETURN. }
        IF action <> "accept" { PRINT "Arrival actions: status, budget, plan, review, accept, replan.". RETURN. }
        IF NOT HASNODE { PRINT "Reviewed node missing; replan.". RETURN. }
        LOCAL nd IS NEXTNODE.
        IF NOT bplaneReviewMatches(saved, nd) {
            PRINT "Reviewed node changed; replan before acceptance.". RETURN.
        }
        IF nd:ETA < BPLANE_EXISTING_NODE_MIN_ETA OR ABORT OR maneuverBurnInterrupted() {
            PRINT "Node too late, ABORT set, or interrupted burn present; cannot accept.". RETURN.
        }
        LOCAL targetBody IS BODY(saved["target"]).
        LOCAL hit IS findArrivalPatch(nd, targetBody).
        IF hit = 0 { PRINT "Encounter missing; replan.". RETURN. }
        LOCAL patch IS hit["patch"].
        IF patch:PERIAPSIS < BPLANE_REVIEW_MIN_PE
                OR patch:PERIAPSIS >= targetBody:SOIRADIUS - targetBody:RADIUS {
            PRINT "Candidate periapsis is outside the review corridor; replan.". RETURN.
        }
        LOCAL apAlt IS MAX(TARGET_AP, patch:PERIAPSIS).
        IF captureApKm >= 0 { SET apAlt TO captureApKm * 1000. }
        IF apAlt < patch:PERIAPSIS OR apAlt >= targetBody:SOIRADIUS - targetBody:RADIUS {
            PRINT "Capture apoapsis must be at least Pe and below the SOI altitude.". RETURN.
        }
        IF BPLANE_CAPTURE_MARGIN >= 0 {
            LOCAL needed IS nd:DELTAV:MAG + bplaneCaptureCost(patch, targetBody, apAlt)
                + BPLANE_CAPTURE_MARGIN.
            IF needed > SHIP:DELTAV:VACUUM {
                PRINT "Selected capture Ap exceeds the fuel budget; candidate retained.".
                PRINT "Choose a higher Ap or use action replan.". RETURN.
            }
        }
        LOCAL phaseCap IS BPLANE_DV_CAP.
        IF phase = "REFINE_BPLANE" { SET phaseCap TO REFINE_BPLANE_DV_CAP. }
        LOCAL oldAp IS TARGET_AP.
        SET TARGET_AP TO apAlt.
        LOCAL allowed IS bplaneCorrectionAllowed(nd, targetBody, phaseCap, FALSE).
        SET TARGET_AP TO oldAp.
        IF NOT allowed { RETURN. }
        _bplaneWriteAcceptedTargets(patch:PERIAPSIS, patch:INCLINATION, apAlt).
        mLog("STATS bplane review decision=accepted PeKm=" + (CAPTURE_PE / 1000)
            + " inc=" + CAPTURE_INC + " captureApKm=" + (TARGET_AP / 1000)).
        stateRemove("bplane_review").
        // Normal phase execution revalidates budget/geometry and reserves cost
        // once before ignition; acceptance itself neither burns nor charges fuel.
        resumeMission().
    }

    IF _arrivalLoadContext() {
        _arrivalCommand(action, captureApKm).
    }
}

_cmdArrival().
