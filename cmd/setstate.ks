// cmd/setstate.ks
PARAMETER key.
PARAMETER value.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

stateSet(key, value).
PRINT key + " -> " + value.
