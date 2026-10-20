// Shared transfer checkpoint: anchor before solar work or arrival review.
@LAZYGLOBAL OFF.
GLOBAL MIDCOURSE_REFINE_FRACTION IS 0.5.
GLOBAL MIDCOURSE_REFINE_MIN_LEAD IS 600.
GLOBAL MIDCOURSE_REFINE_MARGIN IS 60.
GLOBAL SOI_BUFFER_TIME IS 120.
GLOBAL BPLANE_LEAD IS 300.

GLOBAL FUNCTION midcourseRefineUt {
    PARAMETER tStart.
    PARAMETER tArrival.
    // Reboots and arrival holds must not keep slipping the midpoint later.
    LOCAL storedUt IS stateGetNum("midcourse_refine_ut", 0).
    LOCAL storedArrival IS stateGetNum("midcourse_refine_arrival_ut", 0).
    IF storedUt > 0 AND ABS(storedArrival - tArrival) < 1 {
        RETURN MAX(TIME:SECONDS, storedUt).
    }
    LOCAL frac IS MAX(0.05, MIN(0.95, MIDCOURSE_REFINE_FRACTION)).
    LOCAL rawUt IS tStart + frac * (tArrival - tStart).
    LOCAL latestUt IS tArrival - SOI_BUFFER_TIME - BPLANE_LEAD - MIDCOURSE_REFINE_MARGIN.
    IF latestUt <= tStart { RETURN tStart. }
    LOCAL refineUt IS rawUt.
    IF refineUt < tStart + MIDCOURSE_REFINE_MIN_LEAD
            AND tStart + MIDCOURSE_REFINE_MIN_LEAD < latestUt {
        SET refineUt TO tStart + MIDCOURSE_REFINE_MIN_LEAD.
    }
    SET refineUt TO MIN(refineUt, latestUt).
    stateSet("midcourse_refine_method", "TIME").
    stateSet("midcourse_refine_fraction", frac).
    stateSet("midcourse_refine_arrival_ut", tArrival).
    stateSet("midcourse_refine_ut", refineUt).
    FOR key IN LIST("midcourse_refine_distance", "midcourse_refine_start_distance") {
        stateRemove(key).
    }
    mLog("STATS midcourse schedule arrivalUt=" + tArrival + " refineUt=" + refineUt
        + " eta=" + (refineUt-TIME:SECONDS) + " fraction=" + frac).
    RETURN refineUt.
}

GLOBAL FUNCTION midcourseClearReviewAlarm {
    LOCAL alarmId IS stateGet("arrival_review_alarm", "").
    IF alarmId <> "" AND ADDONS:KAC:AVAILABLE { DELETEALARM(alarmId). }
    stateRemove("arrival_review_alarm").
}
