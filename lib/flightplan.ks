// ============================================================
// flightplan.ks - Shared flight-plan and checklist displays
// (0:/lib/flightplan.ks)
//
// Renders a bordered mission-plan card in the kOS terminal.
// Deliberately NEVER clears the screen: the card scrolls inline
// so boot messages and prior output stay in the scrollback.
//
// The card is composed by the craft scripts from these pieces,
// in any order (each piece draws its own borders):
//   flightPlanTitle(title, sub)   top edge + heading
//   flightPlanIdentity()          code/core/mission rows
//   flightPlanSection(name)       divider with embedded label
//   flightPlanRow(label, value)   aligned key : value row
//   flightPlanSequence(seq)       numbered phases with progress
//                                 markers ([x] done, [>] current)
//                                 + closing edge
//   flightPlanChecklist(...)      boxed checklist, waits for key
//
// Width adapts to the terminal (clamped 36..56 columns of
// content) and every row truncates rather than wrap-breaking
// the border.
// ============================================================

@LAZYGLOBAL OFF.

// --- Config defaults owned by this file ---
GLOBAL MISSION_NAME IS "".
GLOBAL PAYLOADS IS "".
GLOBAL PARKING_ALT IS 80000.
GLOBAL LAUNCH_INCLINATION IS 0.
GLOBAL CAPTURE_PE IS -1.
GLOBAL TARGET_PE IS -1.
GLOBAL TARGET_AP IS -1.
GLOBAL SHAPE_PE IS -1.
GLOBAL SHAPE_AP IS -1.


// Inner content width (between the "| " and " |").
LOCAL FUNCTION _fpInner {
    RETURN MAX(36, MIN(TERMINAL:WIDTH - 6, 56)).
}

// A run of `ch` of length n (kOS has no string repeat).
LOCAL FUNCTION _fpRun {
    PARAMETER ch, n.
    RETURN "":PADLEFT(MAX(0, n)):REPLACE(" ", ch).
}

// Bordered text row, truncated to fit.
LOCAL FUNCTION _fpText {
    PARAMETER s.
    LOCAL w IS _fpInner().
    IF s:LENGTH > w { SET s TO s:SUBSTRING(0, w - 1) + "~". }
    PRINT "  | " + s:PADRIGHT(w) + " |".
}

LOCAL FUNCTION _fpEdge {
    PARAMETER ch.
    PRINT "  +" + _fpRun(ch, _fpInner() + 2) + "+".
}

// ------------------------------------------------------------
// Public pieces
// ------------------------------------------------------------

GLOBAL FUNCTION flightPlanLine {
    _fpEdge("=").
}

GLOBAL FUNCTION flightPlanRule {
    _fpEdge("-").
}

GLOBAL FUNCTION flightPlanTitle {
    PARAMETER title.
    PARAMETER subtitle IS "".

    flightPlanLine().
    _fpText(title).
    IF subtitle <> "" {
        _fpText(subtitle).
    }
    flightPlanRule().
}

GLOBAL FUNCTION flightPlanSection {
    PARAMETER title.
    LOCAL w IS _fpInner().
    LOCAL label IS "-[ " + title + " ]".
    IF label:LENGTH > w { SET label TO label:SUBSTRING(0, w). }
    PRINT "  +" + label + _fpRun("-", w + 2 - label:LENGTH) + "+".
}

GLOBAL FUNCTION flightPlanRow {
    PARAMETER label.
    PARAMETER value.
    _fpText(label:PADRIGHT(13) + ": " + value).
}

GLOBAL FUNCTION flightPlanIdentity {
    LOCAL missionName IS MISSION_NAME.
    IF missionName = "" { SET missionName TO stateGet("mission_name", ""). }
    IF missionName <> "" { flightPlanRow("MISSION", missionName). }
    flightPlanRow("CODE", codeVersion()).
    IF CORE:TAG <> "" { flightPlanRow("CORE", CORE:TAG). }
    flightPlanRow("FREE", ROUND(CORE:VOLUME:FREESPACE, 0) + " bytes").
    IF DEFINED MISSION {
        flightPlanRow("TARGET", getTarget()).
        IF PAYLOADS <> "" {
            flightPlanRow("PAYLOADS", PAYLOADS).
        }
    }
}

// Numbered phase list with live progress markers:
//   [x] flown   [>] current (resume point)   [ ] ahead
// Closes the card with the bottom edge.
GLOBAL FUNCTION flightPlanSequence {
    PARAMETER seq.

    LOCAL cur IS stateGet("phase", "").
    LOCAL curIdx IS -1.
    FROM { LOCAL i IS 0. } UNTIL i >= seq:LENGTH STEP { SET i TO i + 1. } DO {
        IF curIdx < 0 AND seq[i] = cur { SET curIdx TO i. }
    }

    FROM { LOCAL i IS 0. } UNTIL i >= seq:LENGTH STEP { SET i TO i + 1. } DO {
        LOCAL mark IS "[ ]".
        IF curIdx >= 0 {
            IF i < curIdx { SET mark TO "[x]". }
            ELSE IF i = curIdx { SET mark TO "[>]". }
        }
        _fpText(mark + " " + ("" + (i + 1)):PADLEFT(2) + ". " + seq[i]).
    }
    IF curIdx > 0 {
        flightPlanRule().
        _fpText("RESUME at " + cur + " (" + (curIdx + 1) + "/" + seq:LENGTH + ")").
    }
    flightPlanLine().
}

// Generic config dump, grouped by key prefix: keys sharing a prefix
// before the first underscore (CAPTURE_*, SHAPE_*, ...) become a
// section with the prefix stripped from each row; loners gather
// under CONFIG. Sequence/lib plumbing keys are skipped. Lets any
// craft show its full effective mission config without curating
// rows by hand.
GLOBAL FUNCTION flightPlanConfig {
    IF PARKING_ALT > 0 { flightPlanRow("PARK ALT", ROUND(PARKING_ALT/1000,0) + " km"). }
    IF LAUNCH_INCLINATION <> 0 { flightPlanRow("LAUNCH INC", LAUNCH_INCLINATION + " deg"). }
    IF CAPTURE_PE >= 0 { flightPlanRow("CAPTURE PE", ROUND(CAPTURE_PE/1000,0) + " km"). }
    IF TARGET_PE >= 0 { flightPlanRow("TARGET PE", ROUND(TARGET_PE/1000,0) + " km"). }
    IF TARGET_AP >= 0 { flightPlanRow("TARGET AP", ROUND(TARGET_AP/1000,0) + " km"). }
    IF SHAPE_PE >= 0 { flightPlanRow("SHAPE PE", ROUND(SHAPE_PE/1000,0) + " km"). }
    IF SHAPE_AP >= 0 { flightPlanRow("SHAPE AP", ROUND(SHAPE_AP/1000,0) + " km"). }
}

GLOBAL FUNCTION flightPlanChecklist {
    PARAMETER title.
    PARAMETER items.
    PARAMETER envRows IS LIST().
    PARAMETER promptText IS "Press any key when ready".

    flightPlanTitle(title, SHIP:NAME).
    FOR item IN items {
        _fpText("[ ] " + item).
    }
    IF envRows:LENGTH > 0 {
        flightPlanSection("ENVIRONMENT").
        FOR row IN envRows {
            _fpText(row).
        }
    }
    flightPlanRule().
    _fpText(">> " + promptText).
    flightPlanLine().

    TERMINAL:INPUT:GETCHAR().
    PRINT "  Clearance given.".
}
