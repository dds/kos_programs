"""Regression guards for cached source execution used by the flight fixtures."""
import ast
import math
from pathlib import Path
import tempfile
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_deorbit_geometry import Vec, cross, evaluate
from run_checks import instrument


def check_live_values_and_literals():
    env = dict(value=1, obj=NS(ALT=2))
    expr = 'LEXICON("0:/TRUE", value + obj:ALT, "text", "a   b:FALSE\\path")'
    assert evaluate(expr, env) == {'0:/TRUE': 3, 'text': 'a   b:FALSE\\path'}
    env['value'], env['obj'].ALT = 10, 20
    assert evaluate(expr, env)['0:/TRUE'] == 30
    env['MIN'] = lambda *args: 17
    assert evaluate('MIN(1, 2)', env) == 17
    assert evaluate('TRUE AND NOT FALSE AND 2^3 = 8 AND 2 <> 3', env)
    rng = np.random.default_rng(42)
    for _ in range(100):
        a, b = (Vec(rng.normal(size=3)) for _ in range(2))
        np.testing.assert_array_equal(cross(a, b), np.cross(a, b))
        assert math.isclose(a.MAG, np.linalg.norm(a), rel_tol=1e-15)
    print('PASS: cached expressions retain live values, helper overrides, literal whitespace/paths, and 3D vector arithmetic')


def check_control_flow():
    events = []
    env = dict(values=[1, 2, 3], flag=True, target=NS(value=0), box={},
               fixture_wait=lambda value: events.append(('wait', value)),
               fixture_add=lambda value: events.append(('add', value)),
               fixture_lock=lambda value: events.append(('lock', value)),
               stage_event=lambda: events.append(('stage',)),
               engine=NS(ACTIVATE=lambda: events.append(('activate',)),
                         SHUTDOWN=lambda: events.append(('shutdown',))))
    nodes = ks.parse('''PARAMETER missing IS 3. PARAMETER zero IS 9.
        LOCAL total IS 0.
        FOR item IN values {
            UNTIL total >= missing {
                SET total TO total + item.
                IF item = 2 { BREAK. }
            }
            IF item = 2 { BREAK. }
        }
        IF flag { SET target:value TO total. }
        ELSE IF zero = 0 { SET target:value TO -1. }
        ELSE { SET target:value TO -2. }
        SET box["total"] TO total. WAIT 0. ADD total.
        LOCK THROTTLE TO total. STAGE. engine:ACTIVATE. engine:SHUTDOWN.
        IF FALSE { WAIT UNTIL not_supported. PRINT "never executed". }
        RETURN total + zero.''')
    env['zero'] = 0
    for flag, expected in ((True, 3), (False, -1)):
        env['flag'] = flag
        try:
            ks.run(nodes, env)
        except ks.Returned as result:
            assert result.value == 3
        else:
            raise AssertionError('RETURN lost')
        assert env['target'].value == expected and env['box']['total'] == 3
        assert not any(key.startswith('__fixture_') for key in env)
    assert events[:6] == [('wait', 0), ('add', 3), ('lock', 'LOCK THROTTLE TO total'),
                          ('stage',), ('activate',), ('shutdown',)]
    # Public run accepts edited lists: a previous compiled tree cannot mask an edit.
    nodes = ks.parse('SET result TO 1.')
    ks.run(nodes, env)
    nodes[0] = ('SET result TO 2', [], [])
    ks.run(nodes, env)
    assert env['result'] == 2
    for source, exception in (('PARAMETER required.', AssertionError), ('BREAK.', ks.Broken),
                              ('UNTIL FALSE { SET looped TO TRUE. }', AssertionError)):
        try:
            ks.run(ks.parse(source), {})
        except exception:
            pass
        else:
            raise AssertionError(source)
    print('PASS: compiled fixtures retain defaults, nested loops/breaks, return, live branches, mutation, callbacks and convergence guards')


def check_function_cache():
    original = ks.SOURCES
    try:
        ks.SOURCES = 'LOCAL FUNCTION fixtureProbe { PARAMETER ctx. PARAMETER value IS 7. SET ctx["seen"] TO value. LOCAL private IS 5. RETURN value. }'
        ctx, env = {}, dict(value=0)
        assert ks.call('fixtureProbe', env, ctx) == 0  # Existing fixture env/default semantics.
        assert ctx['seen'] == 0 and 'private' not in env
        assert ks.call('fixtureProbe', {}, ctx) == 7
        ks.SOURCES = ks.SOURCES.replace('RETURN value.', 'RETURN value + 1.')
        assert ks.call('fixtureProbe', {}, ctx) == 8
    finally:
        ks.SOURCES = original
    print('PASS: function locals stay isolated, shared context mutates and changed source invalidates cached code')


def check_timing_instrumentation():
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp)/'check_fixture.py'
        path.write_text('''def check_case(value):
    if value == 2: raise AssertionError('failure survives')
if __name__ == '__main__':
    for value in (1, 2): check_case(value)
''')
        entries = []
        def wrap(fn):
            def wrapped(value):
                entries.append(value)
                return fn(value)
            return wrapped
        tree = instrument(path)
        assert isinstance(tree, ast.Module)
        try:
            exec(compile(tree, str(path), 'exec'), dict(__name__='__main__', __check_timed=wrap))
        except AssertionError as error:
            assert str(error) == 'failure survives'
        else:
            raise AssertionError('timing swallowed a failed check')
        assert entries == [1, 2]
    print('PASS: timing instrumentation executes every parameterized main-block case and propagates failures')


if __name__ == '__main__':
    check_live_values_and_literals()
    check_control_flow()
    check_function_cache()
    check_timing_instrumentation()
