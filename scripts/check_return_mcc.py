"""Return-corridor regressions using source expressions and two-body fixtures.

Not a kOS VM or a KSP flight test. Run: python3 -B scripts/check_return_mcc.py
"""
import math
import re
from pathlib import Path
from types import SimpleNamespace as NS

from check_launch_and_staging import body, evaluate

ROOT = Path(__file__).resolve().parents[1]
MCC = (ROOT / 'lib/maneuver_mcc.ks').read_text()
AERO = (ROOT / 'lib/aerobrake.ks').read_text()
TARGETING = (ROOT / 'lib/maneuver_targeting.ks').read_text()


def check_gates():
    budget = re.search(r'RETURN (.*?)\.', body(MCC, '_mccReturnBudget'), re.S)[1]
    for fuel, expected in [(480, 150), (180, 130), (51, 1), (50, 0), (0, 0)]:
        assert evaluate(budget, MCC_RETURN_DV_CAP=150, MCC_RETURN_RESERVE_DV=50,
                        SHIP=NS(DELTAV=NS(VACUUM=fuel))) == expected
    corridor = re.search(r'RETURN (pe >=.*?)\.',
                         body(MCC, '_mccAerobrakePatchSafe'), re.S)[1]
    for pe, allowed in [(2200000, False), (70000, False), (54001, False),
                        (54000, True), (53000, True), (52000, True),
                        (51999, False), (-100, False)]:
        assert evaluate(corridor, pe=pe, target=None, targetPe=53000,
                        _mccAerobrakeSafePeMin=lambda *_: 52000,
                        _mccAerobrakeSafePeMax=lambda *_: 54000) == allowed
    phase = body(MCC, '_mccReturn')
    rejection = re.search(r'IF (NOT peOk OR dv > cap.*?) \{', phase)[1]
    for good, dv, eta, reject in [(True, 45, 120, False), (True, .3, 120, False),
                                  (False, 45, 120, True), (True, 151, 120, True),
                                  (True, 45, 29, True)]:
        assert evaluate(rejection, peOk=good, dv=dv, cap=150,
                        nd=NS(TIME=1000 + eta), TIME=NS(SECONDS=1000)) == reject
    print('PASS: 480 m/s budget, reserve, 52–54 km corridor, tiny burns and stale nodes')


def check_planner_fixture():
    # Independent two-body inbound trajectories, starting with the reported
    # 2200 km Pe. Exercise the existing Newton PE algorithm's scalar update
    # against analytic conics, not its own patched-conic prediction.
    source = body(TARGETING, 'newtonTarget')
    iterations = int(re.search(r'LOCAL maxIter IS (\d+)\.', source)[1])
    update = re.search(r'LOCAL correction IS (.*?)\.', source)[1]
    step = re.search(r'LOCAL maxStep IS CHOOSE .*? ELSE (.*?)\.\n', source)[1]
    mu, radius, wanted = 3.5316e12, 600000., 53000.
    for distance in (35e6, 45e6, 47e6):
        rp, ra = radius + 2200000, 52e6
        semimajor = (rp + ra) / 2
        speed = math.sqrt(mu * (2 / distance - 1 / semimajor))
        transverse = math.sqrt(2 * mu * rp * ra / (rp + ra)) / distance

        def periapsis(prograde):
            velocity = speed + prograde
            angular_momentum = distance * transverse * velocity / speed
            energy = velocity**2 / 2 - mu / distance
            ecc = math.sqrt(1 + 2 * energy * angular_momentum**2 / mu**2)
            return angular_momentum**2 / (mu * (1 + ecc)) - radius

        prograde = 0.
        for _ in range(iterations):
            current = periapsis(prograde)
            err = wanted - current
            if abs(err) < 250:
                break
            sens = (periapsis(prograde + .1) - current) / .1
            correction = evaluate(update, err=err, sens=sens, damp=.5)
            limit = evaluate(step, err=err)
            prograde += max(-limit, min(limit, correction))
            assert abs(prograde) <= 150
        assert abs(periapsis(prograde) - wanted) < 250
    print('PASS: existing PE solver converges for three analytic 2200 km return fixtures')


def check_phase_flow():
    phase = body(MCC, '_mccReturn')
    # An interrupted node survives; only a measured safe orbit may advance.
    assert phase.index('maneuverBurnInterrupted()') < phase.index('REMOVE NEXTNODE')
    assert phase.count('nextPhase(') == 1
    safe = re.search(r'IF _mccAerobrakePatchSafe\(SHIP:ORBIT.*?\{(.*?)\}', phase, re.S)[1]
    assert 'nextPhase(xferSeq)' in safe
    assert 'UNTIL attempt > 3' in phase
    assert phase.index('IF attempt = 3') < phase.index('executeManeuver()')
    assert '"burn-failed-inspect-retained-node"' in phase
    assert '"flown-orbit-outside-corridor"' in phase
    assert 'MCC_MIN_DV' not in phase and 'CAPTURE_INC' not in phase
    hold = body(MCC, '_mccReturnHold')
    assert 'yieldToPrompt()' in hold and 'nextPhase(' not in hold
    assert 'REMOVE' not in hold and 'stateSet("phase"' not in hold
    dispatch = body(MCC, 'phaseMidCourse')
    assert dispatch.index('_mccReturn(target, targetPe)') < dispatch.index('LOCAL targetInc')
    guard = re.search(r'IF (SHIP:BODY:NAME = "Kerbin" AND SHIP:PERIAPSIS >= atmHeight)', AERO)[1]
    for name, pe, reroute in [('Kerbin', 2200000, True), ('Kerbin', 70000, True),
                               ('Kerbin', 53000, False), ('Duna', 2200000, False)]:
        assert evaluate(guard, SHIP=NS(BODY=NS(NAME=name), PERIAPSIS=pe),
                        atmHeight=70000) == reroute
    aero = body(AERO, 'phaseAerobrake')
    assert aero.index('stateSet("phase", "MCC")') < aero.index('_aerobrakeSetEntryAlarm()')
    assert 'no atmospheric approach and no MCC phase; holding' in aero
    command = (ROOT / 'cmd/setphase.ks').read_text()
    assert command.index('bootPreamble()') < command.index('stateGet(')
    assert 'missionOverrideClear' not in command and 'missionProfileBegin' not in command
    print('PASS: actual-orbit handoff, bounded retries, failure holds and saved AEROBRAKE recovery')


if __name__ == '__main__':
    check_gates()
    check_planner_fixture()
    check_phase_flow()
