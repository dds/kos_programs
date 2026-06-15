// cmd/setstatenum.ks
PARAMETER key.
PARAMETER value.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

stateSetNum(key, value).
PRINT key + " -> " + value.
