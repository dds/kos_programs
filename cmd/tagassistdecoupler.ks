// cmd/tagassistdecoupler.ks - Tag landing assist decoupler in flight.
// Usage list/auto: RUNPATH("0:/cmd/tagassistdecoupler.ks").
// Usage choose:    RUNPATH("0:/cmd/tagassistdecoupler.ks", 0).

PARAMETER which_ IS -1.

LOCAL tagName IS "landing_assist_decoupler".
LOCAL tagged IS SHIP:PARTSTAGGED(tagName).
IF tagged:LENGTH > 0 {
    PRINT "Assist decoupler already tagged: " + tagged[0]:TITLE.
    RETURN.
}

LOCAL candidates IS LIST().
FOR p IN SHIP:PARTS {
    IF p:HASMODULE("ModuleDecouple") OR p:HASMODULE("ModuleAnchoredDecoupler") {
        candidates:ADD(p).
    }
}

PRINT "Assist decoupler candidates: " + candidates:LENGTH.
FROM { LOCAL i IS 0. } UNTIL i >= candidates:LENGTH STEP { SET i TO i + 1. } DO {
    LOCAL p IS candidates[i].
    PRINT "  [" + i + "] " + p:TITLE
        + " name=" + p:NAME
        + " tag=" + p:TAG.
}

IF candidates:LENGTH = 0 {
    PRINT "No decoupler modules found on active vessel.".
    RETURN.
}

IF which_ < 0 {
    IF candidates:LENGTH = 1 {
        SET which_ TO 0.
    } ELSE {
        PRINT "Multiple decouplers; rerun with index, e.g.:".
        PRINT "RUNPATH('0:/cmd/tagassistdecoupler.ks', 0).".
        RETURN.
    }
}

IF which_ >= candidates:LENGTH {
    PRINT "Index out of range: " + which_.
    RETURN.
}

SET candidates[which_]:TAG TO tagName.
PRINT "Tagged assist decoupler: [" + which_ + "] " + candidates[which_]:TITLE.
