"""Execute cache/flow decisions from solar.ks; no panel physics or kOS VM."""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_deorbit_geometry import Vec
from check_runtime_contracts import KList

SOURCE = (ROOT / 'lib/solar.ks').read_text()
SOURCE = SOURCE.replace('SAS OFF.', 'SET SAS TO FALSE.').replace('UNLOCK STEERING.', 'unlock().')
ks.SOURCES += '\n' + SOURCE


class Items(KList):
    def ISTYPE(self, name): return name == 'List'


class Identity:
    def __mul__(self, axis): return axis


for index, component in enumerate('XYZ'):
    setattr(Vec, component, property(lambda self, index=index: float(self[index])))


def environment():
    primary = Vec((1, 0, 0))
    facing = NS(FOREVECTOR=primary, TOPVECTOR=Vec((0, 1, 0)), STARVECTOR=Vec((0, 0, 1)))
    module = NS(HASFIELD=lambda name: name == 'energy flow')
    panel = NS(HASMODULE=lambda name: True, GETMODULE=lambda name: module, FACING=facing)
    saved = dict(solar_axis=Items((1, 0, 0)), solar_axis_peak=10., solar_axis_distance=1e10,
                 solar_axis_panels=1, solar_axis_scaled=1)
    attempts, finishes, unlocked, reading = [], [], [], [10.]
    env = dict(SHIP=NS(STATUS='ORBITING', PARTS=Items([panel]), FACING=NS(INVERSE=Identity())),
               SUN=NS(POSITION=Vec((1e10, 0, 0))), forceSearch=False, lockSteering=False,
               overrideLaunchGuard=False, SOLAR_REUSE_RATIO=.9, LIST=lambda *xs: Items(xs),
               V=lambda *xs: Vec(xs), ROUND=round, stateGet=saved.get, stateGetNum=saved.get,
               stateSet=lambda key, value: saved.update({key: value}),
               stateRemove=lambda key: saved.pop(key, None),
               _solarSearchGuardReason=lambda _: '', _solarSunOccluded=lambda: False,
               unlock=lambda: unlocked.append(True), shipSolarFlow=lambda: reading[0],
               shipPowerFraction=lambda: .8)
    env['_solarPanelInfo'] = lambda: ks.call('_solarPanelInfo', env)
    env['_solarCacheReference'] = lambda: ks.call('_solarCacheReference', env)
    def aim(axis):
        attempts.append(axis)
        reading[0] = max(0., float(np.dot(axis, primary))) * 10
    env['_solarAimSettle'] = aim
    env['_solarFinish'] = lambda *args: finishes.append(args)
    def rotate(angle, axis):
        angle = math.radians(angle)
        class Rotation:
            def __mul__(self, vector):
                return Vec(vector*math.cos(angle) + np.cross(axis, vector)*math.sin(angle)
                           + axis*np.dot(axis, vector)*(1-math.cos(angle)))
        return Rotation()
    env['ANGLEAXIS'] = rotate
    return env, saved, attempts, finishes, unlocked, reading


def check_cache_decisions():
    env, saved, attempts, finishes, _, _ = environment()
    ks.call('orientForSolar', env)
    assert len(attempts) == 1 and finishes[0][2] == 'cached axis validated'
    # Slightly below the peak is acceptable; below the configured floor searches.
    for flow, expect_search in ((9.1, False), (8.9, True)):
        env, saved, attempts, finishes, _, reading = environment()
        original = env['_solarAimSettle']
        def aim(axis):
            original(axis)
            if len(attempts) == 1: reading[0] = flow
        env['_solarAimSettle'] = aim
        ks.call('orientForSolar', env)
        assert (len(attempts) > 1) == expect_search
        assert finishes[-1][2] == ('best of 6' if expect_search else 'cached axis validated')
    env, saved, attempts, finishes, _, reading = environment()
    saved['solar_axis'] = Items((-1, 0, 0))
    ks.call('orientForSolar', env)
    assert attempts[0][0] == -1 and finishes[-1][0][0] == 1 and len(attempts) > 1
    for occluded, flow in ((True, 0.), (False, -1.)):
        env, saved, attempts, finishes, unlocked, reading = environment()
        env['_solarSunOccluded'] = lambda: occluded
        env['_solarAimSettle'] = lambda axis: (attempts.append(axis), reading.__setitem__(0, flow))
        ks.call('orientForSolar', env)
        assert len(attempts) == 1 and not finishes and unlocked
        assert saved['solar_axis_peak'] == 10
    env, saved, attempts, finishes, _, _ = environment()
    saved.pop('solar_axis_peak')  # Old save: measure a peak once, then future calls can validate.
    ks.call('orientForSolar', env)
    assert len(attempts) > 1 and finishes[-1][2] == 'best of 6'
    env, saved, attempts, finishes, _, _ = environment()
    ks.call('orientForSolar', env, True)
    assert len(attempts) > 1 and finishes[-1][2] == 'best of 6'
    print('PASS: saved axis tried first; near-peak reuse, low-flow search, bad-axis recovery, eclipse/unreadable retention, old-save learning and explicit forced search')


