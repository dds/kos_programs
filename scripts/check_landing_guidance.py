"""Execute a small KerboScript subset against landing fixtures, not the kOS VM.

No attitude dynamics, terrain mesh, physics scheduling or engine lag is modeled.
Run: python3 -B scripts/check_landing_guidance.py
"""
import math
import re
from functools import lru_cache
from pathlib import Path
from types import SimpleNamespace as NS
from check_deorbit_geometry import Vec, evaluate, dot, python_expression, EVAL_GLOBALS
from check_launch_and_staging import body

ROOT = Path(__file__).resolve().parents[1]
SOURCES = '\n'.join((ROOT / ('lib/' + name + '.ks')).read_text() for name in
                    ('landing_math', 'landing_config', 'landing_main', 'landing_coast', 'landing_terminal', 'landing_brake', 'landing_divert', 'landing_disposal', 'vessel_hardware'))


def tokens(source):
    source = re.sub(r'"[^"\n]*"|//[^\n]*', lambda m: '' if m[0].startswith('//') else m[0], source)
    result, current, quoted = [], '', False
    for i, char in enumerate(source):
        if char == '"':
            quoted = not quoted
        if not quoted and char in '{}':
            if current.strip(): result.append(current.strip())
            result.append(char)
            current = ''
        elif not quoted and char == '.' and (i+1 == len(source) or not source[i+1].isdigit()):
            if current.strip(): result.append(current.strip())
            current = ''
        else:
            current += char
    return result


def parse(source):
    stream = iter(tokens(source))
    items = list(stream)
    index = 0
    def block():
        nonlocal index
        nodes = []
        while index < len(items) and items[index] != '}':
            statement = items[index]
            index += 1
            if statement.startswith(('IF ', 'UNTIL ', 'FOR ')):
                assert items[index] == '{', statement
                index += 1
                children = block()
                index += 1
                other = []
                if index < len(items) and items[index] == 'ELSE':
                    index += 2  # ELSE {
                    other = block()
                    index += 1
                elif index < len(items) and items[index].startswith('ELSE IF '):
                    # Turn the chained condition into a nested IF in the else branch.
                    items[index] = items[index][5:]
                    other = one_if()
                nodes.append((statement, children, other))
            else:
                nodes.append((statement, [], []))
        return nodes
    def one_if():
        nonlocal index
        statement = items[index]
        index += 2
        children = block()
        index += 1
        other = []
        if index < len(items) and items[index] == 'ELSE':
            index += 2
            other = block()
            index += 1
        elif index < len(items) and items[index].startswith('ELSE IF '):
            items[index] = items[index][5:]
            other = one_if()
        return [(statement, children, other)]
    return block()


class Returned(Exception):
    def __init__(self, value): self.value = value


class Broken(Exception):
    pass


def freeze(nodes):
    return tuple((statement, freeze(yes), freeze(no)) for statement, yes, no in nodes)


