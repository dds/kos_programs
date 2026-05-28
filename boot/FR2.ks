CLEARSCREEN.
PRINT "BOOT".
PRINT " ".

COPYPATH("0:/FR2.ks", "1:/").
RUNONCEPATH("1:/FR2.ks").

LOCAL bootState IS "1:/run/boot".
IF not EXISTS(bootState) {
    LOG " " TO bootState.
    main().
} ELSE {}
