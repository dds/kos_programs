// cmd/kerbinreturn.ks - Return from a moon to Kerbin aerobrake.
// Usage: RUNPATH("0:/cmd/kerbinreturn.ks").       // target Pe = 55 km
//        RUNPATH("0:/cmd/kerbinreturn.ks", 50).   // target Pe = 50 km

PARAMETER targetPeKm IS 55.
PARAMETER maxDv IS 1225.

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoadList(LIST("maneuver", "maneuver_targeting")).

LOCAL targetPe IS targetPeKm * 1000.
IF ABS(targetPeKm) > 1000 { SET targetPe TO targetPeKm. }

LOCAL targetBody IS KERBIN.
LOCAL parentBody IS SHIP:ORBIT:BODY:BODY.
IF parentBody:NAME = targetBody:NAME {
    SET targetBody TO parentBody.
}

LOCAL FUNCTION _removeNodeIfPresent {
    PARAMETER nd.
    IF nd = 0 { RETURN. }
    IF NOT nd:ISTYPE("Node") { RETURN. }
    IF HASNODE { REMOVE nd. WAIT 0.01. }
}

LOCAL FUNCTION _patchPe {
    PARAMETER nd.
    LOCAL patch IS _getTargetPatch(nd, targetBody).
    IF patch = 0 { RETURN -999999999. }
    RETURN patch:PERIAPSIS.
}

LOCAL FUNCTION _seedReturnNode {
    LOCAL bestNode IS 0.
    LOCAL bestScore IS 999999999.
    LOCAL period IS SHIP:ORBIT:PERIOD.
    LOCAL samples IS 24.
    LOCAL seedDvs IS LIST(-180, -240, -320, -420, -560, 180, 240, 320, 420, 560).

    FROM { LOCAL i IS 0. } UNTIL i >= samples STEP { SET i TO i + 1. } DO {
        LOCAL burnTime IS TIME:SECONDS + 120 + period * i / samples.
        FOR dv IN seedDvs {
            LOCAL nd IS NODE(burnTime, 0, 0, dv).
            ADD nd.
            WAIT 0.02.
            LOCAL patch IS _getTargetPatch(nd, targetBody).
            IF patch <> 0 {
                LOCAL score IS ABS(patch:PERIAPSIS - targetPe) + nd:DELTAV:MAG * 20.
                IF nd:DELTAV:MAG <= maxDv AND score < bestScore {
                    _removeNodeIfPresent(bestNode).
                    SET bestNode TO nd.
                    SET bestScore TO score.
                } ELSE {
                    REMOVE nd.
                }
            } ELSE {
                REMOVE nd.
            }
            WAIT 0.01.
        }
    }
    RETURN bestNode.
}

PRINT "KERBIN RETURN: target Pe " + ROUND(targetPe/1000,1) + " km".
mLogWarn("STATS kerbin-return setup targetPeKm=" + ROUND(targetPe/1000,1)
    + " body=" + SHIP:ORBIT:BODY:NAME
    + " PeKm=" + ROUND(SHIP:PERIAPSIS/1000,1)
    + " ApKm=" + ROUND(SHIP:APOAPSIS/1000,1)
    + " dvCap=" + ROUND(maxDv,1)
    + " thrust=" + ROUND(SHIP:AVAILABLETHRUST,1)).

IF SHIP:ORBIT:BODY:NAME = targetBody:NAME {
    PRINT "Already in Kerbin SOI.".
    mLogWarn("STATS kerbin-return result status=already-kerbin").
    RETURN.
}

IF SHIP:AVAILABLETHRUST <= 0 {
    PRINT "No available thrust. Cannot plan return burn.".
    mLogError("Kerbin return aborted: no available thrust.").
    RETURN.
}

UNTIL NOT HASNODE { REMOVE NEXTNODE. WAIT 0.1. }
LOCAL nd IS _seedReturnNode().
IF nd = 0 {
    PRINT "No Kerbin-return seed found.".
    mLogError("Kerbin return planner found no Kerbin patch seed.").
    RETURN.
}
IF NOT nd:ISTYPE("Node") {
    PRINT "No Kerbin-return seed found.".
    mLogError("Kerbin return planner found invalid seed object.").
    RETURN.
}

LOCAL patchPe IS _patchPe(nd).
mLogWarn("STATS kerbin-return seed dv=" + ROUND(nd:DELTAV:MAG,1)
    + " eta=" + ROUND(nd:ETA,1)
    + " patchPeKm=" + ROUND(patchPe/1000,1)).

LOCAL targets IS LEXICON("PE", targetPe, "PE_FLOOR", 35000).
LOCAL opts IS LEXICON(
    "STEP_PROGRADE", 20.0,
    "STEP_RADIAL", 20.0,
    "STEP_NORMAL", 5.0,
    "STEP_TIME", 300.0,
    "MIN_STEP", 0.25,
    "MAX_ITER", 120,
    "DV_CAP", maxDv
).
LOCAL result IS _targetPatchElementsCoupled(nd, targetBody, targets, opts).
LOCAL patch IS _getTargetPatch(nd, targetBody).
IF patch = 0 {
    PRINT "Return targeting lost Kerbin patch.".
    mLogError("Kerbin return targeting lost Kerbin patch.").
    RETURN.
}

mLogWarn("STATS kerbin-return target result solved=" + result["SOLVED"]
    + " dv=" + ROUND(nd:DELTAV:MAG,1)
    + " eta=" + ROUND(nd:ETA,1)
    + " patchPeKm=" + ROUND(patch:PERIAPSIS/1000,1)).

IF ABS(patch:PERIAPSIS - targetPe) > 15000 {
    PRINT "Kerbin Pe miss too large: " + ROUND(patch:PERIAPSIS/1000,1) + " km.".
    mLogError("Kerbin return rejected: Pe miss too large.").
    RETURN.
}

mLog("Kerbin return node: dV=" + ROUND(nd:DELTAV:MAG,1)
    + " m/s Pe=" + ROUND(patch:PERIAPSIS/1000,1)
    + " km ETA=" + ROUND(nd:ETA,0) + "s.").
archivePlannedManeuverLog("kerbin-return").
LOCAL ok IS executeManeuver().

IF ok {
    LOCAL finalPatch IS _getTargetPatch(SHIP, targetBody).
    PRINT "Kerbin return burn complete.".
    IF finalPatch <> 0 {
        PRINT "Kerbin Pe: " + ROUND(finalPatch:PERIAPSIS/1000,1) + " km.".
        mLogWarn("STATS kerbin-return result status=complete PeKm="
            + ROUND(finalPatch:PERIAPSIS/1000,1)).
    } ELSE {
        mLogWarn("STATS kerbin-return result status=complete patch=missing-after-burn").
    }
} ELSE {
    PRINT "Kerbin return burn failed or was interrupted.".
    mLogError("Kerbin return burn failed or was interrupted.").
}
