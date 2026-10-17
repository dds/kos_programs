"""Source-driven surface geometry/operator fixtures, not a kOS or CommNet VM."""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_deorbit_geometry import Vec
from check_runtime_contracts import KString, KList, run
from check_surface_return import read_settings

LIGHT = (ROOT / 'lib/landing_light_math.ks').read_text() + '\n' + (ROOT / 'lib/landing_light.ks').read_text()
COMMAND = (ROOT / 'cmd/landlight.ks').read_text()
CONFIG = (ROOT / 'lib/config.ks').read_text()
ks.SOURCES += '\n' + LIGHT


class Geo:
    def __init__(self, lat, lng, world, frame):
        self.LAT, self.LNG = lat, (lng + 180) % 360 - 180
        self.world, self.frame = world, frame

    def ALTITUDEPOSITION(self, altitude):
        lat, lng = map(math.radians, (self.LAT, self.LNG))
        return self.world.POSITION + (self.world.RADIUS + altitude) * Vec(self.frame @ np.array(
            (math.cos(lat)*math.cos(lng), math.cos(lat)*math.sin(lng), math.sin(lat))))


def environment(frame=None, rotation=138984, sun_longitude=0, kerbin_longitude=-45):
    frame = np.eye(3) if frame is None else frame
    origin = Vec((9e7, -3e6, 8e6))
    moon = NS(NAME='FixtureMoon', RADIUS=200000., ROTATIONPERIOD=rotation, POSITION=origin, HASBODY=True)
    sun = NS(NAME='Sun', RADIUS=2.6e8, HASBODY=False)
    kerbin = NS(NAME='Kerbin', RADIUS=600000., HASBODY=True, BODY=sun)
    moon.BODY = kerbin
    time = NS(SECONDS=1000.)

    def direction(deg):
        angle = math.radians(deg)
        return Vec(frame @ np.array((math.cos(angle), math.sin(angle), 0)))

    sun.POSITION = origin + 1.36e10*direction(sun_longitude)
    kerbin.POSITION = origin + 1.2e7*direction(kerbin_longitude)
    def positionat(obj, ut):
        assert obj in (moon, sun, kerbin), 'Surface light must use BODY ephemerides, not vessel predictions'
        return obj.POSITION

    env = dict(SHIP=NS(BODY=moon, PERIAPSIS=14000, ORBIT=NS(PERIOD=2200, ECCENTRICITY=0)),
               SUN=sun, TIME=time, BODY=lambda name: kerbin,
               POSITIONAT=positionat, LATLNG=lambda lat, lng: Geo(lat, lng, moon, frame), V=lambda *xs: Vec(xs),
               LANDING_LIGHT_MODE='MORNING', LANDING_SUN_MIN_ELEV=10,
               LANDING_SUN_MAX_ELEV=30, LANDING_SUN_PREFERRED_ELEV=15,
               LANDING_AFTERNOON_MIN_ELEV=30, LANDING_AFTERNOON_MAX_ELEV=75,
               LANDING_AFTERNOON_PREFERRED_ELEV=52.5,
               LANDING_REQUIRE_KERBIN=1, LANDING_KERBIN_MIN_ELEV=5,
               LANDING_LIGHT_SCAN_ORBITS=4, LANDING_LIGHT_SCAN_SAMPLES=128,
               LANDING_LIGHT_TIME_MARGIN=300, LIST=lambda *xs: KList(xs),
               MOD=lambda x, y: x % y, ROUND=round, fixture_wait=lambda _: None)
    names = re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)', LIGHT)
    for name in names:
        env[name] = lambda *args, name=name: ks.call(name, env, *args)
    return env


