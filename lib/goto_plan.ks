// ============================================================
// goto_plan.ks  —  Universal destination routing
// (0:/lib/goto_plan.ks)
//
// "goto(thing, options)": given any destination — body or vessel,
// parent, sibling, child, or in another planetary system — build
// the phase SEQUENCE and mission_cfg_* values for the next hop
// toward it, reusing the standard mission machinery (bands,
// reload-on-band-change, state resume) for progressive loading.
//
// The planner is HOP-based: each call plans exactly one SOI
// transition (or the final operations when already at the goal).
// Multi-hop routes (sibling moons, moons of other planets, grand
// tour legs) end their hop sequence with the GOTO phase, which
// replans from wherever the ship actually is and requests a
// reboot — so the sequence never needs duplicate phase names and
// every leg loads only its own libraries.
//
// Hop shapes:
//   at goal body            SHAPE, DONE
//   vessel in this SOI      RDV, DONE
//   down/lateral (XING ok)  XING, BPLANE, COAST_1HALF,
//                           REFINE_BPLANE, COAST_2HALF, CAPTURE, then
//                           SHAPE|RDV, DONE (final) or GOTO
//   up one level            ESCAPE, COAST, then
//                           SHAPE|RDV, DONE (final) or GOTO
//
// XING covers two topologies natively via planTransfer:
//   - target orbits the current body          (local transfer)
//   - target orbits the current body's parent (Lambert ejection)
// Everything else climbs with ESCAPE until one of those applies.
//
// State consumed:
//   goto_dest             — final destination name (set by cmd/goto)
//   mission_cfg_SHAPE_*   — requested final orbit elements
// State produced per hop:
//   target, phase, mission_cfg_SEQUENCE, and hop-scoped
//   CAPTURE_*/ESCAPE_*/TARGET_*/RENDEZVOUS_TARGET cfg keys.
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL CAPTURE_PE IS -1.
GLOBAL CAPTURE_INC IS -1.
GLOBAL CAPTURE_LAN IS -1.
GLOBAL CAPTURE_AOP IS -1.
GLOBAL CAPTURE_DIR IS "".
GLOBAL ESCAPE_PE IS -1.
GLOBAL ESCAPE_LAN IS -1.
GLOBAL ESCAPE_AOP IS -1.
GLOBAL TARGET_PE IS -1.
GLOBAL TARGET_AP IS -1.
GLOBAL SHAPE_PE IS -1.
GLOBAL SHAPE_AP IS -1.
GLOBAL SHAPE_INC IS -1.
GLOBAL SHAPE_LAN IS -1.


LOCAL FUNCTION _gotoFindBody {
    PARAMETER name.
    LOCAL allBodies IS LIST().
    LIST BODIES IN allBodies.
    FOR bod IN allBodies {
        IF bod:NAME = name { RETURN bod. }
    }
    RETURN 0.
}

LOCAL FUNCTION _gotoFindVessel {
    PARAMETER name.
    LOCAL all IS LIST().
    LIST TARGETS IN all.
    FOR ves IN all {
        IF ves:NAME = name { RETURN ves. }
    }
    RETURN 0.
}

// Is candidate an ancestor body of x (x somewhere inside its SOI tree)?
LOCAL FUNCTION _gotoIsAncestor {
    PARAMETER candidate, x.
    LOCAL p IS x.
    UNTIL NOT p:HASBODY {
        SET p TO p:BODY.
        IF p = candidate { RETURN TRUE. }
    }
    RETURN FALSE.
}

// The direct child of cur that leads toward goal (goal must be a
// descendant of cur).
LOCAL FUNCTION _gotoChildToward {
    PARAMETER cur, goal.
    LOCAL p IS goal.
    UNTIL p:BODY = cur {
        SET p TO p:BODY.
    }
    RETURN p.
}

// Lowest safe periapsis for a body: clear of atmosphere + margin.
LOCAL FUNCTION _gotoSafePe {
    PARAMETER bod.
    IF bod:ATM:EXISTS { RETURN bod:ATM:HEIGHT + 25000. }
    RETURN 25000.
}

