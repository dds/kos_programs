// Optional file arguments must reach the wrapped command entry function.
PARAMETER forceSearch IS FALSE.
PARAMETER lockSteering IS TRUE.
LOCAL FUNCTION _cmdOrientForSolar {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("solar").
    orientForSolar(forceSearch, lockSteering, TRUE).
    if lockSteering {
        LOCK STEERING TO LOOKDIRUP(SHIP:FACING:FOREVECTOR, SHIP:FACING:TOPVECTOR).
    }
}

_cmdOrientForSolar().