def hierarchy_environment(frame=None, moon_name='Mun', moon_phase=0):
    """Native body POSITIONAT: future local orbit plus CURRENT parent center.

    This models the nested Orbit.getPositionAtUT convention used by the body
    wrapper, not fictitious fully propagated world positions for every body.
    The independent oracle propagates both circular orbits before subtraction.
    """
    frame = np.eye(3) if frame is None else frame
    env = environment(frame)
    moon, star = env['SHIP'].BODY, env['SUN']
    moon.NAME = moon_name
    if moon_name == 'Minmus':
        moon.ROTATIONPERIOD, moon.RADIUS = 40400., 60000.
    parent = moon.BODY
    now = env['TIME'].SECONDS
    outer_radius, inner_radius = 1.36e10, (4.7e7 if moon_name == 'Minmus' else 1.2e7)
    outer_period = 9203545.
    inner_period = 1077310. if moon_name == 'Minmus' else 138984.
    star.POSITION = Vec(frame @ np.array((4e7, 2e7, -3e7)))

    def local_orbit(obj, ut):
        if obj is parent:
            angle, radius = math.pi + 2*math.pi*(ut-now)/outer_period, outer_radius
        elif obj is moon:
            angle, radius = math.radians(moon_phase) + 2*math.pi*(ut-now)/inner_period, inner_radius
        else: raise AssertionError('Only bodies with parents have orbits')
        return Vec(frame @ np.array((radius*math.cos(angle), radius*math.sin(angle), 0)))

    parent.POSITION = star.POSITION + local_orbit(parent, now)
    moon.POSITION = parent.POSITION + local_orbit(moon, now)
    parent.ORBIT = NS(PERIOD=outer_period)
    moon.ORBIT = NS(PERIOD=inner_period, ECCENTRICITY=0)
    env['POSITIONAT'] = lambda obj, ut: obj.BODY.POSITION + local_orbit(obj, ut) if obj.HASBODY else obj.POSITION

    def true_center(obj, ut):
        return true_center(obj.BODY, ut) + local_orbit(obj, ut) if obj.HASBODY else obj.POSITION

    def elevation(lat, lng, obj, ut):
        lat, lng = math.radians(lat), math.radians(lng + 360*(ut-now)/moon.ROTATIONPERIOD)
        normal = Vec(frame @ np.array((math.cos(lat)*math.cos(lng), math.cos(lat)*math.sin(lng), math.sin(lat))))
        direction = true_center(obj, ut) - true_center(moon, ut) - moon.RADIUS*normal
        return math.degrees(math.asin(np.clip(np.dot(normal, direction)/np.linalg.norm(direction), -1, 1)))
    return env, elevation


def check_afternoon():
    env, oracle = hierarchy_environment(moon_phase=-90)
    env['LANDING_LIGHT_MODE'] = 'AFTERNOON'
    now = env['TIME'].SECONDS
    afternoon = env['landingLightAt'](0, 37.5, now)
    assert afternoon['OK'] and afternoon['SETTING'] and not afternoon['RISING'], afternoon
    assert 52 < afternoon['SUN'] < 53 and afternoon['KERBIN'] > 35
    morning = env['landingLightAt'](0, -37.5, now)
    assert not morning['OK'] and morning['REASON'] == 'not-afternoon', morning
    env['lmGroundGeoAt'] = lambda ut: Geo(0, 37.5, env['SHIP'].BODY, np.eye(3))
    selected = env['landingLitGroundTrack']()
    assert selected['FOUND'] and selected['KERBIN'] >= 5 and 30 <= selected['SUN'] <= 75
    # No solar preference is allowed to outweigh a hidden Kerbin.
    env, oracle = hierarchy_environment()
    env['LANDING_LIGHT_MODE'] = 'AFTERNOON'
    env['lmGroundGeoAt'] = lambda ut: Geo(0, 37.5, env['SHIP'].BODY, np.eye(3))
    assert not env['landingLitGroundTrack']()['FOUND']
    # Minmus's faster spin must be predicted, not frozen to its current view.
    env, oracle = hierarchy_environment(moon_name='Minmus')
    parent = env['SHIP'].BODY.BODY
    for dt in (0, 1000, 4000, 9000):
        report = env['landingLightAt'](20, 37.5, now+dt)
        assert abs(report['KERBIN'] - oracle(20, 37.5, parent, now+dt)) < 2e-6
    print('PASS: afternoon prefers setting 52.5-degree Sun, rejects morning/hidden-Kerbin sites; Minmus predicts separate spin and orbit')


