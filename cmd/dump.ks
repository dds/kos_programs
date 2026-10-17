// cmd/dump.ks — Print all persisted state
// Usage: RUNPATH("0:/cmd/dump.ks").

LOCAL FUNCTION _cmdDump {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    stateDump().
}

_cmdDump().
