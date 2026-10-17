"""Source-driven direct-ascent preview and independent point-mass checks.

No kOS VM, mesh/attitude/staging, or native KSP escape-patch validation.
"""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask, dependency_tables, closure
from check_deorbit_geometry import Vec

SOURCE = (ROOT / 'lib/return_direct.ks').read_text()
ks.SOURCES += '\n' + SOURCE


def environment():
    env = dict(CONSTANT=NS(PI=math.pi, E=math.e, G0=9.80665), SQRT=math.sqrt,
               SIN=lambda x: math.sin(math.radians(x)), COS=lambda x: math.cos(math.radians(x)),
               LN=math.log, MOD=lambda x,y: x%y, V=lambda *xs: Vec(xs),
               LIST=lambda *xs: list(xs), ROUND=lambda number,digits=0: str(round(number,digits)),
               fixture_wait=lambda _: None)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)', SOURCE):
        env[name] = lambda *args, name=name: ks.call(name, env, *args)
    return env


def context():
    site = math.radians(97)
    radius, mu, parent_mu, moon_radius = 203800., 6.5138398e10, 3.5316e12, 12e6
    pos = Vec((math.cos(site)*radius, math.sin(site)*radius, 0))
    east = Vec((-math.sin(site), math.cos(site), 0))
    return dict(VALID=True, REASON='ok', POS=pos, VEL=east*(2*math.pi*radius/138984.38),
                NORTH=Vec((0,0,1)), EAST=east, MU=mu, RADIUS=200000., SOI=2429559.,
                PARENT_MU=parent_mu, PARENT_RADIUS=600000., MOON_RADIUS=moon_radius,
                PERIOD=2*math.pi*math.sqrt(moon_radius**3/parent_mu),
                ACC=3.36, VE=320*9.80665, AVAILABLE=1200., BUDGET=1180.,
                TARGET_PE=53000., EPOCH=1000., CLEAR_TIME=math.sqrt(300/(3.36-mu/radius**2)))


def reference_coast(pos, vel, mu, soi, duration):
    """Independent numerical two-body propagation; no anomaly formula."""
    state = np.r_[pos, vel].astype(float)
    def rate(st):
        return np.r_[st[3:], -mu*st[:3]/np.linalg.norm(st[:3])**3]
    steps = math.ceil(duration/1.)
    dt = duration/steps
    for _ in range(steps):
        k1 = rate(state)
        k2 = rate(state+dt*k1/2)
        k3 = rate(state+dt*k2/2)
        k4 = rate(state+dt*k3)
        state += dt*(k1+2*k2+2*k3+k4)/6
    assert abs(np.linalg.norm(state[:3])-soi) < .5
    return state


def check_conic_propagation():
    env = environment()
    mu, soi, peri = 6.5138398e10, 2429559., 220000.
    for ecc in (.85, 1., 1.00000004, 1.3):
        semi_latus = peri*(1+ecc)
        nu = math.radians(25)
        radius = semi_latus/(1+ecc*math.cos(nu))
        pos = Vec((radius*math.cos(nu), radius*math.sin(nu), 0))
        vel = math.sqrt(mu/semi_latus)*Vec((-math.sin(nu), ecc+math.cos(nu), 0))
        coast = env['rdCoastToSoi'](pos, vel, mu, soi)
        assert coast['VALID'], ecc
        expected = reference_coast(pos, vel, mu, soi, coast['TIME'])
        assert np.linalg.norm(coast['POS']-expected[:3]) < .6, (ecc, coast, expected)
        assert np.linalg.norm(coast['VEL']-expected[3:]) < .001
        before_energy = vel.MAG**2/2-mu/pos.MAG
        after_energy = coast['VEL'].MAG**2/2-mu/soi
        assert abs(before_energy-after_energy) < 1e-8
    for pos, vel in ((Vec((220000,0,0)), Vec((-1,900,0))),
                     (Vec((220000,0,0)), Vec((0,300,0))),
                     (Vec((220000,0,0)), Vec((900,0,0))),
                     (Vec((soi,0,0)), Vec((0,900,0)))):
        assert not env['rdCoastToSoi'](pos, vel, mu, soi)['VALID']
    print('PASS: ellipse/hyperbola/parabolic SOI handoffs agree with independent numerical propagation and conserve energy; inbound/non-escaping/radial states rejected')