def check_nested_radio_frame():
    rng = np.random.default_rng(28)
    for orientation in range(4):
        frame, _ = np.linalg.qr(rng.normal(size=(3, 3)))
        if orientation % 2: frame[:, 0] *= -1
        env, oracle = hierarchy_environment(frame)
        parent = env['SHIP'].BODY.BODY
        for dt in (0, 900, 4000, 9000):
            for lat in (0, 45):
                for lng in (-75, 0, 70, 160):
                    result = env['landingLightAt'](lat, lng, 1000+dt)
                    expected = oracle(lat, lng, parent, 1000+dt)
                    assert abs(result['KERBIN']-expected) < 2e-6, (dt, lat, lng, result, expected)
                    assert abs(expected-oracle(lat, lng, parent, 1000)) < 2e-6  # Tidal lock invariant.
        # Regression: early-morning Sun preference cannot accept an Earth-hidden site.
        rejected = env['landingLightAt'](0, -75, 5000)
        assert not rejected['OK'] and rejected['REASON'] == 'kerbin-below-margin', rejected
        # Prove this fixture would have accepted a false positive previously.
        offset = env['_landingSurfaceOffsetAt'](0, -75, 1900)
        legacy = env['POSITIONAT'](parent, 1900) - env['POSITIONAT'](env['SHIP'].BODY, 1900) - offset
        legacy_elevation = math.degrees(math.asin(np.dot(offset.NORMALIZED, legacy.NORMALIZED)))
        assert legacy_elevation > 18 and oracle(0, -75, parent, 1900) < -15
        # A runtime/build convention mismatch must hold rather than approve.
        env['landingKerbinElevationNow'] = lambda *args: -80
        assert env['landingLightAt'](0, 160, 1900)['REASON'] == 'kerbin-frame-mismatch'
    print('PASS: nested Sun/Kerbin/Mun native prediction frames, parent motion, reflected axes and invariant tidally locked Kerbin elevation')


def check_geometry():
    rng = np.random.default_rng(90)
    cases = 0
    for orientation in range(6):
        frame, _ = np.linalg.qr(rng.normal(size=(3, 3)))
        if orientation % 2: frame[:, 0] *= -1
        for rotation in (138984, -138984, 40400, 0):
            env = environment(frame, rotation)
            env['LANDING_REQUIRE_KERBIN'] = 0
            for dt in (0, 1500, 9000):
                for lat in (-80, 0, 70):
                    for longitude in (-105, -75, 0, 75, 105, 179):
                        ut = env['TIME'].SECONDS + dt
                        result = env['landingLightAt'](lat, longitude, ut)
                        angle = longitude + (360*dt/rotation if rotation else 0)
                        # Independent spherical-dot oracle with finite Sun distance.
                        normal = np.array((math.cos(math.radians(lat))*math.cos(math.radians(angle)),
                                           math.cos(math.radians(lat))*math.sin(math.radians(angle)),
                                           math.sin(math.radians(lat))))
                        to_sun = np.array((1.36e10, 0, 0)) - 200000*normal
                        expected = math.degrees(math.asin(np.clip(np.dot(normal, to_sun)/np.linalg.norm(to_sun), -1, 1)))
                        assert abs(result['SUN']-expected) < 2e-6, (result, expected)
                        if lat == 0 and dt == 0 and longitude == -75:
                            assert result['OK'] == (rotation > 0), result
                        if lat == 0 and dt == 0 and longitude == 75:
                            assert result['OK'] == (rotation < 0), result
                        if longitude == 179 and dt == 0: assert not result['OK']
                        cases += 1
    env = environment(kerbin_longitude=180)
    blocked = env['landingLightAt'](0, -75, 1000)
    assert blocked['REASON'] == 'kerbin-below-margin' and blocked['KERBIN'] < 0
    env['LANDING_REQUIRE_KERBIN'] = 0
    assert env['landingLightAt'](0, -75, 1000)['OK']
    env['LANDING_LIGHT_MODE'] = 'SUNLIT'
    assert env['landingLightAt'](0, 75, 1000)['OK']  # Setting is allowed only with SUNLIT/ANY.
    env['LANDING_LIGHT_MODE'] = 'ANY'
    assert env['landingLightAt'](0, 179, 1000)['OK']
    env['LANDING_LIGHT_MODE'] = 'TYPO'
    assert not env['landingLightAt'](0, -75, 1000)['OK']
    env = environment(sun_longitude=0, kerbin_longitude=0)
    assert env['landingLightAt'](0, -75, 1000)['REASON'] == 'eclipse'
    print(f'PASS: {cases} surface elevation cases, reflected axes, rising vs setting, eclipse, radio opt-out and invalid policy')