@lru_cache(maxsize=1024)
def compile_nodes(nodes):
    """Translate the same fixture subset once, rather than interpret each tick.

    This is Python fixture code, not a kOS compiler. Keep parse/run available
    for checks that filter source statements or mutate a parsed tree.
    """
    lines, counters = [], []
    def expression(source):
        try:
            compile(python_expression(source), '<fixture expression>', 'eval')
        except SyntaxError:
            return f'__fixture_evaluate({source!r}, __fixture_env)'
        return python_expression(source)
    def emit(text, indent):
        lines.append('    '*indent + text)
    def block(items, indent):
        if not items:
            emit('pass', indent)
        for statement, yes, no in items:
            if statement.startswith('IF '):
                emit('if ' + expression(statement[3:]) + ':', indent)
                block(yes, indent+1)
                if no:
                    emit('else:', indent)
                    block(no, indent+1)
            elif statement.startswith(('FOR ', 'UNTIL ')):
                if statement.startswith('FOR '):
                    match = re.fullmatch(r'FOR (\w+) IN (.*)', statement, re.S)
                    emit(f'for {match[1]} in {expression(match[2])}:', indent)
                else:
                    counter = f'__fixture_steps_{len(counters)}'
                    counters.append(counter)
                    emit(f'{counter} = 0', indent)
                    emit('while not (' + expression(statement[6:]) + '):', indent)
                emit('try:', indent+1)
                block(yes, indent+2)
                emit('except __fixture_Broken:', indent+1)
                emit('break', indent+2)
                if statement.startswith('UNTIL '):
                    emit(f'{counter} += 1', indent+1)
                    emit(f'assert {counter} < 10000, "fixture loop did not converge"', indent+1)
            elif statement.startswith('PARAMETER '):
                match = re.fullmatch(r'PARAMETER (\w+)(?: IS (.*))?', statement, re.S)
                emit(f'if not __fixture_has({match[1]!r}):', indent)
                if match[2] is None:
                    emit(f'raise __fixture_AssertionError({statement!r})', indent+1)
                else:
                    emit(f'{match[1]} = {expression(match[2])}', indent+1)
            elif statement.startswith(('LOCAL ', 'SET ')):
                match = re.fullmatch(r'(?:LOCAL (.*?) IS|SET (.*?) TO) (.*)', statement, re.S)
                assert match, statement
                emit('fixtureValue = ' + expression(match[3]), indent)
                emit((match[1] or match[2]).replace(':', '.') + ' = fixtureValue', indent)
            elif statement.startswith('RETURN'):
                value = expression(statement[7:]) if statement != 'RETURN' else 'None'
                emit(f'raise __fixture_Returned({value})', indent)
            elif statement == 'BREAK':
                emit('raise __fixture_Broken()', indent)
            elif statement.startswith(('WAIT ', 'ADD ')):
                kind, expr = statement.split(' ', 1)
                emit(f'fixture_{"wait" if kind == "WAIT" else "add"}({expression(expr)})', indent)
            elif statement.startswith(('mLog', '_landingHud')):
                emit('pass', indent)
            elif statement == 'STAGE':
                emit('stage_event()', indent)
            elif statement.startswith('LOCK '):
                emit(f'fixture_lock({statement!r})', indent)
            else:
                expr = statement + '()' if statement.endswith((':ACTIVATE', ':SHUTDOWN')) else statement
                # Unsupported primitives in unvisited branches remain lazy,
                # just as with the old interpreter.
                try:
                    compile(python_expression(expr), '<fixture statement>', 'eval')
                except SyntaxError:
                    emit(f'__fixture_evaluate({expr!r}, __fixture_env)', indent)
                else:
                    emit(python_expression(expr), indent)
    block(nodes, 0)
    return compile('\n'.join(lines), '<KerboScript control fixture>', 'exec'), tuple(counters)


def execute(compiled, env):
    code, counters = compiled
    helpers = dict(EVAL_GLOBALS, __fixture_Returned=Returned, __fixture_Broken=Broken,
                   __fixture_AssertionError=AssertionError, __fixture_has=env.__contains__,
                   __fixture_evaluate=evaluate, __fixture_env=env)
    # Generated loop counters must not leak into an externally inspected env.
    previous = {key: env[key] for key in counters if key in env}
    try:
        exec(code, helpers, env)
    finally:
        for key in counters:
            env.pop(key, None)
        env.update(previous)


def run(nodes, env):
    execute(compile_nodes(freeze(nodes)), env)


PARSED = {}
PARSED_SOURCE = None


def call(name, env, *args):
    global PARSED_SOURCE
    if SOURCES is not PARSED_SOURCE:
        PARSED.clear()
        PARSED_SOURCE = SOURCES
    if name not in PARSED:
        source = body(SOURCES, name)
        params = re.findall(r'PARAMETER (\w+)', source)
        PARSED[name] = (params, compile_nodes(freeze(parse(source))))
    params, compiled = PARSED[name]
    local = dict(env, **dict(zip(params, args)))
    try:
        execute(compiled, local)
    except Returned as result:
        return result.value


def environment():
    env = dict(landingReviewReachableSite=lambda *args: True, ABORT=False,
               SQRT=math.sqrt, TAN=lambda x: math.tan(math.radians(x)),
               SIN=lambda x: math.sin(math.radians(x)), COS=lambda x: math.cos(math.radians(x)),
               CONSTANT=NS(PI=math.pi), TIME=NS(SECONDS=0), SHIP=NS(BODY=NS(RADIUS=60000)))
    for name, value in re.findall(r'GLOBAL (\w+) IS ([^\n]+)\.', SOURCES):
        try: env[name] = evaluate(value, env)
        except (NameError, SyntaxError, AttributeError): pass
    for name in ('lmApproachAcceleration', 'lmApproachDescentSpeed', 'lmApproachSteering',
                 'lmDescentSpeed', 'lmVerticalThrottle', 'landingTerrainGrade'):
        env[name] = lambda *args, name=name: call(name, env, *args)
    return env


