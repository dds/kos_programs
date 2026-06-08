// cmd/zombie.ks — Reboot the other computers.
// Usage: RUNPATH("1:/zombie").

RUNPATH("1:/lib/boot_lib").
bootLibLoad("zombie").
IF DEFINED zombieRebootOtherCores {
    zombieRebootOtherCores().
} ELSE {
    PRINT "  WARN: zombieRebootOtherCores unavailable".
}