// Requested final orbit element from effective globals, or fallback.
LOCAL FUNCTION _gotoShapeNum {
    PARAMETER key, fallback.
    IF key = "PE" AND SHAPE_PE >= 0 { RETURN SHAPE_PE. }
    IF key = "AP" AND SHAPE_AP >= 0 { RETURN SHAPE_AP. }
    IF key = "INC" AND SHAPE_INC >= 0 { RETURN SHAPE_INC. }
    IF key = "LAN" AND SHAPE_LAN >= 0 { RETURN SHAPE_LAN. }
    RETURN fallback.
}

// ============================================================
// gotoBuildPlan — plan the next hop toward destName.
// Returns 0 on resolution failure, else:
//   LEX("sequence" LIST, "target" name, "cfg" LEXICON,
//       "final" bool, "summary" string)
// ============================================================
GLOBAL FUNCTION gotoBuildPlan {
    PARAMETER destName.

    LOCAL destBody IS _gotoFindBody(destName).
    LOCAL destVessel IS 0.
    IF destBody = 0 {
        SET destVessel TO _gotoFindVessel(destName).
        IF destVessel = 0 {
            mLogError("GOTO: unknown destination '" + destName + "'.").
            RETURN 0.
        }
    }
    LOCAL isVessel IS destVessel <> 0.
    LOCAL goalBody IS destBody.
    IF isVessel { SET goalBody TO destVessel:BODY. }
    LOCAL cur IS SHIP:BODY.

    LOCAL seq IS LIST().
    LOCAL cfg IS LEXICON().
    LOCAL hopTarget IS "".
    LOCAL final IS FALSE.

    // --- Already at the goal SOI: final operations only ---
    IF goalBody = cur {
        SET final TO TRUE.
        SET hopTarget TO cur:NAME.
        IF isVessel {
            SET seq TO LIST("RDV", "DONE").
            cfg:ADD("RENDEZVOUS_TARGET", destVessel:NAME).
        } ELSE {
            SET seq TO LIST("SHAPE", "DONE").
        }

    // --- Down or lateral: XING can plan it directly when the hop
    // body orbits the current body (local) or shares its parent
    // (Lambert ejection). Deeper goals hop to the child en route. ---
    } ELSE IF _gotoIsAncestor(cur, goalBody)
            OR (cur:HASBODY AND goalBody:HASBODY
                AND goalBody:BODY = cur:BODY) {
        LOCAL hopBody IS goalBody.
        IF _gotoIsAncestor(cur, goalBody) AND goalBody:BODY <> cur {
            SET hopBody TO _gotoChildToward(cur, goalBody).
        }
        SET hopTarget TO hopBody:NAME.
        SET final TO hopBody = goalBody.

        LOCAL capPe IS _gotoSafePe(hopBody).
        LOCAL capAp IS hopBody:SOIRADIUS * 0.3.
        IF final AND isVessel {
            SET capPe TO MAX(destVessel:ORBIT:PERIAPSIS, _gotoSafePe(hopBody) / 2).
            SET capAp TO destVessel:ORBIT:APOAPSIS.
            cfg:ADD("CAPTURE_INC", destVessel:ORBIT:INCLINATION).
            cfg:ADD("CAPTURE_LAN", destVessel:ORBIT:LAN).
            cfg:ADD("RENDEZVOUS_TARGET", destVessel:NAME).
        } ELSE IF final {
            SET capPe TO _gotoShapeNum("PE", capPe).
            SET capAp TO _gotoShapeNum("AP", capAp).
            IF SHAPE_INC >= 0 {
                cfg:ADD("CAPTURE_INC", _gotoShapeNum("INC", 0)).
            }
            IF SHAPE_LAN >= 0 {
                cfg:ADD("CAPTURE_LAN", _gotoShapeNum("LAN", 0)).
            }
        }
        cfg:ADD("CAPTURE_PE", capPe).
        cfg:ADD("TARGET_PE", capPe).
        cfg:ADD("TARGET_AP", capAp).

        SET seq TO LIST("XING", "BPLANE", "COAST_1HALF",
            "REFINE_BPLANE", "COAST_2HALF", "CAPTURE").
        IF final AND isVessel {
            seq:ADD("RDV"). seq:ADD("DONE").
        } ELSE IF final {
            seq:ADD("SHAPE"). seq:ADD("DONE").
        } ELSE {
            seq:ADD("GOTO").
        }

    // --- Up one level: minimal escape into the parent's SOI ---
    } ELSE {
        IF NOT cur:HASBODY {
            mLogError("GOTO: cannot route from " + cur:NAME
                + " to " + destName + " (no common ancestor path).").
            RETURN 0.
        }
        LOCAL parent IS cur:BODY.
        SET hopTarget TO parent:NAME.
        SET final TO goalBody = parent.

        LOCAL escPe IS MAX(_gotoSafePe(parent),
            cur:ORBIT:SEMIMAJORAXIS - parent:RADIUS).
        IF final AND isVessel {
            SET escPe TO destVessel:ORBIT:PERIAPSIS.
            cfg:ADD("RENDEZVOUS_TARGET", destVessel:NAME).
        } ELSE IF final {
            SET escPe TO _gotoShapeNum("PE", _gotoSafePe(parent)).
        }
        cfg:ADD("ESCAPE_PE", escPe).

        SET seq TO LIST("ESCAPE", "COAST").
        IF final AND isVessel {
            seq:ADD("RDV"). seq:ADD("DONE").
        } ELSE IF final {
            seq:ADD("SHAPE"). seq:ADD("DONE").
        } ELSE {
            seq:ADD("GOTO").
        }
    }

    LOCAL kindWord IS "hop".
    IF final { SET kindWord TO "final leg". }
    LOCAL summary IS kindWord + " -> " + hopTarget
        + "  [" + seq:JOIN(",") + "]"
        + "  (destination: " + destName + ")".

    RETURN LEX(
        "sequence", seq,
        "target", hopTarget,
        "cfg", cfg,
        "final", final,
        "summary", summary).
}