def check_coast():
    env = environment()
    for maximum, minimum, expected in ((0, .02, 0), (.01, .02, .01), (.1, .02, .1), (-1, .02, 0)):
        env.update(LANDING_COAST_MCC_THROTTLE_MAX=maximum, LANDING_COAST_MCC_THROTTLE_MIN=minimum)
        assert call('_landingCoastMccThrottle', env, 300) == expected
    ctx = {}
    env.update(LANDING_COAST_MCC_THROTTLE_MAX=0,
               _landingSetThrottle=lambda c, x: c.update(throttle=x),
               _landingSetState=lambda c, state, reason: c.update(state=state))
    call('_landingCoastMccTick', env, ctx)
    assert ctx == dict(throttle=0, state='COAST')
    coast = body(SOURCES, '_landingCoastTick')
    assert 'IF LANDING_COAST_MCC_THROTTLE_MAX > 0 AND ctx["HAS_TARGET"]' in coast
    print('PASS: disabled coast MCC commands zero; minimum never overrides maximum')


def check_terrain():
    env = environment()
    requests = []
    slope = math.tan(math.radians(2))
    def geo(lat, lng):
        north, east = lat*60000*math.pi/180, lng*60000*math.pi/180
        requests.append((north, east))
        return NS(TERRAINHEIGHT=slope*north)
    env.update(LATLNG=geo, TERRAIN_CHECK_RADIUS=500, TERRAIN_CHECK_STEP=100,
               ADDONS=NS(TR=NS(AVAILABLE=False)),
               geoDistance=lambda a,b,c,d: math.hypot(a-c,b-d)*60000*math.pi/180)
    result = call('_landingTerrainCheck', env, 0, 0)
    assert not result['SHIFTED'] and result['LAT'] == result['LNG'] == 0
    assert len(requests) == 5  # Center and its four neighbors; no pointless grid hunt.
    requests.clear()
    slope = math.tan(math.radians(10))
    env['TERRAIN_CHECK_RADIUS'] = 20
    result = call('_landingTerrainCheck', env, 0, 0)
    assert not result['SHIFTED']  # Uniform slope: no forced move to the SW corner.
    assert max(abs(n) for n,e in requests) <= 40.01
    assert max(abs(e) for n,e in requests) <= 40.01
    print('PASS: acceptable center retained; 20 m final grid works with 100 m configured spacing')


def control_environment():
    env = environment()
    ctx = dict(TARGET_LAT=0, TARGET_LNG=0, UP_VEC=Vec((0,0,1)), POSITION=Vec((305,0,1000)),
               DIVERT_PENDING=False, DIVERT_SEARCH={},
               H_VEL=Vec((0,0,0)), H_SPEED=0, V_SPEED=-10, MAX_ACC=.491*7.45, GRAV=.491,
               STATE_ENTERED=0, TARGET_REFINE_LOGGED=True, TARGET_REFINE_CLIMB_SINCE=0,
               HOVER_REFINED=False, HOVER_TERRAIN_DONE=True, HOVER_HOLD_BOTTOM=15)
    env.update(MAX_TILT=12, LATLNG=lambda *args: NS(POSITION=Vec((0,0,0))),
               _landingTargetHeight=lambda c: c['POSITION'][2],
               _landingBottomRadar=lambda: ctx['POSITION'][2],
               _landingSetState=lambda c, state, reason: c.update(state=state),
               _landingSetThrottle=lambda c, x: c.update(throttle=x),
               _landingSetSteering=lambda c, x: c.update(steering=x),
               _landingFinalTerrainCheck=lambda c: None,
               lmDistanceToTarget=lambda *args: abs(ctx['POSITION'][0]),
               lmGravity=lambda: ctx['GRAV'],
               lmDirectionToTarget=lambda lat,lng,up,pos: Vec((-1 if pos[0] > 0 else 1,0,0)),
               _landingBoolText=lambda x: str(x))
    return env, ctx


