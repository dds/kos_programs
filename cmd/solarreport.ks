// Read the last solar recorder summary/path without changing attitude or phase.
LOCAL FUNCTION _cmdSolarreport {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    PRINT stateGet("last_solar_summary","No solar search recorded with the new recorder yet.").
    PRINT "Last verified report (may be earlier if the latest is buffered): "
        + stateGet("last_solar_report","none").
}
_cmdSolarreport().