// ============================================================
// gotoCommitPlan — persist a hop plan into mission state.
// Clears hop-scoped keys from the previous leg first; never
// touches the operator's SHAPE_* final-orbit spec or goto_dest.
// ============================================================
GLOBAL FUNCTION gotoCommitPlan {
    PARAMETER plan.
    FOR key IN LIST(
        "CAPTURE_PE", "CAPTURE_INC", "CAPTURE_LAN", "CAPTURE_AOP",
        "CAPTURE_DIR", "ESCAPE_PE", "ESCAPE_LAN", "ESCAPE_AOP",
        "RENDEZVOUS_TARGET", "TARGET_PE", "TARGET_AP"
    ) {
        stateRemove("mission_cfg_" + key).
    }
    LOCAL cfg IS plan["cfg"].
    FOR key IN cfg:KEYS {
        stateSet("mission_cfg_" + key, cfg[key]).
    }
    stateSet("target", plan["target"]).
    stateSet("mission_cfg_SEQUENCE", plan["sequence"]).
    stateSet("phase", plan["sequence"][0]).
    mLog("GOTO plan committed: " + plan["summary"]).
}

// ============================================================
// phaseGoto — continuation phase. Reached at the end of an
// intermediate hop: replan from the current SOI and request a
// reboot so the next leg's band loads cleanly.
// ============================================================
GLOBAL FUNCTION phaseGoto {
    LOCAL dest IS stateGet("goto_dest", "").
    IF dest = "" {
        mLogError("GOTO phase reached but goto_dest is not set — ending mission.").
        stateSet("phase", "DONE").
        RETURN.
    }

    LOCAL plan IS gotoBuildPlan(dest).
    IF plan = 0 {
        mLogError("GOTO: replanning toward " + dest + " failed — operator needed.").
        yieldToPrompt().
        RETURN.
    }

    gotoCommitPlan(plan).
    LOCAL firstPhase IS plan["sequence"][0].
    stateSet("reload_required", "true").
    stateSet("reload_reason", "GOTO_HOP").
    stateSet("reload_next_phase", firstPhase).
    stateSet("reload_next_band", bootLibBandForPhase(firstPhase, firstPhase)).

    PRINT " ".
    PRINT "  GOTO: " + plan["summary"].
    PRINT "  Reboot this CPU to fly the next leg.".
    yieldToPrompt().
}
