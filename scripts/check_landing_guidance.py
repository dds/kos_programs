"""Execute a small KerboScript subset against landing fixtures, not the kOS VM.

No attitude dynamics, terrain mesh, physics scheduling or engine lag is modeled.
Run: python3 -B scripts/check_landing_guidance.py
"""
import math
import re
from pathlib import Path
from types import SimpleNamespace as NS
from check_deorbit_geometry import Vec, evaluate, dot
from check_launch_and_staging import body

ROOT = Path(__file__).resolve().parents[1]
SOURCES = '\n'.join((ROOT / ('lib/' + name + '.ks')).read_text() for name in
                    ('landing_math', 'landing_config', 'landing_main', 'landing_coast', 'landing_terminal', 'landing_brake', 'vessel_hardware'))


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


def run(nodes, env):
    for statement, yes, no in nodes:
        if statement.startswith('IF '):
            run(yes if evaluate(statement[3:], env) else no, env)
        elif statement.startswith('FOR '):
            match = re.fullmatch(r'FOR (\w+) IN (.*)', statement, re.S)
            for value in evaluate(match[2], env):
                env[match[1]] = value
                try: run(yes, env)
                except Broken: break
        elif statement.startswith('UNTIL '):
            steps = 0
            while not evaluate(statement[6:], env):
                try: run(yes, env)
                except Broken: break
                steps += 1
                assert steps < 10000, 'fixture loop did not converge'
        elif statement.startswith('PARAMETER '):
            match = re.fullmatch(r'PARAMETER (\w+)(?: IS (.*))?', statement, re.S)
            if match[1] not in env:
                assert match[2] is not None, statement
                env[match[1]] = evaluate(match[2], env)
        elif statement.startswith(('LOCAL ', 'SET ')):
            match = re.fullmatch(r'(?:LOCAL (.*?) IS|SET (.*?) TO) (.*)', statement, re.S)
            assert match, statement
            env['fixtureValue'] = evaluate(match[3], env)
            exec((match[1] or match[2]).replace(':', '.') + ' = fixtureValue', {'__builtins__': {}}, env)
        elif statement.startswith('RETURN'):
            raise Returned(evaluate(statement[7:], env) if statement != 'RETURN' else None)
        elif statement == 'BREAK':
            raise Broken()
        elif statement.startswith('WAIT '):
            env['fixture_wait'](evaluate(statement[5:], env))
        elif statement.startswith('ADD '):
            env['fixture_add'](evaluate(statement[4:], env))
        elif statement.startswith(('mLog', '_landingHud')):
            pass
        elif statement == 'STAGE':
            env['stage_event']()
        elif statement.startswith('LOCK '):
            env['fixture_lock'](statement)
        elif statement.endswith((':ACTIVATE', ':SHUTDOWN')):
            evaluate(statement + '()', env)
        else:
            evaluate(statement, env)


PARSED = {}

def call(name, env, *args):
    if name not in PARSED:
        source = body(SOURCES, name)
        params = re.findall(r'PARAMETER (\w+)', source)
        PARSED[name] = (params, parse(source))
    params, nodes = PARSED[name]
    local = dict(env, **dict(zip(params, args)))
    try:
        run(nodes, local)
    except Returned as result:
        return result.value


def environment():
    env = dict(SQRT=math.sqrt, TAN=lambda x: math.tan(math.radians(x)),
               SIN=lambda x: math.sin(math.radians(x)), COS=lambda x: math.cos(math.radians(x)),
               CONSTANT=NS(PI=math.pi), TIME=NS(SECONDS=0), SHIP=NS(BODY=NS(RADIUS=60000)))
    for name, value in re.findall(r'GLOBAL (\w+) IS ([^\n]+)\.', SOURCES):
        try: env[name] = evaluate(value, env)
        except (NameError, SyntaxError, AttributeError): pass
    for name in ('lmApproachAcceleration', 'lmApproachDescentSpeed', 'lmApproachSteering',
                 'lmDescentSpeed', 'lmVerticalThrottle', '_landingTerrainGrade'):
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
    assert end.index('_landingFinish(ctx).') < end.rindex('SET LOG_ARCHIVE_DEFERRED TO priorArchiveDeferral.')
    logs = (ROOT / 'lib/logs.ks').read_text()
    assert 'IF wroteLocal AND LOG_ARCHIVE_DEFERRED <= 0' in logs
    cleanup = body((ROOT / 'lib/vessel_hardware.ks').read_text(), 'vesselLandingCleanup')
    assert cleanup.index('PILOTMAINTHROTTLE TO 0.') < cleanup.index('WAIT 0.01.') < cleanup.index('UNLOCK THROTTLE.')
    print('PASS: guidance logs stay local until throttle cleanup; landing cutoff clears pilot throttle before unlock')


if __name__ == '__main__':
    check_coast()
    check_terrain()
    check_handoffs()
    check_approach()
    check_logging()
