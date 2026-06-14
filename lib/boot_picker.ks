// ============================================================
// boot_picker.ks  —  Launch-pad mission picker  (0:/lib/boot_picker.ks)
//
// Split out of boot_lib: only a fresh, linked pad boot needs the
// paged profile menu, so the other 99% of boots skip these bytes.
// ============================================================

LOCAL FUNCTION _bootSortStrings {
    PARAMETER l.
    // Insertion sort — profile lists are small and kOS string
    // comparison is lexicographic (and case-insensitive).
    FROM { LOCAL i IS 1. } UNTIL i >= l:LENGTH STEP { SET i TO i + 1. } DO {
        LOCAL v_ IS l[i].
        LOCAL j IS i - 1.
        UNTIL j < 0 {
            IF l[j] > v_ {
                SET l[j + 1] TO l[j].
                SET j TO j - 1.
            } ELSE {
                BREAK.
            }
        }
        SET l[j + 1] TO v_.
    }
}

// Paged mission picker: 1-9 selects on the current page, N/P
// pages through any number of profiles, ENTER takes the first
// profile. Scrolls inline (never clears the screen).
GLOBAL FUNCTION bootSelectMissionId {
    PARAMETER craftName.
    PARAMETER hasLink.
    LOCAL configured IS stateGet("mission_id", "").
    IF configured <> "" { RETURN configured. }
    LOCAL ids IS bootMissionConfigIds(craftName, hasLink).
    IF ids:LENGTH = 0 { RETURN "". }
    _bootSortStrings(ids).

    LOCAL pageSize IS 9.
    LOCAL pages IS CEILING(ids:LENGTH / pageSize).
    LOCAL page IS 0.

    UNTIL FALSE {
        LOCAL start IS page * pageSize.
        LOCAL count IS MIN(pageSize, ids:LENGTH - start).
        PRINT " ".
        PRINT "  ========================================".
        PRINT "  " + craftName + " MISSION SELECT"
            + (CHOOSE "  (page " + (page + 1) + "/" + pages + ")"
               IF pages > 1 ELSE "").
        PRINT "  Pick your poison. Confirm your glory.".
        PRINT "  ========================================".
        FROM { LOCAL i IS 0. } UNTIL i >= count STEP { SET i TO i + 1. } DO {
            PRINT "  [" + (i + 1) + "] " + ids[start + i].
        }
        PRINT "  [0] no profile (use vessel name/default)".
        PRINT "  ----------------------------------------".
        LOCAL hint IS "0 skip | 1-" + count + " choose | ENTER " + ids[0].
        IF pages > 1 { SET hint TO hint + " | N/P page". }
        PRINT "  " + hint.

        LOCAL flip IS FALSE.
        UNTIL flip {
            WAIT UNTIL TERMINAL:INPUT:HASCHAR.
            LOCAL ch IS TERMINAL:INPUT:GETCHAR().
            IF ch = CHAR(13) OR ch = CHAR(10) {
                RETURN ids[0].
            } ELSE IF ch = "0" {
                RETURN "".
            } ELSE IF pages > 1 AND (ch = "N" OR ch = " ") {
                SET page TO MOD(page + 1, pages).
                SET flip TO TRUE.
            } ELSE IF pages > 1 AND ch = "P" {
                SET page TO MOD(page + pages - 1, pages).
                SET flip TO TRUE.
            } ELSE {
                FROM { LOCAL i IS 0. } UNTIL i >= count STEP { SET i TO i + 1. } DO {
                    IF ch = "" + (i + 1) {
                        RETURN ids[start + i].
                    }
                }
            }
        }
    }
}
