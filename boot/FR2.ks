// --- Boot script for FR2 mission set.

// Wait for game to stabilize
WAIT 2.

// Open and configure term
CORE:DOACTION("Open Terminal", TRUE).
SET TERMINAL:HEIGHT to 15.
SET TERMINAL:WIDTH to 40.
CLEARSCREEN.

PRINT "=================================================".
PRINT "     BOOT SEQUENCE INITIATED".
PRINT "=================================================".

LOCAL missionScript is "FR2.ks".
COPYPATH("0:/{0}":FORMAT(missionScript), "1:/").
RUNPATH("1:/{0}":FORMAT(missionScript)).
