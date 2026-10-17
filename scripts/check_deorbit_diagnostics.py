"""Source-driven diagnostic geometry, not kOS compilation or a flight test."""
import math
import re

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, mask, command_entrypoint_errors
from check_deorbit_geometry import Vec, Geo, fixture

COMMAND = (ROOT/'cmd/deorbitcheck.ks').read_text()
ks.SOURCES += '\n' + COMMAND


class Rotation:
    def __init__(self, degrees, axis):
        self.angle, self.axis = math.radians(degrees), axis/np.linalg.norm(axis)

    def __mul__(self, vec):
        cosine, sine = math.cos(self.angle), math.sin(self.angle)
        return Vec(vec*cosine + np.cross(self.axis,vec)*sine
                   + self.axis*np.dot(self.axis,vec)*(1-cosine))


def check_geometry():
    for spin in (40400, -40400, 0):
        env = fixture()
        world = env['SHIP'].BODY
        world.ROTATIONPERIOD = spin
        world.ANGULARVEL = Vec((0,0,2*math.pi/spin if spin else 0))
        def positionat(obj,ut):
            assert obj is env['SHIP'], 'Never subtract a future parent body position'
            angle = .001*ut
            return world.POSITION + Vec((62000*math.cos(angle),
                62000*math.sin(angle)*math.cos(.35),62000*math.sin(angle)*math.sin(.35)))
        env.update(POSITIONAT=positionat, ANGLEAXIS=Rotation,
                   VANG=lambda a,b: math.degrees(math.acos(np.clip(
                       np.dot(a,b)/np.linalg.norm(a)/np.linalg.norm(b),-1,1))))
        for name in ('lmGroundGeoAt','lmGroundPositionAt','lmGroundVelocityAt'):
            env[name] = lambda *args,name=name: ks.call(name,env,*args)
        impact_ut = 8040
        pos = positionat(env['SHIP'],impact_ut)-world.POSITION
        actual = Rotation(-(impact_ut-env['TIME'].SECONDS)*world.ANGULARVEL.MAG*180/math.pi,
                          world.ANGULARVEL)*pos if spin else pos
        geo = world.GEOPOSITIONOF(actual+world.POSITION)
        def check(): return ks.call('_deorbitCheckGeometry',env,geo,impact_ut)
        result = check()
        assert result['TR_NATIVE_GAP'] < .01 and result['TR_QUATERNION_GAP'] < .01,result
        assert np.linalg.norm(result['POSITION']-pos) < 1e-8
        # Deliberately corrupt one frame convention. The independent
        # quaternion measurement must expose, not share, that defect.
        original = env['lmGroundGeoAt']
        env['lmGroundGeoAt'] = lambda ut: Geo(original(ut).LAT,original(ut).LNG+20,world)
        result = check()
        assert result['TR_NATIVE_GAP'] > 15000 and result['TR_QUATERNION_GAP'] < .01,result
        env['lmGroundGeoAt'] = original
        geo = Geo(geo.LAT-10,geo.LNG+15,world)
        result = check()
        assert result['TR_NATIVE_GAP'] > 10000 and result['TR_QUATERNION_GAP'] > 10000,result
    print('PASS: native/quaternion comparisons agree for both spin directions and no spin; independent gaps expose a 20-degree frame defect and stale impact coordinates')


def check_read_only():
    clean = mask(COMMAND)
    assert not command_entrypoint_errors(COMMAND)
    assert not re.search(r'\b(?:ADD|REMOVE|LOCK|UNLOCK|STAGE|REBOOT|SHUTDOWN)\b',clean)
    assert not re.search(r'\b(?:stateSet|stateRemove|missionOverrideUpdate|executeDeorbitNode|targetedDeorbitAt)\s*\(',clean)
    assert not re.search(r'\bSET\s+(?:WARP|THROTTLE|STEERING|SHIP:CONTROL)',clean)
    # Diagnostics do not become dependencies carried by every flight band.
    assert 'deorbitcheck' not in (ROOT/'lib/dependencies.ks').read_text()
    print('PASS: diagnostic has one wrapped command entry, no flight/node/mission-state mutation and no added flight-band dependency')


if __name__ == '__main__':
    check_geometry()
    check_read_only()
