// Save a boolean policy without changing the phase or maneuver node.
// RUNPATH("0:/cmd/aeroassist.ks",1). // enable; 0 disables
// Optional final-descent separator: RUNPATH("0:/cmd/aeroassist.ks",1,"return_decoupler").
@LAZYGLOBAL OFF.
PARAMETER enabled IS 1.
PARAMETER descentTag IS "".

LOCAL FUNCTION _cmdAeroassist {
    IF enabled <> 0 AND enabled <> 1 {
        PRINT "Use 1 to enable aerobrake assistance, or 0 to disable.".
        RETURN.
    }
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    LOCAL settings IS LEXICON("AEROBRAKE_AP_BURN",enabled).
    IF descentTag <> "" {
        IF stateGet("phase","") <> "AEROBRAKE" OR ABORT
                OR NOT (SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
                    AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0) {
            PRINT "Separator setup requires AEROBRAKE, Abort clear and all thrust/throttle zero. Nothing changed.".
            RETURN.
        }
        LOCAL matches IS SHIP:PARTSTAGGED(descentTag).
        IF matches:LENGTH <> 1 {
            PRINT "Separator tag must identify exactly one part. Nothing changed.". RETURN.
        }
        LOCAL separator IS matches[0].
        IF NOT (separator:HASMODULE("ModuleDecouple") OR separator:HASMODULE("ModuleAnchoredDecoupler"))
                OR separator:ISDECOUPLED OR NOT separator:STAGED OR separator:STAGE < 0
                OR CORE:PART:DECOUPLEDIN >= separator:STAGE {
            PRINT "Separator is invalid or would discard this CPU. Nothing changed.". RETURN.
        }
        LOCAL chutes IS SHIP:PARTSTAGGED("descent_chutes").
        IF chutes:LENGTH = 0 {
            PRINT "No tagged descent_chutes to verify on the retained probe. Nothing changed.". RETURN.
        }
        FOR chute IN chutes {
            IF NOT chute:HASMODULE("ModuleParachute") OR chute:DECOUPLEDIN >= separator:STAGE {
                PRINT "Tagged parachute is invalid or would be discarded. Nothing changed.". RETURN.
            }
        }
        settings:ADD("DESCENT_DECOUPLER_TAG",descentTag).
    }
    missionOverrideUpdate(settings).
    PRINT "Aerobrake assistance saved: enabled=" + enabled + ".".
    PRINT "Applies at the next AEROBRAKE boot. This command does not take over active flight.".
    IF descentTag <> "" {
        PRINT "Final DESCENT separator saved: " + descentTag + "; existing separation altitude preserved.".
        PRINT "Aerobrake assist uses the active engine only; this does not stage through other fuel tanks.".
    }
}

_cmdAeroassist().
