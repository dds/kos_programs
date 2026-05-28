// --- BOOT SCRIPT for X_SHOT rocket mission group.

// Wait for game to stabilize
WAIT 2.

// Open and configure term
CORE:DOACTION("Open Terminal", TRUE).
SET TERMINAL:HEIGHT to 25.
SET TERMINAL:WIDTH to 50.
CLEARSCREEN.

PRINT "=================================================".
PRINT "     BOOT SEQUENCE INITIATED".
PRINT "=================================================".

// Copy and run the main msision script from the Archive (Volume 0)
LOCAL missionScript is "X_SHOT.ks".
COPYPATH("0:/{0}":FORMAT(missionScript), "1:/").
RUNPATH("1:/{0}":FORMAT(missionScript)).
