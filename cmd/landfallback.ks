// Permit a checked local landing after a committed descent misses its site.
// RUNPATH("0:/cmd/landfallback.ks"). then REBOOT.
// Saves only the policy override; preserves mission, return sequence and phase.
@LAZYGLOBAL OFF.
PARAMETER enabled IS 1.

LOCAL FUNCTION _cmdLandfallback {
    IF enabled <> 0 AND enabled <> 1 { PRINT "Use 1 to permit a local fallback, 0 to restore a fixed site.". RETURN. }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF (stateGet("phase","") <> "LAND_ASSIST" AND stateGet("phase","") <> "LAND")
            OR SHIP:BODY:ATM:EXISTS OR SHIP:STATUS <> "SUB_ORBITAL" {
        PRINT "Requires an airless committed LAND_ASSIST/LAND descent. Mission unchanged.". RETURN.
    }
    IF ABORT OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Requires Abort clear and actual, raw and pilot throttle all zero.". RETURN.
    }
    missionOverrideUpdate(LEXICON("LANDING_FLEXIBLE_SITE",enabled,"LANDING_ECONOMY_BRAKE",1)).
    PRINT "Local fallback permission=" + enabled + "; mission/return sequence and current phase preserved.".
    PRINT "Terrain, reachability, light/radio and emergency-slope checks still apply.".
    PRINT "REBOOT when ready; this command does not start a burn or change the target.".
}

_cmdLandfallback().