def check_reference_and_persistence():
    env, saved, _, _, _, reading = environment()
    env['SUN'].POSITION = Vec((2e10, 0, 0))
    assert env['_solarCacheReference']() == 2.5  # Inverse-square irradiance.
    saved['solar_axis_panels'] = 2
    assert env['_solarCacheReference']() < 0
    saved['solar_axis_panels'] = 1
    env['_solarPanelInfo'] = lambda: dict(COUNT=1, SCALED=0)
    saved['solar_axis_scaled'] = 0
    assert env['_solarCacheReference']() < 0  # Exposure/mixed units cannot use irradiance scaling.
    env['SUN'].POSITION = Vec((1e10, 0, 0))
    assert env['_solarCacheReference']() == 10
    ks.call('_solarFinish', env, Vec((1, 0, 0)), False, 'reuse', 11.)
    assert saved['solar_axis_peak'] == 11 and saved['solar_axis'] == [1, 0, 0]
    reading[0] = 0
    ks.call('_solarFinish', env, Vec((1, 0, 0)), False, 'eclipse')
    assert saved['solar_axis_peak'] == 11
    for filename, name in (('phases', 'coastHealthCheck'), ('capture', '_enterSolarCoast'), ('solar', 'solarHoldTick')):
        code = function_body((ROOT/f'lib/{filename}.ks').read_text(), name)
        assert 'orientForSolar(TRUE' not in code
    command = (ROOT/'cmd/solarhold.ks').read_text()
    assert 'PARAMETER research IS FALSE.' in command
    orient = (ROOT/'cmd/orientForSolar.ks').read_text()
    assert orient.index('PARAMETER forceSearch') < orient.index('LOCAL FUNCTION _cmdOrientForSolar')
    print('PASS: peak saved across boots, no downward ratchet/zero overwrite, changed panels invalidate benchmark, Sun-distance scaling and automatic coast reuse')


def check_occultation():
    env, *_ = environment()
    star = NS(NAME='Sun', POSITION=Vec((1e10, 0, 0)), RADIUS=1e5, HASBODY=False)
    parent = NS(NAME='Kerbin', POSITION=Vec((-1e7, 3e6, 0)), RADIUS=600000, HASBODY=True, BODY=star)
    moon = NS(NAME='Mun', POSITION=Vec((300000, 0, 0)), RADIUS=200000, HASBODY=True, BODY=parent)
    env['SUN'], env['SHIP'].BODY = star, moon
    assert ks.call('_solarSunOccluded', env)
    moon.POSITION = Vec((-300000, 0, 0))
    assert not ks.call('_solarSunOccluded', env)
    moon.POSITION = Vec((300000, 300000, 0))
    assert not ks.call('_solarSunOccluded', env)
    parent.POSITION = Vec((1e7, 0, 0))
    assert ks.call('_solarSunOccluded', env)
    print('PASS: measured-flow cache can distinguish daylight from own-body and ancestor-body eclipses')


if __name__ == '__main__':
    check_cache_decisions()
    check_reference_and_persistence()
    check_occultation()
