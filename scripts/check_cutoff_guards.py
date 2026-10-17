"""Source-expression/order checks, not a kOS flight-control simulation."""
import re
from pathlib import Path
from types import SimpleNamespace as NS
from check_launch_and_staging import body, evaluate

ROOT = Path(__file__).resolve().parents[1]
ASCENT = (ROOT / 'lib/ascent.ks').read_text()


def safe_throttle(control, pe=9000, now=20, abort=False, command=.7):
    src = body(ASCENT, '_circSafeThrottle')
    env = dict(control=control, SHIP=NS(PERIAPSIS=pe), TIME=NS(SECONDS=now),
               ABORT=abort, command=command)
    for cond, action in re.findall(r'IF (.*?) \{(.*?)\}', src, re.S):
        if evaluate(cond, **env):
            if 'RETURN 0.' in action:
                return 0
            reason = re.search(r'SET control\["REASON"\] TO "(.*?)"', action)[1]
            control['REASON'] = reason
    return evaluate(src[src.rindex('RETURN ')+7:].strip().removesuffix('.'), **env)


def check_cutoffs():
    fresh = lambda: dict(REASON='', TARGET_PE=9900, DEADLINE=90, APPLIED_DV=0, DV_CAP=100)
    for condition, reason in ((dict(pe=9900), 'parking-periapsis'),
                              (dict(now=90), 'time-limit'), (dict(abort=True), 'abort')):
        control = fresh()
        assert safe_throttle(control, **condition) == 0
        assert control['REASON'] == reason
        # A stale nonzero command or a later change in Pe cannot restart thrust.
        assert safe_throttle(control, pe=8000, now=30, command=1) == 0
    control = fresh()
    control['APPLIED_DV'] = 100
    assert safe_throttle(control) == 0 and control['REASON'] == 'dv-limit'
    assert safe_throttle(fresh(), command=2) == 1
    assert safe_throttle(fresh(), command=-1) == 0
    assert safe_throttle(fresh(), command=.03) == .03
    stop = body(ASCENT, '_ascentStopThrottle')
    assert 'RETURN thrustCutoffOk(releaseLock).' in stop
    circ = body(ASCENT, '_ascentCircularize')
    assert 'LOCK THROTTLE TO _circSafeThrottle(throt, control).' in circ
    loop = circ[circ.index('UNTIL ABORT OR appliedDv'):circ.index('IF control["REASON"] = ""')]
    assert 'mLog(' not in loop and 'mLogWarn(' not in loop
    assert 'LOCK THROTTLE TO throt.' not in circ
    assert circ.index('IF NOT _ascentStopThrottle()', circ.index('SET throt TO 0.')) < circ.index('FOR traceLine IN burnTrace')
    taper = re.search(r'SET throt TO (MIN\(1, remDv.*?\))\.', circ)[1]
    for acceleration in (.2, 4, 100):
        for dt in (.02, .2, 2):
            throttle = evaluate(taper, remDv=.31, currentAcc=acceleration, dt=dt)
            assert 0 < throttle <= 1
            assert throttle*acceleration*dt <= .31 + 1e-9
    deorbit = (ROOT / 'lib/deorbit_burn.ks').read_text()
    assert 'LOCAL stopped IS vesselLandingCleanup().' in deorbit
    assert 'LOCAL success IS stopped AND NOT ABORT' in deorbit
    print('PASS: latched parking/abort/time/dV cutoffs, no throttle floor, zero reaches physics before unlock/logging')


def check_preview():
    src = (ROOT / 'lib/return_escape.ks').read_text()
    preview = body(src, 'previewReturnEscape')
    assert preview.index('IF HASNODE') < preview.index('_planReturnEscape(')
    assert 'SET ESCAPE_KSC_TARGET TO 0.' in preview
    assert all(term not in preview for term in ('executeManeuver(', 'nextPhase(', 'stateSet(', 'REBOOT.', 'REMOVE '))
    command = (ROOT / 'cmd/returncheck.ks').read_text()
    assert 'bootPreamble().' in command and 'bootLibLoad("return_escape").' in command
    assert 'previewReturnEscape(53000).' in command
    entry = body(src, '_returnEscapeEntryValid')
    expr = entry[entry.index('RETURN ')+7:].strip().removesuffix('.')
    for pe, expected in ((52000,True),(53000,True),(54000,True),(51999,False),
                         (54001,False),(-1000,False),(22050000,False)):
        assert evaluate(expr, predictedPe=pe, targetPe=53000, RETURN_ESCAPE_PE_TOLERANCE=1000) == expected
    phase = body(src, 'phaseEscape')
    guard = phase.index('IF NOT _returnEscapeEntryValid(')
    execute = phase.index('SET success TO executeManeuver().')
    assert guard < execute and 'yieldToPrompt().' in phase[guard:execute]
    assert 'nd:DELTAV:MAG > SHIP:DELTAV:VACUUM' in phase[guard:execute]
    assert 'RETURN.' in phase[guard:execute]
    print('PASS: return preview preserves phase/existing nodes and never executes a burn')
    print('PASS: 22,050 km Pe rejected; automatic execution holds outside entry corridor or fuel budget')


if __name__ == '__main__':
    check_cutoffs()
    check_preview()