def check_handoffs():
    for speed, age, height, expected in ((.5, 0, 1000, 'APPROACH'), (4, 12, 1000, 'APPROACH'),
                                        (8, 21, 1000, 'APPROACH'), (8, 21, 10, 'VERTICAL_DESCENT')):
        env, ctx = control_environment()
        ctx.update(H_SPEED=speed, H_VEL=Vec((speed,0,0)), POSITION=Vec((305,0,height)))
        env['TIME'].SECONDS = age
        call('_landingTargetRefineTick', env, ctx)
        assert ctx['state'] == expected
        assert ctx['HOVER_REFINED'] == (height <= 15)
    for distance, speed, age, exits in ((20,.5,0,True), (100,0,31,True), (100,2,5,False)):
        env, ctx = control_environment()
        ctx.update(POSITION=Vec((distance,0,15)), H_SPEED=speed, H_VEL=Vec((speed,0,0)))
        env['TIME'].SECONDS = age
        call('_landingHoverRefineTick', env, ctx)
        assert (ctx.get('state') == 'VERTICAL_DESCENT') == exits
    print('PASS: 305 m refine miss hands to approach; low-altitude fallback and bounded hover exits')


def check_approach():
    env, ctx = control_environment()
    acceleration = env['lmApproachAcceleration'](ctx['MAX_ACC'],ctx['GRAV'])
    assert 0 < acceleration < ctx['GRAV']*math.tan(math.radians(12))
    assert env['lmApproachAcceleration'](.2,.491) == 0
    for height in (10,15,100,1000):
        paced = env['lmApproachDescentSpeed'](20,height,305,0,acceleration)
        assert 0 <= paced <= 20
        if height > 15: assert paced > 0
    # Source-driven point-mass fixture: this tests command convergence only,
    # assuming instantaneous steering, constant mass/gravity and flat terrain.
    dt = .1
    for step in range(4000):
        call('_landingApproachTick', env, ctx)
        if ctx.get('state'):
            break
        thrust = ctx['steering'] * (ctx['throttle']*ctx['MAX_ACC'])
        vel = Vec((ctx['H_VEL'][0],0,ctx['V_SPEED'])) + (thrust-Vec((0,0,ctx['GRAV'])))*dt
        ctx['POSITION'] = ctx['POSITION'] + vel*dt
        ctx['H_VEL'] = Vec((vel[0],0,0))
        ctx['H_SPEED'], ctx['V_SPEED'] = abs(vel[0]), vel[2]
        assert ctx['POSITION'][2] > 0
        assert dot(ctx['steering'],ctx['UP_VEC']) >= math.cos(math.radians(12))-1e-9
    assert ctx.get('state') == 'VERTICAL_DESCENT', ctx
    assert abs(ctx['POSITION'][0]) <= 30 and ctx['H_SPEED'] <= 1.75
    print(f'PASS: idealized 305 m approach converges to {abs(ctx["POSITION"][0]):.1f} m in {step*dt:.1f} s without hover')


def check_logging():
    main = body(SOURCES, 'landExecute')
    assert main.index('SET LOG_ARCHIVE_DEFERRED TO 1.') < main.index('UNTIL landingAbortFlag')
    end = main[main.index('IF landingAbortFlag {'):]
    assert end.index('vesselLandingCleanup().') < end.index('SET LOG_ARCHIVE_DEFERRED TO priorArchiveDeferral.')
    assert end.index('_landingFinish(ctx)') < end.rindex('SET LOG_ARCHIVE_DEFERRED TO priorArchiveDeferral.')
    logs = (ROOT / 'lib/logs.ks').read_text()
    assert 'IF wroteLocal AND LOG_ARCHIVE_DEFERRED <= 0' in logs
    cleanup = body((ROOT / 'lib/vessel_hardware.ks').read_text(), 'vesselLandingCleanup')
    assert 'thrustCutoffOk()' in cleanup and 'RETURN stopped.' in cleanup
    print('PASS: guidance logs stay local until throttle cleanup; landing cutoff clears pilot throttle before unlock')


if __name__ == '__main__':
    check_coast()
    check_terrain()
    check_handoffs()
    check_approach()
    check_logging()