def reference_powered(ctx, program):
    """Independent small-step Heun ascent in the fixture's equatorial plane."""
    pos, vel = np.array(ctx['POS']), np.array(ctx['VEL'])
    duration = ctx['VE']/ctx['ACC']*(1-math.exp(-program['DV']/ctx['VE']))
    steps = math.ceil(duration/.01)
    dt = duration/steps
    def acceleration(point, time):
        radius = np.linalg.norm(point)
        radial = point/radius
        # AZ=90 in this oracle; no cross products or production helper calls.
        tangent = np.array((-radial[1], radial[0], 0))
        fraction = max(0, time-ctx['CLEAR_TIME'])/program['TURN']
        pitch = math.radians(program['FLOOR']+(90-program['FLOOR'])*math.exp(-fraction**program['POWER']))
        return ctx['ACC']/(1-ctx['ACC']*time/ctx['VE'])*(radial*math.sin(pitch)+tangent*math.cos(pitch))-ctx['MU']*radial/radius**2
    for step in range(steps):
        first = acceleration(pos, step*dt)
        second = acceleration(pos+vel*dt, (step+1)*dt)
        pos += dt*vel + dt*dt*first/2
        vel += dt*(first+second)/2
    env = environment()
    coast = env['rdCoastToSoi'](Vec(pos), Vec(vel), ctx['MU'], ctx['SOI'])
    assert coast['VALID']
    phase = 2*math.pi*(duration+coast['TIME'])/ctx['PERIOD']
    parent_pos = np.array((math.cos(phase), math.sin(phase), 0))*ctx['MOON_RADIUS']+coast['POS']
    parent_vel = np.array((-math.sin(phase), math.cos(phase), 0))*ctx['MOON_RADIUS']*2*math.pi/ctx['PERIOD']+coast['VEL']
    energy = np.dot(parent_vel,parent_vel)/2-ctx['PARENT_MU']/np.linalg.norm(parent_pos)
    h2 = np.linalg.norm(np.cross(parent_pos,parent_vel))**2
    eccentricity = math.sqrt(1+2*energy*h2/ctx['PARENT_MU']**2)
    return h2/(ctx['PARENT_MU']*(1+eccentricity))-ctx['PARENT_RADIUS']


def check_powered_prediction():
    env, ctx = environment(), context()
    program = dict(AZ=90, TURN=5., POWER=.9664756, FLOOR=17.4651, DV=976.9115)
    coarse = env['rdPredict'](ctx, program, .5)
    fine = env['rdPredict'](ctx, program, .125)
    assert coarse['VALID'] and fine['VALID']
    reference = reference_powered(ctx, program)
    assert 51000 < fine['PE'] < 55000, fine
    assert abs(fine['PE']-reference) < 40, (fine, reference)
    assert abs(fine['PE']-coarse['PE']) < 100
    tuned = env['_rdTuneEntry'](ctx, dict(program))
    actual = env['rdPredict'](ctx, tuned, .125)
    assert actual['VALID'] and abs(actual['PE']-53000) <= 1000, actual
    assert tuned['DV'] <= ctx['BUDGET']
    # Same geometry in a reflected parent-orbit-normal basis.
    mirrored = dict(ctx, NORTH=-ctx['NORTH'])
    assert abs(env['rdPredict'](mirrored, program, .5)['PE']-coarse['PE']) < 1e-6
    # Reported landed budget: do not invent dry mass/fuel to fit a 977 m/s burn.
    constrained = dict(ctx, AVAILABLE=830.5, BUDGET=810.5)
    assert not env['rdPredict'](constrained, program, .5)['VALID']
    affordable = dict(program, DV=810.5)
    assert not env['rdPredict'](constrained, affordable, .5)['VALID']
    assert not env['rdPredict'](ctx, dict(program, DV=0), .5)['VALID']
    assert not env['rdPredict'](ctx, program, 0)['VALID']
    print(f'PASS: finite-burn predictor agrees with independent Heun ascent; Pe tuned to {actual["PE"]/1000:.3f} km, budget limits and reflected geometry retained (synthetic craft, not flight proof)')


