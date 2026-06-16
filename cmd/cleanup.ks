// cmd/cleanup.ks - Free local kOS storage
// Usage with link: RUNPATH("0:/cmd/cleanup.ks").
// Usage cached:    RUNPATH("0:/cmd/cleanup.ks").

RUNPATH("1:/lib/boot_lib").
bootLibLoad("cleanup").
cleanupLocalVolume().
