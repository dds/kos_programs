// cmd/scan.ks — SCANsat/science operator actions (0:/cmd/scan.ks)
// Replaces scanstart.ks / scanstatus.ks / scantransmit.ks.
// Usage:
//   RUNPATH("1:/cmd/scan.ks").              // status
//   RUNPATH("1:/cmd/scan.ks", "start").     // start all scanners
//   RUNPATH("1:/cmd/scan.ks", "transmit").  // transmit stored science

PARAMETER action IS "status".

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("science").

IF action = "start" {
    scienceStartScanners().
} ELSE IF action = "transmit" {
    scienceTransmitAll().
} ELSE IF action = "status" {
    scienceScanStatus().
} ELSE {
    PRINT "Unknown action '" + action + "'. Use: start | status | transmit.".
}
