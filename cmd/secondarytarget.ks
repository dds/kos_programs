// cmd/secondarytarget.ks - Load a mission's secondary target.
//
// Usage after the primary target reaches DONE:
//   RUNPATH("0:/cmd/secondarytarget.ks").
//
// Optional:
//   RUNPATH("0:/cmd/secondarytarget.ks", FALSE).  // skip release

PARAMETER doRelease IS TRUE.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

IF NOT (DEFINED CFG) {
    GLOBAL CFG IS LEXICON().
}
applyKnownMissionState().

LOCAL FUNCTION _cfgStr {
    PARAMETER key.
    PARAMETER defaultValue.
    IF CFG:HASKEY(key) { RETURN CFG[key]. }
    RETURN defaultValue.
}

LOCAL FUNCTION _activateTag {
    PARAMETER tagName.
    PARAMETER moduleName.
    PARAMETER events.

    IF tagName = "" { RETURN 0. }
    LOCAL parts IS SHIP:PARTSTAGGED(tagName).
    LOCAL count IS 0.
    FOR partRef IN parts {
        IF partRef:HASMODULE(moduleName) {
            LOCAL modu IS partRef:GETMODULE(moduleName).
            LOCAL fired IS FALSE.
            FOR eventName IN events {
                IF NOT fired AND modu:HASEVENT(eventName) {
                    modu:DOEVENT(eventName).
                    SET fired TO TRUE.
                    SET count TO count + 1.
                }
            }
        }
    }
    IF parts:LENGTH > 0 {
        PRINT "Activated " + count + " from tag " + tagName + ".".
    }
    RETURN count.
}

LOCAL FUNCTION _releaseTag {
    PARAMETER tagName.
    IF tagName = "" { RETURN TRUE. }
    LOCAL parts IS SHIP:PARTSTAGGED(tagName).
    IF parts:LENGTH = 0 {
        PRINT "No release part tagged " + tagName + "; assuming already gone.".
        RETURN TRUE.
    }
    LOCAL dc IS parts[0].
    IF dc:HASMODULE("ModuleDecouple") {
        dc:GETMODULE("ModuleDecouple"):DOEVENT("Decouple").
    } ELSE IF dc:HASMODULE("ModuleAnchoredDecoupler") {
        dc:GETMODULE("ModuleAnchoredDecoupler"):DOEVENT("Decouple").
    } ELSE {
        PRINT "Release part " + tagName + " has no decouple module.".
        RETURN FALSE.
    }
    WAIT 1.
    RETURN TRUE.
}

IF doRelease AND stateGet("secondary_release_done", "false") <> "true" {
    _activateTag(_cfgStr("SECONDARY_RELEASE_ANTENNA_TAG", ""),
        "ModuleDeployableAntenna",
        LIST("extend antenna", "Extend Antenna", "Extend", "Deploy")).
    _activateTag(_cfgStr("SECONDARY_RELEASE_SOLAR_TAG", ""),
        "ModuleDeployableSolarPanel",
        LIST("Extend Solar Panel", "extend solar panel", "Extend", "Deploy")).
    WAIT 1.
    IF NOT _releaseTag(_cfgStr("SECONDARY_RELEASE_TAG", "")) {
        PRINT "Secondary release failed; holding.".
        WAIT UNTIL FALSE.
    }
    stateSet("secondary_release_done", "true").
    PRINT "Secondary payload released.".
}

LOCAL seqRaw IS _cfgStr("SECONDARY_SEQUENCE", "SHAPE,SCANSAT_OPS,DONE").
LOCAL seq IS phaseListFromString(seqRaw).
SET launchSeq TO seq.
SET xferSeq TO seq.

stateSet("secondary_active", "true").
stateSet("phase", seq[0]).
stateSet("reload_required", "false").

PRINT "Secondary target active.".
PRINT "Sequence: " + seq:JOIN(" -> ").
PRINT "Rebooting into normal mission resume.".
WAIT 1.
REBOOT.
