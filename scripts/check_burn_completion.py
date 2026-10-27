"""Cutoff/settling boundary and explicit SHAPE recovery; source fixtures, not KSP."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_burn_watchdog import fixture as governor_fixture, SOURCE

RETRY = (ROOT/'cmd/shaperetry.ks').read_text()


def execute(source, env):
    source = re.sub(r'PARAMETER [^.]+\.', '', source)
    def strip(nodes):
        return [(text, strip(yes), strip(no)) for text, yes, no in nodes
                if not text.startswith('PRINT ')]
    try:
        ks.run(strip(ks.parse(source)), env)
    except ks.Returned as result:
        return result.value


def final_guard(env, residual, reason='live-node-trim', cutoff_rem=.00099, fault='', rebound=False):
    fn = function_body(SOURCE, 'executeManeuver')
    guard = fn[fn.index('LOCAL finalResidualLimit'):fn.index('// Compact evidence')]
    state = {}
    env.update(res=residual, liveCutoff=dict(reason=reason, rem=cutoff_rem),
               burnAbort=fault, burnAbortDetail='', burnCompleteReason=reason,
               fixedBurnVector=False, dra=rebound,
               stateSet=lambda key, value: state.update({key:value}),
               _fs=lambda number, places: str(round(number, places)))
    env['_burnFinalResidualLimit'] = lambda cutoff: execute(
        function_body(SOURCE, '_burnFinalResidualLimit'), dict(env, cutoff=cutoff))
    execute(guard, env)
    return env['burnAbort'], env['finalResidualLimit'], state


def check_latched_trim_after_settling():
    for residual, accepted in ((.001000001, True), (.0012, True), (.001499999, True),
                               (.0015, True), (.001500001, False), (.01, False)):
        env, cutoff, node, command = governor_fixture(acc=.8, cap=.08)
        env['BURN_TRIM_ABS_COMPLETE_DV'] = .001
        node.DELTAV = ks.Vec((.00099, 0, 0))
        assert command(1) == 0 and cutoff['reason'] == 'live-node-trim'
        # The real governor stays OFF despite later node drift during the
        # physical cutoff verification; classify that later sample separately.
        env['TIME'].SECONDS += .25
        node.DELTAV = ks.Vec((residual, 0, 0))
        assert command(1) == 0
        fault, limit, state = final_guard(env, residual, cutoff_rem=cutoff['rem'])
        assert limit == .0015
        assert (fault == '') == accepted, (residual, fault)
        assert bool(state) == (not accepted)
    print('PASS: real governor latches valid0.001 trim; actual final guard accepts bounded settling up to0.0015 but rejects larger residuals, without reignition')


def check_completion_evidence_and_faults():
    env, _, _, _ = governor_fixture()
    env['BURN_TRIM_ABS_COMPLETE_DV'] = .001
    for reason, sample in (('', .00099), ('live-thrust-axis-trim', .00099),
                           ('live-vector-passed-target', .00099), ('live-residual-rebound', .00099),
                           ('live-impulse-limit', .00099), ('live-command-stale', .00099),
                           ('live-node-trim', -1), ('live-node-trim', math.nan),
                           ('live-node-trim', math.inf), ('live-node-trim', .00101)):
        fault, limit, _ = final_guard(env, .0012, reason, sample)
        assert limit == .001 and fault == 'residual-outside-tolerance', (reason, sample)
    for original in ('thrust-after-cutoff', 'live-operator-abort', 'invalid-node-residual', 'live-command-stale'):
        fault, _, _ = final_guard(env, .0012, fault=original)
        assert fault == original
    assert final_guard(env, .0012, rebound=True)[0] == 'dv-rebound'
    env['BURN_TRIM_ABS_COMPLETE_DV'] = .05
    assert final_guard(env, .0509, cutoff_rem=.049)[0] == ''
    assert final_guard(env, .0511, cutoff_rem=.049)[0] == 'residual-outside-tolerance'
    assert final_guard(env, .0509, reason='live-thrust-axis-trim', cutoff_rem=.049)[0] == 'residual-outside-tolerance'
    fn = function_body(SOURCE, 'executeManeuver')
    assert fn.index('LOCAL cutoffCheck IS _burnVerifyCutoff()') < fn.index('LOCAL finalResidualLimit')
    assert fn.index('SET burnAbort TO "residual-outside-tolerance"') < fn.index('stateSet("last_burn_report"')
    assert '_fs(liveCutoff["rem"],9)' in fn and '_fs(finalResidualLimit,9)' in fn
    print('PASS: no allowance for missing/invalid/axis/reversal/rebound evidence; forced-cutoff/watchdog/invalid-data faults survive; allowance caps at0.001 and report records final failure with9-place residuals')


def retry_fixture():
    state = dict(phase='SHAPE', burn_phase='SHAPE', burn_body='Minmus',
                 burn_pending='true', burn_started='true', burn_node_time=1000,
                 burn_status='interrupted', burn_abort_reason='residual-outside-tolerance',
                 mission_id='minmus_kolniya_flats_return', shape_budget_spent=25,
                 last_burn_report='valid trim, late residual drift', launch_time=100)
    node = NS(TIME=1000)
    ship = NS(BODY=NS(NAME='Minmus', ATM=NS(EXISTS=False)), STATUS='ORBITING',
              PERIAPSIS=10260, THRUST=0, ORBIT=NS(ECCENTRICITY=.7, HASNEXTPATCH=False),
              CONTROL=NS(MAINTHROTTLE=0, PILOTMAINTHROTTLE=0))
    removed = []
    def remove_prefix(prefix):
        for key in list(state):
            if key.startswith(prefix): del state[key]
    env = dict(SHIP=ship, ABORT=False, HASNODE=True, NEXTNODE=node,
               stateGet=state.get, stateGetNum=state.get, stateRemovePrefix=remove_prefix,
               fixture_remove=removed.append, fixture_settle=lambda: None)
    env['ready'] = lambda: execute(function_body(RETRY, 'ready'), dict(env))
    return env, state, removed


def retry(env):
    code = function_body(RETRY, 'resetShape')
    code = code.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.', 'fixture_settle().')
    code = code.replace('REMOVE NEXTNODE.', 'fixture_remove(NEXTNODE).')
    return execute(code, env)


def check_shape_recovery():
    for has_node in (True, False):
        env, state, removed = retry_fixture()
        env['HASNODE'] = has_node
        before = {key:value for key,value in state.items() if not key.startswith('burn_')}
        assert retry(env)
        assert state == before and len(removed) == int(has_node)
    changes = (
        lambda env,state: state.update(phase='XING'),
        lambda env,state: state.update(burn_phase='CAPTURE'),
        lambda env,state: state.update(burn_body='Mun'),
        lambda env,state: state.update(burn_started='false'),
        lambda env,state: state.update(burn_pending='false'),
        lambda env,state: env.update(ABORT=True),
        lambda env,state: setattr(env['SHIP'], 'STATUS', 'SUB_ORBITAL'),
        lambda env,state: setattr(env['SHIP'], 'PERIAPSIS', -1),
        lambda env,state: setattr(env['SHIP'].ORBIT, 'HASNEXTPATCH', True),
        lambda env,state: setattr(env['SHIP'].ORBIT, 'ECCENTRICITY', 1),
        lambda env,state: setattr(env['SHIP'], 'THRUST', 1),
        lambda env,state: setattr(env['SHIP'].CONTROL, 'MAINTHROTTLE', .1),
        lambda env,state: setattr(env['SHIP'].CONTROL, 'PILOTMAINTHROTTLE', .1),
        lambda env,state: setattr(env['NEXTNODE'], 'TIME', 2000),
        lambda env,state: setattr(env['NEXTNODE'], 'TIME', math.nan),
        lambda env,state: setattr(env['SHIP'].BODY, 'ATM', NS(EXISTS=True, HEIGHT=70000)),
    )
    for change in changes:
        env, state, removed = retry_fixture()
        change(env, state)
        before = dict(state)
        assert not retry(env)
        assert state == before and not removed
    env, state, removed = retry_fixture()
    before = dict(state)
    env['fixture_settle'] = lambda: setattr(env['SHIP'], 'THRUST', 1)
    assert not retry(env) and state == before and not removed
    assert RETRY.index('bootPreamble().') < RETRY.index('stateRemovePrefix("burn_")')
    assert all(token not in RETRY for token in ('executeManeuver(', 'missionOverrideClear(', 'nextPhase(', 'STAGE.'))
    print('PASS: explicit SHAPE retry removes only its matching node/attempt, preserves spent budget/mission/last report, refuses16 unsafe or unrelated cases and rechecks after warp settles; no burn/advance')


def check_interrupted_shape_preserves_node():
    from check_shape_precision import phase_fixture, execute as execute_shape
    from check_shape_minimum import Lex, SOURCE as SHAPE
    for already_interrupted in (True, False):
        env, targets, removed, events = phase_fixture()
        node = NS(DELTAV=NS(MAG=.0234), ETA=1000)
        started = [already_interrupted]
        plans = []
        def burn():
            started[0] = True
            return False
        env.update(HASNODE=not already_interrupted, NEXTNODE=node,
                   maneuverBurnInterrupted=lambda: started[0],
                   shapeErrors=lambda _: Lex(AP=-770, PE=960), shapeConverged=lambda _: False,
                   _shapeReserveBurn=lambda _: True, executeManeuver=burn)
        # No existing node when initially planning; the planner attaches it.
        env['HASNODE'] = already_interrupted
        def attach(_):
            plans.append(True)
            env['HASNODE'] = True
            return Lex(node=node, label='set-ap')
        env['shapeNextBurn'] = attach
        env['_shapeInterruptedHold'] = lambda label: execute(
            function_body(SHAPE, '_shapeInterruptedHold'), dict(env, phaseLabel=label))
        execute_shape('_runShapePhase', env)
        assert events == ['hold'] and env['HASNODE'] and not removed
        assert len(plans) == int(not already_interrupted)
        assert env['BURN_TRIM_ABS_COMPLETE_DV'] == .05
        assert env['BURN_TRIM_COMPLETE_MAX_DV'] == .05
    print('PASS: interrupted SHAPE holds at entry and immediately after a failed flown burn, restores precision, retains node, and never spends retry waits or silently replaces the plan')


if __name__ == '__main__':
    check_latched_trim_after_settling()
    check_completion_evidence_and_faults()
    check_shape_recovery()
    check_interrupted_shape_preserves_node()
