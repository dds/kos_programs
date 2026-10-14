"""Numerical checks of source expressions; not a kOS/Trajectories simulation.

Run: python3 -B scripts/check_deorbit_geometry.py
"""
import math
import re
from pathlib import Path
from types import SimpleNamespace as NS

import numpy as np

from check_launch_and_staging import body

ROOT = Path(__file__).resolve().parents[1]
MATH = (ROOT / 'lib/landing_math.ks').read_text()
PLAN = (ROOT / 'lib/deorbit_targeting.ks').read_text()


class Vec(np.ndarray):
    def __new__(cls, values):
        return np.asarray(values, dtype=float).view(cls)

    @property
    def MAG(self):
        return float(np.linalg.norm(self))

    @property
    def NORMALIZED(self):
        return self / self.MAG


def dot(a, b):
    return float(np.dot(a, b))


def exclude(axis, vec):
    return vec - dot(axis, vec) / dot(axis, axis) * axis


class Geo:
    def __init__(self, lat, lng, world):
        self.LAT, self.LNG, self.world = lat, (lng + 180) % 360 - 180, world

    def ALTITUDEPOSITION(self, altitude):
        lat, lng = map(math.radians, (self.LAT, self.LNG))
        return self.world.POSITION + (self.world.RADIUS + altitude) * Vec(
            (math.cos(lat) * math.cos(lng), math.cos(lat) * math.sin(lng), math.sin(lat)))


def expressions(source, env):
    """Evaluate assignment expressions from a straight-line mathematical path."""
    source = re.sub(r'//[^\n]*', '', source)
    for match in re.finditer(r'(?:LOCAL (\w+) IS|SET (\w+) TO) (.*?)\.(?=\s*(?:\n|$))', source, re.S):
        name = match[1] or match[2]
        # The sole conditional assignment in lmGroundGeoAt.
        if name == 'longitude_' and match[2] and abs(env['SHIP'].BODY.ROTATIONPERIOD) <= .01:
            continue
        env[name] = evaluate(match[3], env)
        if name == 'tangent' and env[name].MAG < .01:
            return False
    return True


def evaluate(expr, env):
    expr = ' '.join(expr.split()).replace(':', '.').replace('^', '**').replace('<>', '!=')
    for old, new in (('TRUE', 'True'), ('FALSE', 'False'), ('AND', 'and'), ('OR', 'or'), ('NOT', 'not')):
        expr = re.sub(rf'\b{old}\b', new, expr)
    expr = re.sub(r'(?<![<>!=])=(?!=)', '==', expr)
    helpers = dict(VDOT=dot, VXCL=exclude, MIN=min, MAX=max, ABS=abs,
                   ARCSIN=lambda x: math.degrees(math.asin(x)),
                   ARCCOS=lambda x: math.degrees(math.acos(x)),
                   ARCTAN2=lambda y, x: math.degrees(math.atan2(y, x)),
                   LEXICON=lambda *xs: dict(zip(xs[::2], xs[1::2])))
    return eval(expr, {'__builtins__': {}, **helpers}, env)


def fixture():
    world = NS(RADIUS=60000, ROTATIONPERIOD=40400, POSITION=Vec((200000, -80000, 60000)))
    def geoposition(position):
        rel = position - world.POSITION
        return Geo(math.degrees(math.asin(rel[2] / rel.MAG)),
                   math.degrees(math.atan2(rel[1], rel[0])), world)
    world.GEOPOSITIONOF = geoposition
    return dict(SHIP=NS(BODY=world), CONSTANT=NS(PI=math.pi), TIME=NS(SECONDS=1000),
                LATLNG=lambda lat, lng: Geo(lat, lng, world))


def offsets(target_up, impact_up, tangent):
    env = fixture()
    world = env['SHIP'].BODY
    # Feed arbitrary orientations, including reflected axes, through the
    # actual Cartesian expressions; geocoordinates merely supply unit vectors.
    points = [target_up, impact_up]
    env['LATLNG'] = lambda index, _: NS(ALTITUDEPOSITION=lambda altitude:
                                      world.POSITION + points[index] * (world.RADIUS + altitude))
    env.update(targetLat=0, targetLng=0, impactLat=1, impactLng=0, groundVelocity=tangent)
    source = body(MATH, 'lmSurfaceTrackOffset')
    if not expressions(source, env):
        return {'VALID': False}
    result = source[source.rindex('RETURN ') + 7:].strip().removesuffix('.')
    return evaluate(result, env)


def check_offsets():
    rng = np.random.default_rng(42)
    cases = 0
    for _ in range(8):
        transform, _ = np.linalg.qr(rng.normal(size=(3, 3)))
        for along in (-45000, -30450, -15000, 0, 10000, 15000, 20000, 45000):
            for cross in (0, 100, 610, 7800):
                a, c = along / 60000, cross / 60000
                target = Vec(transform @ np.array((math.cos(c)*math.cos(a),
                                                   -math.cos(c)*math.sin(a), math.sin(c))))
                impact = Vec(transform[:, 0])
                tangent = Vec(transform[:, 1]) * 150 - impact * 90
                result = offsets(target, impact, tangent)
                assert result['VALID']
                assert abs(result['DOWNFIELD'] - along) < 1e-7, result
                assert abs(result['CROSS'] - cross) < 1e-7, result
                assert abs(result['DIST'] - 60000*math.acos(np.clip(dot(target, impact), -1, 1))) < .002
                cases += 1
    assert not offsets(Vec((1, 0, 0)), Vec((1, 0, 0)), Vec((1, 0, 0)))['VALID']
    a = 15000 / 60000
    old_cross = math.sqrt((120000 * math.sin(a/2))**2 - (60000 * math.sin(a))**2)
    assert 1800 < old_cross < 1900
    print(f'PASS: {cases} signed spherical offsets, reflected frames, zero-tangent rejection; old false cross={old_cross:.1f}m')


