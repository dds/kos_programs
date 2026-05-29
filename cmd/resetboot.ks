// cmd/resetboot.ks — Reset boot count so next reboot re-arms auto mode
// Usage: RUNPATH("1:/cmd/resetboot.ks").
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
stateSetNum("boot_count", 0).
PRINT "Boot count reset. Reboot to re-arm auto mode.".
mLog("Boot count reset by operator.").
