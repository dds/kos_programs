// cmd/zombie.ks — Reboot the other computers.
// Usage: RUNPATH("1:/zombie").

bootLibLoad("zombie").
IF DEFINED zombieRebootOtherCores {
    zombieRebootOtherCores().
} ELSE {
    PRINT "  WARN: zombieRebootOtherCores unavailable".
}
