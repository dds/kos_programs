"""Source-expression regressions for arrival budgets and file logging.

These fixtures do not run the kOS VM or simulate KSP patched conics.
Run: python3 -B scripts/check_arrival_budget.py
"""
import math
import re
from pathlib import Path
from types import SimpleNamespace as NS

from check_launch_and_staging import body, evaluate
from check_surface_return import read_settings

ROOT = Path(__file__).resolve().parents[1]
BPLANE = (ROOT / 'lib/arrival_bplane.ks').read_text()
SHAPE = (ROOT / 'lib/orbit_shape.ks').read_text()
LOGS = (ROOT / 'lib/logs.ks').read_text()


def check_budget():
    source = re.sub(r'//[^\n]*', '', body(BPLANE, '_bplaneTrimCap'))
    updates = re.findall(r'IF ([\w]+ >= 0) \{\s*SET cap TO (.*?)\.', source, re.S)
    assert len(updates) == 3

    def cap(config, fuel, spent, phase_cap=150):
        env = dict(config, cap=phase_cap, targetBody=None,
                   SHIP=NS(DELTAV=NS(VACUUM=fuel)),
                   _bplaneTrimSpent=lambda _: spent)
        for condition, expression in updates:
            if evaluate(condition, **env):
                env['cap'] = evaluate(expression, **env)
        return evaluate(re.search(r'RETURN (MAX.*?)\.', source)[1], **env)

    for moon, reserve in [('mun', 900), ('minmus', 400)]:
        cfg = read_settings((ROOT / f'missions/RO8/{moon}_landing_return.ks').read_text(), {})
        assert cfg['BPLANE_TRIM_RESERVE_DV'] == reserve
        assert cap(cfg, reserve - 1, 0) == 0
        assert cap(cfg, reserve, 0) == 0
        assert cap(cfg, reserve + 3, 0) == 3
        assert cap(cfg, reserve + 100, 0) == 10
        assert cap(cfg, reserve + 100, 17) == 3
        assert cap(cfg, reserve + 100, 20) == 0
        assert cap(cfg, reserve + 100, 0, phase_cap=2) == 2
        assert cap(cfg, 0, 0) == 0
    print('PASS: RO8 899 m/s report, reserve boundaries, cumulative/refinement caps, unavailable dV')


def check_decisions():
    gate = body(BPLANE, 'bplaneCorrectionAllowed')
    conditions = re.findall(r'IF (.*?)\{\s*_bplaneHoldCorrection\("([^"]+)"\)', gate, re.S)
    # Pull just the last IF before each hold (earlier blocks contain logs).
    conditions = {reason: condition.rsplit('IF ', 1)[-1].strip()
                  for condition, reason in conditions}
    base = dict(nd=NS(DELTAV=NS(MAG=2)), cap=10, planned=object(), shift=0,
                beforeCost=280, afterCost=280, BPLANE_MAX_ARRIVAL_SHIFT=600,
                BPLANE_MAX_CAPTURE_DV_INCREASE=5)
    for cost, expected in [(0.3, False), (10, False), (150, True)]:
        env = dict(base, nd=NS(DELTAV=NS(MAG=cost)))
        assert evaluate(conditions['correction-budget'], **env) == expected
    for shift, expected in [(0, False), (600, False), (601, True), (7200, True)]:
        assert evaluate(conditions['arrival-time-shift'], **dict(base, shift=shift)) == expected
    for after, expected in [(200, False), (285, False), (286, True), (400, True)]:
        assert evaluate(conditions['capture-cost-increase'], **dict(base, afterCost=after)) == expected
    assert evaluate(conditions['planned-encounter-missing'], **dict(base, planned=0))
    assert 'findArrivalPatch(0, targetBody)' in gate
    assert 'findArrivalPatch(nd, targetBody)' in gate
    assert 'POSITIONAT(' not in gate

    shape = body(SHAPE, '_shapeReserveBurn')
    allow = re.search(r'LOCAL allowed IS (.*?)\.', shape, re.S)[1]
    env = dict(cost=10, spent=0, remaining=700,
               SHAPE_DV_CAP=10, SHAPE_TOTAL_DV_CAP=20, SHAPE_RESERVE_DV=650)
    assert evaluate(allow, **env)
    for changed in (dict(cost=150), dict(spent=11), dict(remaining=659)):
        assert not evaluate(allow, **(env | changed))
    print('PASS: saved 150 m/s node, encounter shift/capture cost and downstream SHAPE rejection')


