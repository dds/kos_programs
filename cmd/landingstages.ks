// Reserve lower-numbered propulsion stages for surface ascent/return.
// RUNPATH("0:/cmd/landingstages.ks", 2). // landing may use stage 2 and above
// Per-flight override only; does not stage, ignite, change mission or reboot.
@LAZYGLOBAL OFF.
PARAMETER lastLandingStage IS -1.

LOCAL FUNCTION _cmdLandingstages {
    IF lastLandingStage < 0 OR lastLandingStage <> FLOOR(lastLandingStage) {
        PRINT "Supply the lowest engine stage landing may use, for example 2.".
        RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("vessel_hardware").
    IF ABORT OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:MAINTHROTTLE > 0
            OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Stop automation with Abort clear and zero actual/raw/pilot throttle before configuring landing stages.".
        RETURN.
    }
    IF STAGE:NUMBER < lastLandingStage OR CORE:PART:DECOUPLEDIN >= lastLandingStage {
        PRINT "That landing-stage floor is already passed or would discard the controlling core. Nothing saved.".
        RETURN.
    }
    LOCAL found IS FALSE.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:POSSIBLETHRUST > 0
                AND eng:STAGE < lastLandingStage {
            PRINT "A reserved lower-stage engine is already enabled. Disable it before configuring this floor.".
            RETURN.
        }
        IF eng:STAGE = lastLandingStage AND eng:DECOUPLEDIN < lastLandingStage
                AND NOT eng:THROTTLELOCK AND NOT eng:FLAMEOUT AND eng:POSSIBLETHRUST > 0 {
            SET found TO TRUE.
        }
    }
    IF NOT found {
        PRINT "No usable retained throttleable engine exists at that staging number. Nothing saved.".
        RETURN.
    }
    missionOverrideUpdate(LEXICON("LANDING_STAGE_LIMIT",lastLandingStage)).
    SET LANDING_STAGE_LIMIT TO lastLandingStage.
    PRINT "Saved landing stage floor=" + lastLandingStage + "; lower-numbered engines reserved for later phases.".
    PRINT "Keep crossfeed from reserved tanks disabled; this setting controls staging, not fuel flow.".
    PRINT "Landing may exhaust these permitted engines; the floor is not a descent-fuel guarantee.".
    PRINT "Surface ascent can use remaining landing fuel and its own normal staging.".
    PRINT "Mission, node, target and phase preserved. Applies at subsequent boots; no reboot or burn started here.".
}

_cmdLandingstages().
