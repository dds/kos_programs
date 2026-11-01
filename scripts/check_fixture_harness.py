"""Regression guards for cached source execution used by the flight fixtures."""
import ast
import argparse
from contextlib import redirect_stdout
import io
import math
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace as NS
from unittest.mock import patch

import numpy as np

import check_landing_guidance as ks
from check_deorbit_geometry import Vec, cross, evaluate
from check_codebase import function_body
from check_minmus_kolniya import execute as run_adapted
from run_checks import instrument, run_files, worker_environment, positive_jobs


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


def check_immutable_source_caches():
    source='LOCAL FUNCTION probe { RETURN value + 1. }'
    body=function_body(source,'probe')
    env=dict(value=2)
    for current,result in ((source,3),(source.replace('+ 1','+ 2'),4),(source,3)):
        extracted=function_body(current,'probe')
        code=ks.compile_source(extracted)
        try:ks.execute(code,env)
        except ks.Returned as returned:assert returned.value==result
        else:raise AssertionError('cached source lost RETURN')
    env['value']=8
    try:ks.execute(ks.compile_source(body),env)
    except ks.Returned as returned:assert returned.value==9
    else:raise AssertionError('cached source reused a result')
    # A caller can still edit a public parsed tree without poisoning source caches.
    tree=ks.parse(body);tree[0]=('RETURN 99',[],[])
    assert run_adapted(body,env)==9
    assert run_adapted(body.replace('+ 1','+ 2'),env)==10
    env['fixture_unlock']=lambda:env.update(unlocked=True)
    assert run_adapted('UNLOCK STEERING. PRINT "ignored menu". RETURN value.',env)==8
    assert env['unlocked']
    print('PASS: exact-source caches preserve edits, live values, returns and menu/unlock adaptation without sharing mutable parse trees or result values')


def check_nested_execution_and_live_helpers():
    env=dict(outer=0,inner=0,__fixture_steps_0=123)
    def nested():
        ks.run(ks.parse('UNTIL inner >= 2 { SET inner TO inner + 1. }'),env)
    env['nested']=nested
    ks.run(ks.parse('UNTIL outer >= 2 { nested(). SET outer TO outer + 1. }'),env)
    assert env==dict(outer=2,inner=2,__fixture_steps_0=123,nested=nested,fixtureValue=2)
    code=ks.compile_source('RETURN MIN(2,3).')
    original=ks.EVAL_GLOBALS['MIN']
    try:
        for result in (5,7):
            ks.EVAL_GLOBALS['MIN']=lambda *_,result=result:result
            try:ks.execute(code,{})
            except ks.Returned as returned:assert returned.value==result
            else:raise AssertionError('live global helper was cached')
        try:ks.execute(code,dict(MIN=lambda *_:11))
        except ks.Returned as returned:assert returned.value==11
        else:raise AssertionError('local helper override was hidden')
    finally:ks.EVAL_GLOBALS['MIN']=original
    print('PASS: nested execution restores outer loop counters, leaves no private context references and observes both live global and local helper overrides')


def check_isolated_parallel_runner():
    with tempfile.TemporaryDirectory(prefix='kos-runner-check-') as temp:
        root=Path(temp);paths=[]
        for name in ('a','b','c'):
            path=root/f'check_{name}.py'
            path.write_text('import builtins\n'
                'def check_case():\n'
                '    assert not hasattr(builtins, "_kos_fixture_seen")\n'
                '    builtins._kos_fixture_seen=True\n'
                f'    print("output-{name}")\n'
                +('    raise AssertionError("expected runner failure")\n' if name=='b' else '')
                +"if __name__ == '__main__':\n    check_case()\n")
            paths.append(path)
        for jobs in (1,2):
            result_dir=root/f'results-{jobs}';result_dir.mkdir()
            output=io.StringIO()
            with redirect_stdout(output):rows=run_files(paths,'fast',jobs,result_dir)
            assert [row['module'] for row in rows]==[path.name for path in paths]
            assert [row['returncode'] for row in rows]==[0,1,0]
            assert all([case['case'] for case in row['cases']]==['check_case'] for row in rows)
            text=output.getvalue()
            assert text.index('output-a')<text.index('output-b')<text.index('output-c')
            assert 'expected runner failure' in text and 'Traceback' in text
    print('PASS: serial/parallel runners retain isolated globals, ordered output, all case timings and failures, and continue after a failed file')


def check_worker_thread_limits():
    with patch.dict(os.environ,{},clear=True):
        env=worker_environment()
        assert all(env[key]=='1' for key in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','MKL_NUM_THREADS'))
    with patch.dict(os.environ,dict(OPENBLAS_NUM_THREADS='3',OMP_NUM_THREADS='2',MKL_NUM_THREADS='4')):
        env=worker_environment()
        assert [env[key] for key in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','MKL_NUM_THREADS')]==['3','2','4']
    with patch.dict(os.environ,dict(MAKEFLAGS='--jobs=8',MAKELEVEL='2',SHLVL='9',CODEX_TOOL_CALL_ID='transient',CUSTOM_CHECK_SETTING='retained')):
        env=worker_environment()
        assert not {'MAKEFLAGS','MAKELEVEL','MFLAGS','SHLVL','_','CODEX_TOOL_CALL_ID'} & env.keys()
        assert env['CUSTOM_CHECK_SETTING']=='retained'
    assert positive_jobs('1')==1 and positive_jobs('4')==4
    try:positive_jobs('0')
    except argparse.ArgumentTypeError:pass
    else:raise AssertionError('zero workers accepted')
    print('PASS: worker BLAS pools default to one thread, explicit developer settings survive and zero-worker requests reject')


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
    check_immutable_source_caches()
    check_nested_execution_and_live_helpers()
    check_isolated_parallel_runner()
    check_worker_thread_limits()
    check_timing_instrumentation()