def check_capture_estimate():
    source = body(BPLANE, 'bplaneCaptureCost')
    for vinf in (100, 300, 600):
        for pe in (15000, 50000):
            radius, mu, ap = 200000, 6.5138398e10, 100000
            rp = radius + pe
            env = dict(targetBody=NS(RADIUS=radius, MU=mu),
                       patch=NS(PERIAPSIS=pe, ECCENTRICITY=1 + rp * vinf**2 / mu),
                       TARGET_AP=ap, SQRT=math.sqrt)
            for name in ('rp', 'apAlt', 'ra', 'incoming', 'captured'):
                expr = re.search(rf'LOCAL {name} IS (.*?)\.', source)[1]
                env[name] = evaluate(expr, **env)
                if name == 'apAlt':
                    expr = re.search(r'SET apAlt TO (.*?)\.', source)[1]
                    env[name] = evaluate(expr, **env)
            actual = evaluate(re.search(r'RETURN (MAX.*?)\.', source)[1], **env)
            expected = math.sqrt(vinf**2 + 2*mu/rp) - math.sqrt(mu*(2/rp - 2/(rp+radius+ap)))
            assert math.isclose(actual, expected, abs_tol=1e-9)
    print('PASS: capture-cost estimates against independent vis-viva fixtures')


def check_logging_and_integration():
    log = body(LOGS, 'mLog')
    persist = re.search(r'LOCAL persist IS (.*?)\.', log, re.S)[1]
    for level, message, verbose, expected in [
            ('INFO', 'STATS bplane plan dv=150', 0, True),
            ('INFO', 'solver iteration', 0, False),
            ('INFO', 'solver iteration', 1, True),
            ('WARN', 'budget hold', 0, True),
            ('PHASE', 'BPLANE', 0, True)]:
        assert evaluate(persist, level=level, message=NS(STARTSWITH=message.startswith),
                        LOG_INFO_TO_FILE=verbose) == expected
    space = re.search(r'LOCAL enoughSpace IS (.*?)\.', log, re.S)[1]
    assert evaluate(space, CORE=NS(VOLUME=NS(FREESPACE=2000)),
                    LOG_FILE_RESERVE_BYTES=1024, line=NS(LENGTH=200))
    assert not evaluate(space, CORE=NS(VOLUME=NS(FREESPACE=1200)),
                        LOG_FILE_RESERVE_BYTES=1024, line=NS(LENGTH=200))
    assert 'IF persist AND enoughSpace' in log
    assert 'IF wroteLocal AND HOMECONNECTION:ISCONNECTED' in log
    hold = body(BPLANE, '_bplaneHoldCorrection')
    assert 'REMOVE NEXTNODE' in hold and 'yieldToPrompt()' in hold
    planner = body(BPLANE, 'planBplaneCorrection')
    assert planner.index('existing-patch-unmeasurable') < planner.index('_acquireEncounter(')
    assert 'IF NOT converged AND NOT acquired' in planner
    assert 'unconverged-optional-correction' in planner
    for phase in ('phaseBplane', 'phaseRefineBplane'):
        source = body(BPLANE, phase)
        assert source.index('bplaneCorrectionAllowed(') < source.index('executeManeuver()')
        assert source.index('_bplaneReserveCorrection(') < source.index('executeManeuver()')
        assert source.count('IF phaseShouldYield { RETURN. }') == 2
        assert '_bplaneLogBaseline(' in source
    existing = body(BPLANE, '_bplaneExistingNodeAcceptable')
    assert 'bplaneCorrectionAllowed(nd, targetBody, phaseCap)' in existing
    reserve = body(BPLANE, '_bplaneReserveCorrection')
    assert 'stateSet("bplane_budget_spent"' in reserve
    shape_run = body(SHAPE, '_runShapePhase')
    assert shape_run.index('_shapeReserveBurn(NEXTNODE)') < shape_run.index('executeManeuver()')
    print('PASS: persisted STATS/storage reserve, missing-measurement hold, pre-ignition and resume guards')


if __name__ == '__main__':
    check_budget()
    check_decisions()
    check_capture_estimate()
    check_logging_and_integration()
