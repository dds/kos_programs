// cmd/resetboot.ks — Reset boot count so next reboot re-arms auto mode
// Usage: RUNPATH("0:/cmd/resetboot.ks").
RUNPATH("1:/lib/boot_lib").
bootPreamble().
stateSet("boot_count", 0).
PRINT "Boot count reset. Reboot to re-arm auto mode.".
mLog("Boot count reset by operator.").
