// ============================================================
// FDR1.ks  —  Hover drone flight computer  (0:/craft/FDR1.ks)
//
// Autonomous hover/transport drone (lib/drone.ks). One craft
// script for every world: Kerbin builds use tilting lift
// engines (DRONE_STYLE=TILT — vertically mounted Junos work at
// current tech), Mun/Minmus hoppers use level-attitude RCS
// translation (DRONE_STYLE=RCS in the mission profile).
// Ship name:  FDR1-TARGET-TYPE1-...-NN
//
// Build notes (TILT):
//   - Probe core pointing UP (control axis = lift axis).
//   - Lift engines symmetric around CoM, thrust straight down.
//   - Reaction wheels sized to actually tilt the craft.
// Build notes (RCS):
//   - 4-way RCS blocks around CoM + a small lift engine, or
//     enough RCS for >1 local-g of up-thrust.
//
// In flight: AG7 hover, AG8 fly to the selected waypoint,
// AG9 land here. A commanded landing that sits for 8s ends the sortie;
// RUNPATH("1:/cmd/restartflightplan") re-arms for the next one.
// ============================================================

GLOBAL CFG IS LEXICON(
    "DRONE_STYLE",       "TILT",
    "DRONE_HOVER_AGL",      15,
    "DRONE_CRUISE_AGL",     60,
    "DRONE_CRUISE_SPEED",   25,
    "DRONE_MAX_TILT",       30,
    "DRONE_VS_CAP",          8,
    "DRONE_LOW_RESOURCE",   15
).

GLOBAL FDR1_SEQ IS LIST("ARM", "FLY", "DONE").

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs("FLY").
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    LOCAL seq IS airplaneSequenceFromState(FDR1_SEQ).
    LOCAL libs IS missionSequenceLibs(missionLibsForPhases(seq, LIST()), LIST()).
    stateSet("lib_band", "FLY").
    stateSet("lib_band_phase", stateGet("phase", seq[0])).
    stateSet("lib_band_libs", libs:JOIN(",")).
    RETURN libs.
}

GLOBAL FUNCTION main {
    LOCAL seq IS FDR1_SEQ.
    IF stateGet("mission_cfg_SEQUENCE", "") <> "" {
        SET seq TO phaseListFromString(stateGet("mission_cfg_SEQUENCE", "")).
    }
    SET launchSeq TO seq.
    SET xferSeq TO seq.

    mLogPhase("FDR1 MAIN").
    mLog("Target: " + MISSION["target"] + "  Payloads: " + MISSION["payloads"]).
    IF stateGet("phase", "") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "ARM", phaseArm@,
        "FLY", phaseFly@
    ).
    runPhases(phaseMap).
}
