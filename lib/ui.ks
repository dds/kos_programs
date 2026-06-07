// ============================================================
// ui.ks - Lightweight terminal presentation helpers
// ============================================================

GLOBAL FUNCTION uiLine {
    PRINT "  ==========================================".
}

GLOBAL FUNCTION uiRule {
    PRINT "  ------------------------------------------".
}

GLOBAL FUNCTION uiTitle {
    PARAMETER title.
    PARAMETER subtitle IS "".
    uiLine().
    PRINT "  " + title.
    IF subtitle <> "" {
        PRINT "  " + subtitle.
    }
    uiLine().
}

GLOBAL FUNCTION uiSection {
    PARAMETER title.
    PRINT " ".
    PRINT "  [" + title + "]".
    uiRule().
}

GLOBAL FUNCTION uiRow {
    PARAMETER label.
    PARAMETER value.
    PRINT "  " + label:PADRIGHT(13) + " : " + value.
}

GLOBAL FUNCTION uiPrompt {
    PARAMETER text.
    PRINT " ".
    PRINT "  >> " + text.
}
