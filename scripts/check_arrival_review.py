"""Check partial-arrival review, binding and accepted targets without the kOS VM."""
import math
import re
from pathlib import Path
from types import SimpleNamespace as NS

from check_launch_and_staging import body, evaluate
from check_surface_return import read_settings, literal

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'lib/arrival_bplane.ks').read_text()
COMMAND = (ROOT / 'cmd/arrival.ks').read_text()


def check_binding():
    match = body(SOURCE, 'bplaneReviewMatches')
    expr = re.search(r'RETURN (.*?)\.\s*$', match, re.S)[1]
    saved = dict(mission='mun_capture_recovery', phase='BPLANE', body='Kerbin',
                 target='Mun', ut=12345, pro=12, rad=-2, normal=58)
    node = dict(TIME=12345, PROGRADE=12, RADIALOUT=-2, NORMAL=58)
    state = dict(mission_id='mun_capture_recovery', phase='BPLANE')
    def matches(saved=saved, node=node, state=state):
        return evaluate(expr, saved=saved, nd=NS(**node), SHIP=NS(BODY=NS(NAME='Kerbin')),
                        stateGet=lambda key, default: state.get(key, default), getTarget=lambda _: 'Mun')
    assert matches()
    for changed in (dict(TIME=12346), dict(PROGRADE=13), dict(RADIALOUT=0), dict(NORMAL=57)):
        assert not matches(node=node | changed)
    assert not matches(state=state | {'phase': 'REFINE_BPLANE'})
    assert not matches(state=state | {'mission_id': 'other'})
    assert not matches(saved=saved | {'body': 'Mun'})
    assert not matches(saved=saved | {'target': 'Minmus'})
    command = body(COMMAND, '_arrivalCommand')
    stale = re.search(r'IF (nd:ETA.*?maneuverBurnInterrupted\(\)) \{', command, re.S)[1]
    for eta, abort, interrupted, blocked in [(300,False,False,False), (29,False,False,True),
                                            (300,True,False,True),(300,False,True,True)]:
        assert evaluate(stale, nd=NS(ETA=eta), BPLANE_EXISTING_NODE_MIN_ETA=30,
                        ABORT=abort, maneuverBurnInterrupted=lambda: interrupted) == blocked
    assert command.index('bplaneReviewMatches(') < command.index('_bplaneWriteAcceptedTargets(')
    assert command.index('bplaneCorrectionAllowed(') < command.index('_bplaneWriteAcceptedTargets(')
    assert 'stateRemove("bplane_review")' in command
    assert command.index('Selected capture Ap exceeds') < command.index('bplaneCorrectionAllowed(')
    print('PASS: exact-node/mission/phase binding and stale, abort, interrupted-burn rejection')


def accepted_values(pe, inc, ap):
    writer = body(COMMAND, '_bplaneWriteAcceptedTargets')
    expr = re.search(r'LOCAL values IS (.*?)\.\s*LOCAL previous', writer, re.S)[1]
    return evaluate(expr, pe=pe, inc=inc, apAlt=ap, BPLANE_REVIEW_MIN_PE=10000,
                    BPLANE_PE_TOL=2000, LEX=lambda *args: dict(zip(args[::2], args[1::2])))


