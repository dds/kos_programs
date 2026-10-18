// Optional file arguments must reach the wrapped command entry function.
PARAMETER forceSearch IS FALSE.
PARAMETER lockSteering IS TRUE.
LOCAL FUNCTION _cmdOrientForSolar {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    bootLibLoad("solar").
    IF NOT orientForSolar(forceSearch, lockSteering, TRUE) { RETURN. }
    IF lockSteering { solarMaintainHold(). }
}

_cmdOrientForSolar().
