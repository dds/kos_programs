

LOCAL FUNCTION _cmdOrientForSolar {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("solar").
    PARAMETER forceSearch IS FALSE.
    PARAMETER lockSteering IS TRUE.
    orientForSolar(forceSearch, lockSteering, TRUE).
    if lockSteering {
        LOCK STEERING TO LOOKDIRUP(SHIP:FACING:FOREVECTOR, SHIP:FACING:TOPVECTOR).
    }
}

_cmdOrientForSolar().