def check_windows_and_search():
    env = environment(kerbin_longitude=-45)
    site = Geo(0, -75, env['SHIP'].BODY, np.eye(3))
    env['lmGroundGeoAt'] = lambda ut: site
    found = env['landingLitGroundTrack']()
    assert found['FOUND'] and abs(found['LAT']) < .001
    assert found['SUN'] >= 10 and found['KERBIN'] >= 5
    env['lmGroundGeoAt'] = lambda ut: Geo(0, 179, env['SHIP'].BODY, np.eye(3))
    assert not env['landingLitGroundTrack']()['FOUND']
    # Reject a center-time success if any sampled touchdown margin fails.
    env['landingLightAt'] = lambda lat, lng, ut, tolerance=0, required=1: dict(OK=ut <= 1000, REASON='test-window')
    assert not env['landingLightWindow'](0, -75, 1000)['OK']
    # Retained nodes cannot bypass missing timing or policy failures.
    env = environment(kerbin_longitude=-45)
    env.update(landingResolveTarget=lambda: dict(FOUND=True, LAT=0, LNG=-75),
               ADDONS=NS(TR=NS(AVAILABLE=True, ISVERTWOTWO=True, HASIMPACT=True, TIMETILLIMPACT=1000)))
    assert env['landingLightNodeAllowed'](NS(TIME=1200))
    planner = function_body((ROOT/'lib/deorbit_targeting.ks').read_text(), '_targetDeorbitLightAccepted')
    calls = []
    plan_env = dict(solved=dict(HAS_IMPACT=True, TTI=900), burnUT=5000, targetLat=7, targetLng=23,
                    landingLightActive=lambda: True,
                    landingLightWindow=lambda *args: (calls.append(args) or dict(OK=True)))
    assert run(planner, plan_env)
    assert calls == [(7, 23, 5900)]  # Burn UT + post-burn TTI, not now + TTI or the search pass.
    env['landingLightWindow'] = lambda *args: dict(OK=False, REASON='kerbin-below-margin', SUN=15, KERBIN=-4)
    assert not env['landingLightNodeAllowed'](NS(TIME=1200))
    env['ADDONS'].TR.HASIMPACT = False
    assert not env['landingLightNodeAllowed'](NS(TIME=1200))
    env['LANDING_LIGHT_MODE'], env['LANDING_REQUIRE_KERBIN'] = 'ANY', 0
    assert env['landingLightNodeAllowed'](NS(TIME=1200))
    deps, _, _ = dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'landing_light' in closure(['deorbit_burn'], deps)
    assert 'landing_light' not in closure(['landing_main'], deps)  # Orbital search stays out of powered descent.
    assert 'landing_light_math' in closure(['landing_main'], deps)  # Diversions retain Sun/radio gates offline.
    for vehicle in ('RO8', 'RO9'):
        for moon in ('mun', 'minmus'):
            profile = read_settings((ROOT/f'missions/{vehicle}/{moon}_economy_return.ks').read_text(), {})
            assert profile['LANDING_LIGHT_MODE'] == 'MORNING' and profile['LANDING_REQUIRE_KERBIN'] == 1
            assert profile['LANDING_SUN_PREFERRED_ELEV'] == 15 and profile['LANDING_KERBIN_MIN_ELEV'] == 5
    print('PASS: bounded ground-track selection, no dark fallback, touchdown margin, retained-node timing/policy checks and offline dependencies')