def check_snapshot():
    env, ctx = environment(), context()
    parent = NS(NAME='Kerbin', POSITION=Vec((1e8,2e8,-3e7)), MU=ctx['PARENT_MU'], RADIUS=600000.)
    moon = NS(NAME='Mun', BODY=parent, POSITION=parent.POSITION+Vec((12e6,0,0)),
              ATM=NS(EXISTS=False), ORBIT=NS(ECCENTRICITY=0, PERIOD=ctx['PERIOD']),
              MU=ctx['MU'], RADIUS=200000., SOIRADIUS=ctx['SOI'])
    engine = NS(IGNITION=True, FLAMEOUT=False, THROTTLELOCK=False, AVAILABLETHRUST=10., VISP=320.)
    inactive = NS(IGNITION=False, FLAMEOUT=False, THROTTLELOCK=False, AVAILABLETHRUST=200., VISP=400.)
    ship = NS(STATUS='LANDED', BODY=moon, POSITION=moon.POSITION+ctx['POS'], MASS=10/3.36,
              VELOCITY=NS(ORBIT=ctx['VEL']), ENGINES=[engine,inactive], DELTAV=NS(VACUUM=2000.))
    env.update(SHIP=ship, STAGE=NS(DELTAV=NS(VACUUM=830.5)), TIME=NS(SECONDS=1000.),
               POSITIONAT=lambda obj,ut: parent.POSITION+12e6*Vec((math.cos(2*math.pi*(ut-1000)/ctx['PERIOD']),math.sin(2*math.pi*(ut-1000)/ctx['PERIOD']),0)),
               HEADING=lambda az,pitch: NS(FOREVECTOR=ctx['NORTH']*math.cos(math.radians(az))+ctx['EAST']*math.sin(math.radians(az))))
    result = env['_rdSnapshot']()
    assert result['VALID'] and result['AVAILABLE'] == 830.5 and result['ACC'] == 3.36, result
    assert abs(result['VE']-320*9.80665) < 1e-10
    assert np.linalg.norm(result['POS']-ctx['POS']) < 1e-7
    moon.ORBIT.ECCENTRICITY = .01
    assert not env['_rdSnapshot']()['VALID']
    moon.ORBIT.ECCENTRICITY = 0
    engine.IGNITION = False
    assert not env['_rdSnapshot']()['VALID']
    engine.IGNITION = True
    ship.STATUS = 'SUB_ORBITAL'
    assert not env['_rdSnapshot']()['VALID']
    print('PASS: snapshot measures active limited thrust/Isp, caps current-stage fuel, ignores inactive engines, and refuses unsupported bodies/orbits or airborne replanning')


def check_preview_controls():
    # Execute orchestration with cheap model responses, including cancellation
    # and changed live state. Numerical physics is checked separately above.
    def without_print(nodes):
        return [(s, without_print(yes), without_print(no)) for s,yes,no in nodes
                if not s.startswith(('PRINT ', 'LOCAL snapshotText '))]
    nodes = without_print(ks.parse(function_body(SOURCE, 'previewDirectReturn')))
    for scenario in ('candidate', 'no-entry', 'abort', 'changed', 'status'):
        env, ctx = environment(), context()
        recorded, snapshots, events = [], [], []
        flag = type('Flag', (), {'__bool__': lambda self: bool(self.value)})()
        flag.value = False
        def snapshot():
            snapshots.append(1)
            if scenario == 'changed' and len(snapshots) > 1:
                return dict(VALID=False, REASON='vehicle-changed')
            return dict(ctx)
        def predict(context_, program, step):
            recorded.append(dict(program))
            assert 0 < program['DV'] <= context_['BUDGET']
            if scenario == 'abort': flag.value = True
            return dict(VALID=scenario != 'no-entry', PE=53000., SCORE=program['DV'], REASON='fixture')
        env.update(targetPe=53000., reserveDv=20., search=scenario != 'status',
                   CONFIG=NS(IPU=150), WARP=0, ABORT=flag,
                   SHIP=NS(STATUS='LANDED', THRUST=0, CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
                   _rdSnapshot=snapshot, rdPredict=predict, _rdTuneEntry=lambda ctx,prog: prog,
                   stateSet=lambda *args: events.append(('set',args)), stateRemove=lambda *args: events.append(('remove',args)))
        try: ks.run(nodes, env)
        except ks.Returned as result: assert result.value is (scenario == 'candidate')
        else: raise AssertionError('preview did not return')
        assert env['CONFIG'].IPU == 150
        if scenario == 'status':
            assert not events and not recorded and len(snapshots) == 1
            continue
        assert events[0] == ('set', ('burn_prior_ipu',150))
        assert events[-1] == ('remove', ('burn_prior_ipu',))
        assert recorded and len(recorded) <= 515
    clean = mask(SOURCE + (ROOT/'cmd/directreturn.ks').read_text())
    assert not re.search(r'\b(?:LOCK|UNLOCK|REBOOT|ADD|REMOVE)\b|\bSTAGE\s*\.', clean)
    assert 'nextPhase(' not in SOURCE and 'missionOverride' not in SOURCE
    assert re.findall(r'stateSet\("([^"]+)"', SOURCE) == ['burn_prior_ipu']
    libs, phases, _ = dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert libs['return_direct'] == []
    assert all('return_direct' not in closure(roots, libs) for roots in phases.values())
    print('PASS: bounded preview never burns, stages, changes nodes or mission; cancellation/state changes restore CPU and ordinary phase bands do not load the preview')


if __name__ == '__main__':
    check_conic_propagation()
    check_snapshot()
    check_powered_prediction()
    check_preview_controls()
