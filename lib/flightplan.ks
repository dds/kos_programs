// ============================================================
// flightplan.ks - Shared flight-plan and checklist displays
// ============================================================

GLOBAL FUNCTION flightPlanLine {
    PRINT "  ==========================================".
}

GLOBAL FUNCTION flightPlanRule {
    PRINT "  ------------------------------------------".
}

GLOBAL FUNCTION flightPlanTitle {
    PARAMETER title.
    PARAMETER subtitle IS "".

    CLEARSCREEN.
    flightPlanLine().
    PRINT "  " + title.
    IF subtitle <> "" {
        PRINT "  " + subtitle.
    }
    flightPlanLine().
}

GLOBAL FUNCTION flightPlanSection {
    PARAMETER title.
    PRINT " ".
    PRINT "  [" + title + "]".
    flightPlanRule().
}

GLOBAL FUNCTION flightPlanRow {
    PARAMETER label.
    PARAMETER value.
    PRINT "  " + label:PADRIGHT(13) + " : " + value.
}

GLOBAL FUNCTION flightPlanIdentity {
    IF DEFINED codeVersion {
        flightPlanRow("CODE", codeVersion()).
    }
    flightPlanRow("CORE", CORE:TAG).
    flightPlanRow("FREE", ROUND(CORE:VOLUME:FREESPACE,0) + " bytes").
    IF DEFINED MISSION {
        flightPlanRow("TARGET", MISSION["target"]).
        flightPlanRow("PAYLOADS", MISSION["payloads"]).
    }
}

GLOBAL FUNCTION flightPlanStorage {
    PRINT " ".
    IF DEFINED printStorageStatus {
        printStorageStatus().
    } ELSE {
        flightPlanSection("STORAGE").
        flightPlanRow("FREE", ROUND(CORE:VOLUME:FREESPACE,0) + " bytes").
        flightPlanRow("CAPACITY", ROUND(CORE:VOLUME:CAPACITY,0) + " bytes").
    }
}

GLOBAL FUNCTION flightPlanSequence {
    PARAMETER seq.

    LOCAL i IS 0.
    UNTIL i >= seq:LENGTH {
        LOCAL line IS "  ".
        LOCAL j IS i.
        UNTIL j >= seq:LENGTH OR line:LENGTH > 42 {
            IF j > i { SET line TO line + " > ". }
            SET line TO line + seq[j].
            SET j TO j + 1.
        }
        PRINT line.
        SET i TO j.
    }
}

GLOBAL FUNCTION flightPlanChecklist {
    PARAMETER title.
    PARAMETER items.
    PARAMETER envRows IS LIST().
    PARAMETER promptText IS "Press any key when ready".

    flightPlanTitle(title, SHIP:NAME).
    PRINT " ".
    FOR item IN items {
        PRINT "  [ ] " + item.
    }
    IF envRows:LENGTH > 0 {
        flightPlanSection("ENVIRONMENT").
        FOR row IN envRows {
            PRINT "  " + row.
        }
    }
    PRINT " ".
    PRINT "  >> " + promptText.

    TERMINAL:INPUT:GETCHAR().
    PRINT " ".
    PRINT "  Clearance given.".
}
