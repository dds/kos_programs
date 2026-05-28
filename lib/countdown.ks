DECLARE GLOBAL FUNCTION countdown {
    PARAMETER countStart.

    SET beepVoice to GETVOICE(0).
    FROM {local i is countStart.} UNTIL i = 0 STEP {set i to i - 1.} DO {
        PRINT "T-minus " + i.
        // Play a quick 440Hz (A4) beep for 0.1 seconds
        HUDTEXT("T-minus " + i, 1, 2, 15, WHITE, FALSE).
        beepVoice:PLAY(NOTE(440, 0.1)).
        WAIT 1.
    }
    beepVoice:PLAY(NOTE(880, 0.4)). // Higher pitch beep for launch
} 