def check_future_frame():
    env = fixture()
    world, ship = env['SHIP'].BODY, env['SHIP']
    mu, semi, ecc = 1.7658e9, (74600 + 160000)/2, (160000-74600)/(160000+74600)
    motion = math.sqrt(mu / semi**3)
    def relative(ut):
        mean = motion * (ut - 1000)
        eccentric = mean
        for _ in range(12):
            eccentric -= (eccentric-ecc*math.sin(eccentric)-mean)/(1-ecc*math.cos(eccentric))
        # Eccentric polar orbit; its plane cuts the longitude wrap and pole.
        return Vec((semi*(math.cos(eccentric)-ecc), 0,
                    semi*math.sqrt(1-ecc**2)*math.sin(eccentric)))
    def positionat(obj, ut):
        assert obj is ship, 'Do not subtract a future parent-orbit body position'
        return world.POSITION + relative(ut)
    env['POSITIONAT'] = positionat

    def run(name, ut):
        local = dict(env, ut=ut)
        source = body(MATH, name)
        expressions(source, local)
        return evaluate(source[source.rindex('RETURN ') + 7:].strip().removesuffix('.'), local)
    env['lmGroundGeoAt'] = lambda ut: run('lmGroundGeoAt', ut)
    env['lmGroundPositionAt'] = lambda ut: run('lmGroundPositionAt', ut)
    env['lmGroundVelocityAt'] = lambda ut: run('lmGroundVelocityAt', ut)

    def expected(ut):
        angle = -2*math.pi*(ut-1000)/world.ROTATIONPERIOD if world.ROTATIONPERIOD else 0
        rot = np.array(((math.cos(angle), -math.sin(angle), 0),
                        (math.sin(angle), math.cos(angle), 0), (0, 0, 1)))
        return Vec(rot @ relative(ut))
    for period in (40400, -40400, 0):
        world.ROTATIONPERIOD = period
        for ut in (1000, 1800, 4000, 8500, 16000):
            actual = run('lmGroundPositionAt', ut)
            assert (actual - expected(ut)).MAG < 1e-7
            velocity = run('lmGroundVelocityAt', ut)
            expected_velocity = (expected(ut) - expected(ut-.5))/.5
            assert (velocity - expected_velocity).MAG < 1e-6
            local = dict(env, impactUT=ut)
            source = body(PLAN, '_nodeImpactAngle')
            expressions(source, local)
            angle = evaluate(source[source.rindex('RETURN ') + 7:].strip().removesuffix('.'), local)
            expected_angle = abs(math.degrees(math.asin(dot(expected_velocity.NORMALIZED, expected(ut).NORMALIZED))))
            assert abs(angle-expected_angle) < 1e-7
    print('PASS: 14.6 x 100 km polar orbit ground positions, surface velocities and FPA; prograde/retrograde/no rotation')


def check_planner_guards():
    source = body(PLAN, '_targetDeorbitSolutionAccepted')
    gates = re.findall(r'IF (.*?) \{\s*RETURN FALSE\.\s*\}', source, re.S)
    result_expr = source[source.rindex('RETURN ') + 7:].strip().removesuffix('.')
    def accepted(down, cross, valid=True, impact=True, fpa=37.8, minimum_fpa=0):
        env = dict(solved={'VALID': valid, 'HAS_IMPACT': impact, 'DOWNFIELD': down,
                           'CROSS': cross, 'ANGLE': fpa}, minDownfield=10000, maxDownfield=20000,
                   DEORBIT_MIN_FPA=minimum_fpa, _targetCrossTrackFromSolved=lambda s: s['CROSS'],
                   _targetDeorbitCrossAuthority=lambda s: 610)
        return not any(evaluate(g, env) for g in gates) and evaluate(result_expr, env)
    assert accepted(15000, 0) and accepted(10000, 610) and accepted(20000, 0)
    assert not accepted(15000, 611) and not accepted(-30450, 7800)
    assert not accepted(9999, 0) and not accepted(20001, 0)
    assert not accepted(15000, 0, valid=False) and not accepted(15000, 0, impact=False)
    assert not accepted(15000, 0, fpa=20, minimum_fpa=30)
    planner = body(PLAN, 'targetedDeorbitAt')
    assert 'FOR candidateAngle IN LIST(50, 35, 65, 20, 80)' in planner
    assert 'stepA, candidateAngle)' in planner
    assert 'period / MAX(128, TARGET_DEORBIT_SCAN_SAMPLES)' in planner
    guard = planner.index('IF NOT _targetDeorbitSolutionAccepted(finalCheck')
    execute = planner.index('IF NOT executeDeorbitNode(realNode)')
    assert guard < execute and 'REMOVE realNode.' in planner[guard:execute]
    assert 'reason=validation-window-expired' in planner[guard:execute]
    reader = body(PLAN, '_readGeometricDeorbitNode')
    assert 'SET result["TTI"] TO impactUT - nd:TIME.' in reader
    assert 'lmGroundVelocityAt(impactUT)' in reader
    assert 'POSITIONAT(bdy,' not in MATH and 'POSITIONAT(SHIP:BODY,' not in MATH
    assert 'solved["DIST"] ^ 2' not in PLAN
    print('PASS: acceptance boundaries, multiple burn locations, final/late-node guards and post-burn correction time')


if __name__ == '__main__':
    check_offsets()
    check_future_frame()
    check_planner_guards()
