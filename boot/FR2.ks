CLEARSCREEN.
PRINT "BOOT".
PRINT " ".

COPYPATH("0:/FR2.ks", "1:/").
RUNPATH("1:/FR2.ks").

UNLOCK ALL.

LOCAL bootState IS "1:/boot/first_boot.state".
IF not EXISTS(bootState) {
    LOG "" TO bootState.
    main().
} ELSE {
}
