// cmd/cleanup.ks - Free local kOS storage
// Usage with link: RUNPATH("0:/cmd/cleanup.ks").
// Usage cached:    RUNPATH("0:/cmd/cleanup.ks").

LOCAL FUNCTION _cmdCleanup {
    RUNPATH("1:/lib/boot_lib").
    bootLibLoad("cleanup").
    cleanupLocalVolume().
}

_cmdCleanup().
