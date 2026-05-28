// --- Boot script for FR2 mission set.

// Open and configure term
CORE:DOACTION("Open Terminal", TRUE).
SET TERMINAL:HEIGHT to 25.
SET TERMINAL:WIDTH to 50.
CLEARSCREEN.

PRINT "=================================================".
PRINT "     BOOT SEQUENCE INITIATED".
PRINT "=================================================".

COPYPATH("0:/FR2.ks", "1:/").
RUNPATH("1:/FR2.ks").
main().