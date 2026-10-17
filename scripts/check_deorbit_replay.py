"""Independent recorded-state regression, not a kOS or powered-flight test."""
import math

import numpy as np

from replay_deorbit import ellipse, parse_snapshot, replay, rotate


# Reduced numeric records from the operator's unflown Minmus node. The
# snapshot's rows were taken sequentially, not at a common atomic epoch.
SNAPSHOT = '''STATS deorbit-check schema=2 ut=1305239.30875045
STATS deorbit-check body name=Minmus radius=60000 mu=1765800026.31247 angularVel=V(0,-0.000155524408910424,9.26997627964665E-12)
STATS deorbit-check current lat=-4.6833180183266 lng=-15.8367833575132 relativePos=V(-16024.4175205725,-6088.3602939158,-72571.0049937764) orbitalVel=V(122.906103076855,86.2705763838202,-32.9923387080884)
STATS deorbit-check target found=True configuredLat=18.1420953580792 configuredLng=76.9114750412703
STATS deorbit-check light point=target-now ut=1305239.34875045 lat=18.1420953580792 lng=76.9114750412703
STATS deorbit-check target terrain=3602.9
STATS deorbit-check node ut=1312101.32724091 prograde=-14.853496280424 normal=0 radial=0 pe=-8179.16178477471
STATS deorbit-check sample=1 ut=1305239.34875045 impactUT=1312746.55440385 impactLat=8.45481697 impactLng=91.62155 nativeBody=Minmus
'''


def check_recorded_node():
    data = parse_snapshot(SNAPSHOT)
    result = replay(data)
    # Reproduce the game's independently logged orbital/impact quantities
    # before trusting this replay to explain the target's rotating geometry.
    assert abs(result['node_pe_error_m']) < .2, result
    assert result['impact_fit_m'] < 5, result
    assert 16000 < result['target_plane_now_m'] < 18000, result
    assert 50 < result['target_pass_miss_m'] < 80, result
    assert 2900 < result['pass_above_target_terrain_m'] < 2950, result
    assert 65 < result['rotation_to_pass_deg'] < 67, result
    assert 125 < result['pass_before_impact_s'] < 132, result
    assert -27 < result['pass_vs_m_s'] < -25, result
    assert 146 < result['pass_hs_m_s'] < 149, result
    # Handle missing early TR samples and later schema versions without
    # depending on an absolute file path or the operator's original report.
    absent = 'STATS deorbit-check sample=0 hasImpact=false\n'
    assert replay(parse_snapshot(absent + SNAPSHOT.replace('schema=2','schema=3'))) == result
    # A resolved waypoint supersedes stale configured coordinates.
    stale = SNAPSHOT.replace('configuredLat=18.1420953580792','configuredLat=0')
    assert replay(parse_snapshot(stale)) == result
    for invalid in (SNAPSHOT.replace('found=True','found=False'),
                    SNAPSHOT.replace('nativeBody=Minmus','nativeBody=Kerbin')):
        try:
            parse_snapshot(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError('No target or an SOI change must refuse replay')
    for field in ('radial','normal'):
        unsupported = dict(data, **{field: 1})
        try:
            replay(unsupported)
        except ValueError as exc:
            assert 'prograde/retrograde-only' in str(exc)
        else:
            raise AssertionError('Do not silently replay an unsupported node')
    print('PASS: recorded Minmus node matches native Pe/impact; rotating target passes within 80m despite a present-day 17km plane offset; nonzero radial/normal nodes refused')


def check_propagation():
    data = parse_snapshot(SNAPSHOT)
    position, velocity, mu = data['position'],data['velocity'],data['mu']
    state,_,_ = ellipse(position,velocity,mu)
    point,speed = state(0)
    assert np.linalg.norm(point-position) < 1e-8
    assert np.linalg.norm(speed-velocity) < 1e-10
    energy = np.dot(velocity,velocity)/2-mu/np.linalg.norm(position)
    momentum = np.cross(position,velocity)
    for elapsed in (-7000,3036.31737918477,7500):
        point,speed = state(elapsed)
        assert abs(np.dot(speed,speed)/2-mu/np.linalg.norm(point)-energy) < 1e-9
        assert np.linalg.norm(np.cross(point,speed)-momentum) < 1e-7
    # Full rotations and reversing the measured rotation undo one another.
    spin = np.array((0.,0.,2*math.pi/40400))
    assert np.linalg.norm(rotate(position,spin,40400)-position) < 1e-8
    assert np.linalg.norm(rotate(rotate(position,spin,7500),spin,-7500)-position) < 1e-8
    try:
        ellipse(position,velocity*10,mu)
    except ValueError:
        pass
    else:
        raise AssertionError('Unbound propagation is outside this replay')
    print('PASS: independent Kepler propagation reproduces its initial state and conserves orbital energy/momentum; rotation round-trips and unbound rejection verified')


if __name__ == '__main__':
    check_recorded_node()
    check_propagation()
