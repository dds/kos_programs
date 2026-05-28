DECLARE GLOBAL flightLogPathLocal IS "".
DECLARE GLOBAL flightLogPathArchive IS "".

GLOBAL FUNCTION initializeLogFile {
    LOCAL fileName IS SHIP:NAME + "_" + ROUND(TIME:SECONDS) + ".log".

    SET flightLogPathLocal TO "1:/logs/" + fileName.
    SET flightLogPathArchive TO "0:/logs/" + fileName.
}

GLOBAL FUNCTION mLog {
    PARAMETER message.

    LOCAL stampedLine IS "[" + ROUND(TIME:SECONDS, 1) + "] " + message. 
    PRINT message.

    LOG stampedLine TO flightLogPathLocal.
}
