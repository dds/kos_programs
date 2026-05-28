// --- Boot script for FR2 mission set.

CLEARSCREEN.

PRINT "=================================================".
PRINT "     BOOT SEQUENCE INITIATED".
PRINT "=================================================".

COPYPATH("0:/FR2.ks", "1:/").
RUNPATH("1:/FR2.ks").
main().