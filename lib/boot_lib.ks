// ============================================================
// boot_lib.ks - boot-time library dependency expansion
//
// This stays deliberately small: dependencies.txt is refreshed when
// available, parsed with OPEN(...):READALL:STRING, then cached in
// lexicons/lists for the rest of the boot.
// ============================================================

GLOBAL BOOT_LIB_DEPS IS LEXICON().
GLOBAL BOOT_LIB_BANDS IS LEXICON().
GLOBAL BOOT_LIB_PHASES IS LEXICON().
GLOBAL BOOT_LIB_PREAMBLE IS LIST().
GLOBAL BOOT_LIB_LOADED IS FALSE.

GLOBAL FUNCTION bootLibSpecPath {
    LOCAL archivePath IS "0:/lib/dependencies.txt".
    LOCAL localPath IS "1:/lib/dependencies.txt".
    IF HOMECONNECTION:ISCONNECTED AND EXISTS(archivePath) {
        IF NOT EXISTS("1:/lib") { CREATEDIR("1:/lib"). }
        COPYPATH(archivePath, localPath).
    }
    RETURN localPath.
}

LOCAL FUNCTION _bootLibApplyValues {
    PARAMETER table.
    PARAMETER key.
    PARAMETER values.
    PARAMETER op.
    LOCAL current IS LIST().
    IF table:HASKEY(key) {
        FOR item IN table[key] { current:ADD(item). }
        table:REMOVE(key).
    }
    IF op = "=" {
        SET current TO LIST().
    }
    IF op = "-" {
        LOCAL kept IS LIST().
        FOR item IN current {
            IF NOT values:CONTAINS(item) { kept:ADD(item). }
        }
        SET current TO kept.
    } ELSE {
        FOR item IN values {
            IF NOT current:CONTAINS(item) { current:ADD(item). }
        }
    }
    table:ADD(key, current).
}

LOCAL FUNCTION _bootLibLineValues {
    PARAMETER raw.
    LOCAL values IS LIST().
    IF raw = "" { RETURN values. }
    FOR itemRaw IN raw:SPLIT(",") {
        LOCAL item IS itemRaw:TRIM.
        IF item <> "" { values:ADD(item). }
    }
    RETURN values.
}

LOCAL FUNCTION _bootLibBandKey {
    PARAMETER band.
    RETURN band:TOUPPER.
}

LOCAL FUNCTION _bootLibParseLines {
    PARAMETER raw.
    LOCAL lines IS raw:SPLIT(CHAR(10)).
    FOR lineRaw IN lines {
        LOCAL line IS lineRaw:REPLACE(CHAR(13), ""):TRIM.
        IF line <> "" {
            LOCAL skipLine IS FALSE.
            IF line:SUBSTRING(0, 1) = "#" { SET skipLine TO TRUE. }
            IF line:LENGTH >= 2 AND line:SUBSTRING(0, 2) = "//" { SET skipLine TO TRUE. }
            IF NOT skipLine {
                LOCAL parts IS line:SPLIT("=").
                IF parts:LENGTH >= 2 {
                    LOCAL lhs IS parts[0]:TRIM.
                    LOCAL rhs IS parts[1]:TRIM.
                    LOCAL op IS "=".
                    IF lhs:LENGTH > 0 {
                        LOCAL opChar IS lhs:SUBSTRING(lhs:LENGTH - 1, 1).
                        IF opChar = "+" OR opChar = "-" {
                            SET op TO opChar.
                            SET lhs TO lhs:SUBSTRING(0, lhs:LENGTH - 1):TRIM.
                        }
                    }
                    LOCAL keys IS _bootLibLineValues(lhs:REPLACE(" ", ",")).
                    IF keys:LENGTH >= 2 AND keys[0]:TOUPPER = "LIB" {
                        LOCAL libName IS keys[1]:TRIM.
                        _bootLibApplyValues(BOOT_LIB_DEPS, libName, _bootLibLineValues(rhs), op).
                    } ELSE IF keys:LENGTH >= 1 AND keys[0]:TOUPPER = "PREAMBLE" {
                        LOCAL preambleTable IS LEXICON("PREAMBLE", BOOT_LIB_PREAMBLE).
                        _bootLibApplyValues(preambleTable, "PREAMBLE", _bootLibLineValues(rhs), op).
                        SET BOOT_LIB_PREAMBLE TO preambleTable["PREAMBLE"].
                    } ELSE IF keys:LENGTH >= 2 AND keys[0]:TOUPPER = "BAND" {
                        LOCAL bandKey IS _bootLibBandKey(keys[1]).
                        _bootLibApplyValues(BOOT_LIB_BANDS, bandKey, _bootLibLineValues(rhs), op).
                    } ELSE IF keys:LENGTH >= 2 AND keys[0]:TOUPPER = "PHASE" {
                        LOCAL phaseIx IS 1.
                        UNTIL phaseIx >= keys:LENGTH {
                            LOCAL phaseName IS keys[phaseIx]:TOUPPER.
                            _bootLibApplyValues(BOOT_LIB_PHASES, phaseName, _bootLibLineValues(rhs), op).
                            SET phaseIx TO phaseIx + 1.
                        }
                    }
                }
            }
        }
    }
}

