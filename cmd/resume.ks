// cmd/resume.ks — Resume mission from saved phase
// Usage: RUNPATH("0:/cmd/resume.ks").
// Assumes boot has already loaded all libs + vehicle script.

LOCAL FUNCTION _cmdResume {
    resumeMission().
}

_cmdResume().