def check_reboot_targets():
    profile = (ROOT / 'missions/RO8/mun_capture_recovery.ks').read_text()
    prior = 'SET TARGET_AP TO 100000.\nSET SHAPE_INC TO 90.\nSET TARGET_LAT TO 44.593.\n'
    for inc in (82.19, 97.81):
        values = accepted_values(27000, inc, 50000)
        # Same literal format and full-file replacement policy as the writer.
        lines = [line for line in prior.splitlines() if not any(
            line.strip().startswith('SET ' + key + ' TO ') for key in values)]
        override = '\n'.join(lines + [f'SET {key} TO {literal(value)}.' for key, value in values.items()])
        for _ in range(2):
            rebooted = read_settings(override, read_settings(profile, {}))
            assert rebooted['CAPTURE_PE'] == rebooted['SHAPE_PE'] == 27000
            assert rebooted['CAPTURE_INC'] == rebooted['SHAPE_INC'] == inc
            assert rebooted['CAPTURE_DIR'] == ''
            assert rebooted['CAPTURE_MIN_PE'] == 25000 and rebooted['CAPTURE_MAX_PE'] == 29000
            assert rebooted['TARGET_AP'] == rebooted['SHAPE_AP'] == 50000
            assert rebooted['BPLANE_REQUIRE_PLANE'] == 1
            assert rebooted['TARGET_LAT'] == 44.593  # Unrelated override survives.
            assert rebooted['SCIENCE_OPS_HOLD'] == 1
        assert min(inc, 180-inc) > 66.765  # Both survey latitudes remain reachable.
    for ap in (50000, 100000, 500000):
        assert accepted_values(27000, 82.19, ap)['SHAPE_AP'] == ap
    print('PASS: reported 27 km / 7.81-degree compromise survives fresh boots through capture and SHAPE')


def check_capture_costs():
    source = body(SOURCE, 'bplaneCaptureCost')
    for vinf in (100,300,600):
        costs = []
        for ap in (50000,100000,500000):
            radius, mu, pe = 200000, 6.5138398e10, 27000
            rp = radius + pe
            env = dict(targetBody=NS(RADIUS=radius, MU=mu), patch=NS(PERIAPSIS=pe,
                       ECCENTRICITY=1 + rp * vinf**2 / mu), TARGET_AP=100000,
                       captureAp=ap, SQRT=math.sqrt)
            for name in ('rp','apAlt','ra','incoming','captured'):
                expr = re.search(rf'LOCAL {name} IS (.*?)\.', source)[1]
                env[name] = evaluate(expr, **env)
                if name == 'apAlt':
                    for expr in re.findall(r'SET apAlt TO (.*?)\.', source):
                        env[name] = evaluate(expr, **env)
            cost = evaluate(re.search(r'RETURN (MAX.*?)\.', source)[1], **env)
            expected = math.sqrt(vinf**2 + 2*mu/rp) - math.sqrt(mu*(2/rp - 2/(rp+radius+ap)))
            assert math.isclose(cost, expected, abs_tol=1e-9)
            costs.append(cost)
        assert costs[0] > costs[1] > costs[2]
    print('PASS: chosen-apoapsis capture estimates; 50 km costs more than 100 km, then 500 km')


def check_review_flow():
    offer = body(SOURCE, '_bplaneOfferReview')
    assert 'phaseCap, FALSE)' in offer
    assert 'bplaneCorrectionAllowed(' in offer and 'stateSet("bplane_review"' in offer
    assert 'executeManeuver' not in offer and '_bplaneReserveCorrection' not in offer
    assert 'yieldToPrompt()' in offer
    gate = body(SOURCE, 'bplaneCorrectionAllowed')
    assert 'IF BPLANE_REQUIRE_PLANE <> 0 AND checkCorridor' in gate
    for guard in ('correction-budget', 'correction-plus-capture-budget', 'arrival-time-shift', 'capture-cost-increase'):
        assert guard in gate
    planner = body(SOURCE, 'planBplaneCorrection')
    assert planner.index('_bplaneOfferReview(') < planner.index('unconverged-optional-correction')
    for phase in ('phaseBplane', 'phaseRefineBplane'):
        code = body(SOURCE, phase)
        assert code.index('bplanePauseForReview()') < code.index('IF SHIP:BODY = targetBody')
        assert code.index('bplanePauseForReview()') < code.index('_bplaneExistingNodeAcceptable(')
    assert 'GLOBAL BPLANE_REVIEW_UNCONVERGED IS 0.' in SOURCE
    print('PASS: review retains node without ignition/charging; reboot holds; budget gates remain mandatory')


if __name__ == '__main__':
    check_binding()
    check_reboot_targets()
    check_capture_costs()
    check_review_flow()
