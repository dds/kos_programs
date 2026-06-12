RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("solar").
PARAMETER forceSearch IS FALSE.
PARAMETER lockSteering IS TRUE.
orientForSolar(forceSearch, lockSteering).