def check_command():
    source = function_body(COMMAND, '_cmdLandlight').replace('REMOVE NEXTNODE.', 'remove_node().')
    # PRINT is a UI primitive outside this interpreter; skip only those AST nodes.
    def without_print(nodes):
        return [(s, without_print(yes), without_print(no)) for s, yes, no in nodes if not s.startswith('PRINT ')]
    parsed = without_print(ks.parse(source))
    for scenario in ('preview', 'apply', 'afternoon', 'status', 'no-site', 'suborbital', 'started', 'throttle'):
        mutations, nodes = [], [object()]
        class HasNode:
            def __bool__(self): return bool(nodes)
        state = dict(vehicle='RO9', mission_id='mun_economy_return', phase='LAND_DEORBIT')
        if scenario == 'started': state['deorbit_burn_started'] = 'true'
        if scenario == 'status': state.update(phase='LAND_ASSIST', deorbit_burn_started='true')
        before = dict(state)
        env = dict(action=scenario if scenario in ('preview', 'status') else 'apply',
                   mode='AFTERNOON' if scenario == 'afternoon' else 'MORNING', requireKerbin=1,
                   SHIP=NS(STATUS='SUB_ORBITAL' if scenario == 'suborbital' else 'LANDED' if scenario == 'status' else 'ORBITING',
                           BODY=NS(NAME='Mun'), ORBIT=NS(ECCENTRICITY=0), PERIAPSIS=14000,
                           THRUST=0, CONTROL=NS(MAINTHROTTLE=.1 if scenario == 'throttle' else 0, PILOTMAINTHROTTLE=0)),
                   TIME=NS(SECONDS=1000), ABORT=False, stateGet=state.get,
                   KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),
                   RUNPATH=lambda _: None, bootPreamble=lambda: None, bootLibLoad=lambda _: None,
                   EXISTS=lambda _: True, applyMissionOverrides=lambda: None,
                   landingKerbinElevationNow=lambda *args: 10,
                   landingResolveTarget=lambda: dict(FOUND=True, LAT=2, LNG=-75),
                   LATLNG=lambda lat, lng: NS(LAT=lat, LNG=lng),
                   landingLightAt=lambda *args: dict(KERBIN=10, SUN=15, REASON='ok'),
                   landingLitGroundTrack=lambda: dict(FOUND=scenario!='no-site', LAT=2, LNG=-75, UT=2000, SUN=15, KERBIN=10),
                   missionOverrideUpdate=lambda values: mutations.append(values),
                   LEXICON=lambda *xs: dict(zip(xs[::2], xs[1::2])), HASNODE=HasNode(),
                   remove_node=lambda: nodes.clear(), fixture_wait=lambda _: None)
        try: ks.run(parsed, env)
        except ks.Returned: pass
        assert state == before
        assert bool(mutations) == (scenario in ('apply', 'afternoon'))
        assert bool(nodes) == (scenario not in ('apply', 'afternoon'))
        if mutations:
            assert 'SEQUENCE' not in mutations[0]
            assert mutations[0]['LANDING_REQUIRE_KERBIN'] == 1
            assert mutations[0]['LANDING_LIGHT_MODE'] == ('AFTERNOON' if scenario == 'afternoon' else 'MORNING')
    print('PASS: preview preserves node/mission; apply alone replaces target/node; no-site, begun burn, descent and positive throttle refuse mutation')


class Text(KString):
    @property
    def TRIM(self): return Text(self.strip())
    def STARTSWITH(self, value): return self.casefold().startswith(value.casefold())
    def SPLIT(self, value): return KList(Text(s) for s in self.split(value))


