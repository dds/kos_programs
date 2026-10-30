// Preview refinement of an existing ordered native flyby/capture itinerary.
// RUNPATH("0:/cmd/assistcheck.ks",LIST(
//   LEXICON("BODY","Ike","MIN_PE",25000),
//   LEXICON("BODY","Duna","MIN_PE",75000,"AP",2880000))).
// Leaves only a useful validated preview node. Never burns or changes mission.
@LAZYGLOBAL OFF.
PARAMETER route.
PARAMETER reserveDv IS 100.

LOCAL FUNCTION _cmdAssistcheck {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("gravity_assist").
    SET ASSIST_RESERVE_DV TO reserveDv.
    LOCAL result IS planAssistRefinement(route).
    IF NOT result["OK"] {
        PRINT "Assist preview unavailable: " + result["REASON"] + ".".
        PRINT "A complete native flyby/arrival chain is required; original trajectory retained.".
        RETURN.
    }
    PRINT "ASSIST PREVIEW ONLY: no burn or mission change.".
    PRINT "Predicted correction + capture: " + ROUND(result["COST"],1)
        + "m/s; original itinerary: " + ROUND(result["BASELINE_COST"],1) + "m/s.".
    PRINT "Review every encounter, available fuel and post-flyby capture before executing.".
    PRINT "Comparison is against the existing itinerary; impulsive capture estimate, no landing/return cost.".
    PRINT "Retained fuel allowance: " + reserveDv + "m/s.".
    FOR leg IN result["LEGS"] {
        mLogSummary("STATS assist leg body=" + leg["BODY"] + " pe=" + leg["PE"]
            + " entryUt=" + leg["ENTRY"] + " peUt=" + leg["PE_UT"]).
    }
}

_cmdAssistcheck().
