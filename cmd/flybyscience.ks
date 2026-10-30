// Optional science during configured flybys; no added maneuver allowance.
// RUNPATH("0:/cmd/flybyscience.ks",1). Then REBOOT. Use0 to disable.
@LAZYGLOBAL OFF.
PARAMETER enabled IS 1.

LOCAL FUNCTION _cmdFlybyscience {
    IF enabled <> 0 AND enabled <> 1 {
        PRINT "Use1 to enable optional flyby science or0 to disable. Nothing changed.". RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF stateGet("mission_id","") = "" {
        PRINT "No selected mission. Nothing changed.". RETURN.
    }
    missionOverrideUpdate(LEXICON("MISSION_ASSIST_SCIENCE",enabled)).
    PRINT "Optional flyby science saved: enabled=" + enabled + ". REBOOT. to apply.".
    PRINT "Uses configured science bodies only; mission, trajectory and maneuver budgets preserved.".
}

_cmdFlybyscience().