GLOBAL FUNCTION bootLibLoadSpec {
    IF BOOT_LIB_LOADED { RETURN. }
    LOCAL path_ IS bootLibSpecPath().
    IF NOT EXISTS(path_) {
        PRINT "  WARN: dependencies.txt unavailable".
        SET BOOT_LIB_LOADED TO TRUE.
        RETURN.
    }

    _bootLibParseLines(OPEN(path_):READALL:STRING).
    SET BOOT_LIB_LOADED TO TRUE.
}

GLOBAL FUNCTION bootLibAddUnique {
    PARAMETER libs.
    PARAMETER libName.
    IF libName <> "" AND NOT libs:CONTAINS(libName) {
        libs:ADD(libName).
    }
}

GLOBAL FUNCTION bootLibAppendResolved {
    PARAMETER libs.
    PARAMETER libName.
    bootLibLoadSpec().
    IF BOOT_LIB_DEPS:HASKEY(libName) {
        FOR dep IN BOOT_LIB_DEPS[libName] {
            bootLibAppendResolved(libs, dep).
        }
    }
    bootLibAddUnique(libs, libName).
}

GLOBAL FUNCTION bootLibResolve {
    PARAMETER roots.
    LOCAL libs IS LIST().
    FOR libName IN roots {
        bootLibAppendResolved(libs, libName).
    }
    RETURN libs.
}

GLOBAL FUNCTION bootLibBandRoots {
    PARAMETER band.
    bootLibLoadSpec().
    LOCAL roots IS LIST().
    FOR libName IN BOOT_LIB_PREAMBLE { bootLibAddUnique(roots, libName). }
    LOCAL bandKey IS _bootLibBandKey(band).
    IF BOOT_LIB_BANDS:HASKEY(bandKey) {
        FOR phaseName IN BOOT_LIB_BANDS[bandKey] {
            FOR libName IN bootLibPhaseRoots(phaseName) { bootLibAddUnique(roots, libName). }
        }
    } ELSE {
        FOR libName IN bootLibPhaseRoots(bandKey) { bootLibAddUnique(roots, libName). }
    }
    RETURN roots.
}

GLOBAL FUNCTION bootLibBand {
    PARAMETER band.
    RETURN bootLibResolve(bootLibBandRoots(band)).
}

GLOBAL FUNCTION bootLibBandForPhase {
    PARAMETER phaseName.
    PARAMETER defaultBand IS "".
    bootLibLoadSpec().
    LOCAL phaseKey IS phaseName:TOUPPER.
    IF phaseKey = "" { RETURN defaultBand. }
    FOR bandKey IN BOOT_LIB_BANDS:KEYS {
        FOR bandPhase IN BOOT_LIB_BANDS[bandKey] {
            IF bandPhase:TOUPPER = phaseKey { RETURN bandKey. }
        }
    }
    IF defaultBand <> "" { RETURN defaultBand. }
    RETURN phaseKey.
}

GLOBAL FUNCTION bootLibPhaseRoots {
    PARAMETER phaseName.
    bootLibLoadSpec().
    LOCAL roots IS LIST().
    FOR libName IN BOOT_LIB_PREAMBLE { bootLibAddUnique(roots, libName). }
    LOCAL phaseKey IS phaseName:TOUPPER.
    IF BOOT_LIB_PHASES:HASKEY(phaseKey) {
        FOR libName IN BOOT_LIB_PHASES[phaseKey] { bootLibAddUnique(roots, libName). }
    }
    RETURN roots.
}