def check_overrides():
    source = function_body(CONFIG, 'missionOverrideUpdate')
    source = re.sub(r'LOG (.*) TO (\w+)\.', r'write_line(\1, \2).', source)
    path = '1:/run/mission_overrides.ks'
    disk = {path: ['SET SEQUENCE TO LIST("LAND_DEORBIT", "LAND_ASSIST", "SURFACE_RETURN_SETUP").',
                   'SET CAPTURE_RESERVE_DV TO 1500.', 'SET TARGET_LAT TO -4.', 'SET LANDING_REQUIRE_KERBIN TO 0.']}
    class Values(dict):
        @property
        def KEYS(self): return list(self)
    updates = Values(TARGET_LAT=3, LANDING_REQUIRE_KERBIN=1)
    env = dict(values=updates, LIST=lambda *xs: KList(xs), CHAR=chr,
               EXISTS=lambda p: p in disk, missionOverridePath=lambda: path,
               OPEN=lambda p: NS(READALL=NS(STRING=Text('\n'.join(disk[p])))),
               DELETEPATH=lambda p: disk.pop(p),
               write_line=lambda line, p: disk.setdefault(p, []).append(line),
               COPYPATH=lambda src, dst: disk.update({dst: list(disk[src])}), configLiteral=str)
    run(source, env)
    assert len(disk[path]) == 4
    assert 'SURFACE_RETURN_SETUP' in disk[path][0] and disk[path][1] == 'SET CAPTURE_RESERVE_DV TO 1500.'
    assert disk[path][2:] == ['SET TARGET_LAT TO 3.', 'SET LANDING_REQUIRE_KERBIN TO 1.']
    run(source, env)
    assert len(disk[path]) == 4  # Replace, do not accumulate old assignments.
    class Boolean:
        def __init__(self, value): self.value = value
        def ISTYPE(self, name): return name == 'Boolean'
        def __bool__(self): return self.value
    for value in (True, False):
        assert run(function_body(CONFIG, 'configLiteral'), dict(raw=Boolean(value))) == str(value).upper()
    print('PASS: override upsert preserves return sequence/reserve and replaces each supplied key without growing the file')


def check_diversion_radio_margin():
    env=environment(kerbin_longitude=87)
    env['LANDING_LIGHT_MODE']='ANY'
    now=env['TIME'].SECONDS
    assert not env['landingLightAt'](0,0,now)['OK']
    relaxed=env['landingLightAt'](0,0,now,5)
    assert relaxed['OK'] and 0 < relaxed['KERBIN'] < 5
    assert env['landingLightWindow'](0,0,now,5)['OK']
    assert not env['landingLightWindow'](0,0,now)['OK']
    # Operator-approved -1.11 degree case passes only under diversion policy.
    env=environment(kerbin_longitude=90.16)
    env['LANDING_LIGHT_MODE']='ANY'
    negative=env['landingLightAt'](0,0,now,7)
    assert negative['OK'] and -1.12 < negative['KERBIN'] < -1.1
    assert env['landingLightWindow'](0,0,now,7)['OK']
    assert not env['landingLightAt'](0,0,now)['OK']
    # The allowance is still bounded at -2 degrees, even if huge.
    env=environment(kerbin_longitude=94)
    env['LANDING_LIGHT_MODE']='ANY'
    assert not env['landingLightAt'](0,0,now,100)['OK']
    assert env['landingLightWindow'](0,0,now,7,0)['OK']
    assert env['LANDING_REQUIRE_KERBIN']==1  # No global policy mutation.
    # Solar policy remains active under the radio tolerance.
    env=environment(kerbin_longitude=87,sun_longitude=180)
    env['LANDING_LIGHT_MODE']='SUNLIT'
    assert env['landingLightAt'](0,0,now,5)['REASON']=='sun-below-margin'
    assert env['landingLightAt'](0,0,now,7,0)['REASON']=='sun-below-margin'
    print('PASS: -1.11 degree allowance and link-free diversion; strict planning, optional -2 degree floor and Sun rejection remain active')


if __name__ == '__main__':
    check_diversion_radio_margin()
    check_nested_radio_frame()
    check_afternoon()
    check_geometry()
    check_windows_and_search()
    check_command()
    check_overrides()
