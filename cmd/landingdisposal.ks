// Save an elective landing handoff without changing the mission or its node.
// RUNPATH("0:/cmd/landingdisposal.ks").         // 80 m/s, 700 m/s reserve
// RUNPATH("0:/cmd/landingdisposal.ks", 0).      // restore fuel-first staging
@LAZYGLOBAL OFF.
PARAMETER handoffSpeed IS 80.
PARAMETER reserveDv IS 700.

LOCAL FUNCTION _cmdLandingdisposal {
    IF NOT (handoffSpeed = 0 OR handoffSpeed > 30)
            OR NOT (reserveDv >= 0) {
        PRINT "Use speed=0 to disable, or speed>30 m/s and a nonnegative lander reserve.".
        RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    missionOverrideUpdate(LEXICON("LANDING_STAGE_DISCARD_HSPEED", handoffSpeed,
        "LANDING_STAGE_DISCARD_RESERVE_DV", reserveDv)).
    PRINT "Landing disposal saved: handoff speed=" + handoffSpeed + "m/s reserve=" + reserveDv + "m/s.".
    PRINT "Applies when the landing band next boots; no active flight controller is changed.".
    PRINT "Fuel, clearance, stack, cutoff and ballistic-contact checks remain mandatory.".
    PRINT "Node and mission phase preserved. This command does not execute the maneuver.".
}

_cmdLandingdisposal().
