"""Execute the footprint solver against numerical response/Kepler fixtures.

Not the kOS VM or Trajectories scheduling/terrain. Actual KSP flight required.
"""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask
from check_surface_return import read_settings

SOURCE = (ROOT/'lib/deorbit_targeting.ks').read_text()
LANDING = (ROOT/'lib/landing_deorbit.ks').read_text()
ks.SOURCES += '\n' + SOURCE


class Counter:
    def __init__(self): self.value = 0
    def __add__(self, number): return self.value + number
    def __ge__(self, number): return self.value >= number


def environment(oracle, cap=10, budget=64):
    counter, trials = Counter(), []
    env = dict(TIME=NS(SECONDS=0), ABORT=False, SHIP=NS(DELTAV=NS(VACUUM=1000)),
               TARGET_DEORBIT_NORMAL_DV_CAP=cap, TARGET_DEORBIT_MAX_EVALUATIONS=budget,
               TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM=.25, DEORBIT_MIN_FPA=0,
               _deorbitEvaluations=counter, LIST=lambda *xs: list(xs),
               SQRT=math.sqrt, fixture_wait=lambda _: None)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)', SOURCE):
        env[name] = lambda *args,name=name: ks.call(name,env,*args)
    env['_targetDeorbitCrossAuthority'] = lambda _: 500
    def evaluate(ut, retro, lat, lng, lead, desired, normal=0):
        if counter.value >= budget or ut <= env['TIME'].SECONDS+lead:
            return dict(VALID=False,HAS_IMPACT=False)
        assert 2-1e-8 <= retro <= 120+1e-8 and abs(normal) <= cap+1e-8
        counter.value += 1
        result = oracle(ut,retro,normal)
        trials.append(result)
        return result
    env['_evalGeometricDeorbitNode'] = evaluate
    return env, counter, trials


def impact(ut, retro, normal, along_error, signed_cross, valid=True):
    return dict(VALID=valid, HAS_IMPACT=valid, UT=ut, RETRO=retro, NORMAL=normal,
                DV=math.hypot(retro,normal), DOWNFIELD=15000+along_error, ERR=along_error,
                CROSS=abs(signed_cross), SIGNED_CROSS=signed_cross, ANGLE=20,
                PE=-8000,LAT=19.,LNG=129.,DIST=math.hypot(15000+along_error,signed_cross),TTI=500)


def solve(env, base):
    return env['_refineDeorbitFootprint'](base,19.,129.,120,15000,10000,20000,2,120)


def kepler_oracle(true_ut=1000, true_retro=15, true_normal=3.5, mirror=1):
    """Independent circular 20-degree Minmus orbit, instantaneous deorbit.

    Exact ellipse intersection with the surface, including Minmus rotation.
    Target is 15 km upstream of one known reachable ballistic footprint.
    """
    mu, orbital_radius, radius = 1.7658e9, 75000., 60000.
    inc, spin = math.radians(20), 2*math.pi/40400.
    rate = math.sqrt(mu/orbital_radius**3)
    def rotation(angle):
        return np.array(((math.cos(angle),-math.sin(angle),0),
                         (math.sin(angle), math.cos(angle),0),(0,0,1)))
    def trajectory(ut, retro, normal):
        phase = rate*ut
        pos = orbital_radius*np.array((math.cos(phase),math.sin(phase)*math.cos(inc),math.sin(phase)*math.sin(inc)))
        velocity = orbital_radius*rate*np.array((-math.sin(phase),math.cos(phase)*math.cos(inc),math.cos(phase)*math.sin(inc)))
        velocity = velocity-retro*velocity/np.linalg.norm(velocity)+normal*mirror*np.array((0,-math.sin(inc),math.cos(inc)))
        hvec = np.cross(pos,velocity)
        eccentric = ((np.dot(velocity,velocity)-mu/orbital_radius)*pos-np.dot(pos,velocity)*velocity)/mu
        ecc = np.linalg.norm(eccentric)
        energy = np.dot(velocity,velocity)/2-mu/orbital_radius
        if energy >= 0 or ecc < 1e-8: return None
        semi = -mu/(2*energy)
        if semi*(1-ecc) >= radius: return None
        latus = np.dot(hvec,hvec)/mu
        cosine = (latus/radius-1)/ecc
        if abs(cosine) >= 1: return None
        nu = 2*math.pi-math.acos(cosine)
        anomaly = math.atan2(math.sqrt(1-ecc*ecc)*math.sin(nu),ecc+math.cos(nu))%(2*math.pi)
        coast = (anomaly-ecc*math.sin(anomaly)-math.pi)/math.sqrt(mu/semi**3)
        if coast <= 0: return None
        peri = eccentric/ecc
        transverse = np.cross(hvec/np.linalg.norm(hvec),peri)
        contact = radius*(math.cos(nu)*peri+math.sin(nu)*transverse)
        contact_vel = math.sqrt(mu/latus)*(-math.sin(nu)*peri+(ecc+math.cos(nu))*transverse)
        world_to_surface = rotation(-spin*(ut+coast))
        surface_up = world_to_surface@contact/radius
        surface_vel = world_to_surface@(contact_vel-np.cross((0,0,spin),contact))
        tangent = surface_vel-surface_up*np.dot(surface_up,surface_vel)
        tangent /= np.linalg.norm(tangent)
        angle = abs(math.degrees(math.asin(np.dot(surface_up,world_to_surface@contact_vel)/np.linalg.norm(contact_vel))))
        return surface_up,tangent,coast,angle
    truth = trajectory(true_ut,true_retro,true_normal)
    assert truth is not None
    target = math.cos(15000/radius)*truth[0]-math.sin(15000/radius)*truth[1]
    def oracle(ut,retro,normal):
        result = trajectory(ut,retro,normal)
        if result is None: return impact(ut,retro,normal,0,0,False)
        up,tangent,coast,angle = result
        along = radius*math.atan2(-np.dot(target,tangent),np.dot(target,up))
        cross = radius*math.asin(np.clip(np.dot(target,np.cross(up,tangent)),-1,1))
        prediction = impact(ut,retro,normal,along-15000,cross)
        prediction.update(TTI=coast,ANGLE=angle)
        return prediction
    oracle.period = 2*math.pi/rate
    oracle.target = target
    oracle.ground = lambda ut: rotation(-spin*ut)@np.array((math.cos(rate*ut),math.sin(rate*ut)*math.cos(inc),math.sin(rate*ut)*math.sin(inc)))
    return oracle


def check_physical_solver():
    for mirror in (-1,1):
        oracle = kepler_oracle(mirror=mirror)
        env,count,trials = environment(oracle)
        base = oracle(1000,16,0)
        assert base['VALID'] and base['CROSS'] > 500, base
        result = solve(env,base)
        assert env['_targetDeorbitSolutionAccepted'](result,10000,20000), result
        assert result['CROSS'] <= 250 and abs(result['NORMAL']) > .1
        assert count.value <= 12, count.value
        assert abs(result['NORMAL']) <= 10
    oracle = kepler_oracle(true_ut=1045,true_normal=0)
    env,count,trials = environment(oracle,cap=0)
    result = solve(env,oracle(1000,16,0))
    assert env['_targetDeorbitSolutionAccepted'](result,10000,20000),result
    assert result['CROSS'] <= 250 and result['NORMAL'] == 0
    assert abs(result['UT']-1000) <= 120 and abs(result['UT']-1000) > 1
    assert count.value <= 12
    # Exercise the actual geometric seed scan and impact bootstrap as well,
    # rather than supplying only a conveniently close known burn time.
    oracle = kepler_oracle()
    env,count,_ = environment(oracle)
    def ground_angle(ut,*args):
        return dict(VALID=True,UT=ut,ANGLE=math.degrees(math.acos(np.clip(
            np.dot(oracle.ground(ut),oracle.target),-1,1))),LAT=0,LNG=0)
    env['_targetGroundAngleAt'] = ground_angle
    found = False
    for angle in (50,35,65,20,80):
        seed = env['_findDeorbitGeometryNode'](19,129,157,157+oracle.period+30,oracle.period/512,angle)
        if seed['VALID']:
            result = env['_solveGeometricDeorbitDv'](seed['UT'],19,129,120,2,120,15,15000,10000,20000)
            if env['_targetDeorbitRefineDone'](result,10000,20000):
                found = True
                break
    assert found and count.value <= 64,(count.value,result)
    print('PASS: 20-degree Minmus Kepler footprints converge with both normal signs; timing correction works without a normal burn, within bounded native evaluations')


def check_progress_and_failure():
    def nonlinear(ut,retro,normal):
        return impact(ut,retro,normal,-1200*(retro-15)+300*normal,
                      3000+700*normal+100*normal**3)
    env,count,trials = environment(nonlinear)
    base = nonlinear(1000,15,0)
    result = solve(env,base)
    assert result['CROSS'] <= 250,result
    assert any(t['CROSS'] > base['CROSS'] for t in trials) # Rejected large step.
    assert count.value < 20
    for budget in (3,64):
        def unreachable(ut,retro,normal):
            return impact(ut,retro,normal,-1000*(retro-15),3000+100*normal)
        env,count,trials = environment(unreachable,budget=budget)
        result = solve(env,unreachable(1000,15,0))
        assert count.value <= budget
        assert all(abs(t['NORMAL']) <= 10 and 880 <= t['UT'] <= 1120 for t in trials)
        assert not env['_targetDeorbitSolutionAccepted'](result,10000,20000)
    flat = lambda ut,retro,normal: impact(ut,retro,normal,0,3000)
    env,count,_ = environment(flat)
    result = solve(env,flat(1000,15,0))
    assert result['CROSS'] == 3000 and count.value <= 4
    # Bootstrap increasing retro only until an impact exists, then use the
    # coupled solve; current-time and evaluation bounds are not bypassed.
    env,count,_ = environment(lambda ut,retro,normal: impact(ut,retro,normal,0,0,retro >= 22))
    result = env['_solveGeometricDeorbitDv'](1000,19,129,120,2,120,15,15000,10000,20000)
    assert result['VALID'] and count.value == 2
    # Do not lose an already admissible candidate while chasing the preferred
    # cross range if subsequent improvements fail another physical gate.
    def steep(ut,retro,normal):
        row = impact(ut,retro,normal,-1000*(retro-15),400+100*normal)
        row['ANGLE'] = 45 if normal == 0 else 10
        return row
    env,_,_ = environment(steep)
    env['DEORBIT_MIN_FPA'] = 30
    base = steep(1000,15,0)
    result = solve(env,base)
    assert result is base and env['_targetDeorbitSolutionAccepted'](result,10000,20000)
    print('PASS: nonlinear oversized steps backtrack; saturated/singular/budget-exhausted solves retain the best prediction and fail strict gates; impact bootstrap stops promptly')


def check_geometry_before_light():
    planner = function_body(SOURCE,'targetedDeorbitAt')
    start = planner.index('IF NOT solved["VALID"]')
    stop = planner.index('\n            } ELSE {\n                mLogWarn("No deorbit node found',start)
    nodes = ks.parse(planner[start:stop])
    for kind in ('no-impact','cross-track','fuel','accepted','bad-light'):
        env,_,_ = environment(lambda *args: None)
        candidate = impact(1234,15,0,0,100)
        if kind == 'no-impact': candidate['VALID'] = False
        if kind == 'cross-track': candidate['CROSS'] = 2000
        if kind == 'fuel': candidate['DV'] = 2000
        light_calls = []
        env.update(solved=candidate,geometry=dict(UT=1111),targetLat=19,targetLng=129,
                   minDownfield=10000,maxDownfield=20000,orbitScan=0,scanOrbits=4,
                   candidateAngle=50,bestAccepted=dict(VALID=False),bestAcceptedCross=1e9,
                   preferredCrossTrack=250,acceptedSolution=False,
                   _targetDeorbitLightAccepted=lambda solved,ut,*args: light_calls.append(ut) or kind != 'bad-light')
        ks.run(nodes,env)
        assert light_calls == ([1234] if kind in ('accepted','bad-light') else [])
        assert env['acceptedSolution'] is (kind == 'accepted')
    for craft in ('RO8','RO9'):
        for moon in ('mun','minmus'):
            profile = read_settings((ROOT/f'missions/{craft}/{moon}_economy_return.ks').read_text(),{})
            assert profile['TARGET_DEORBIT_NORMAL_DV_CAP'] == 10
            assert profile['TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM'] == .25
            assert profile['DEORBIT_CROSSTRACK_AUTHORITY_KM'] == .5
    print('PASS: impossible/fuel-invalid footprints never run the light solve; adjusted burn UT is used for light, and all economy profiles enable bounded lateral correction')


def without_print(nodes):
    return [(s,without_print(yes),without_print(no)) for s,yes,no in nodes if not s.startswith('PRINT ')]


def check_resume_and_cpu():
    nodes = without_print(ks.parse(function_body(LANDING,'_resumeExistingLandingDeorbitNode')))
    for status,started,skip,allowed in (('ORBITING',False,0,False),('ORBITING',False,0,True),
                                       ('SUB_ORBITAL',False,0,False),('ORBITING',True,0,False),
                                       ('ORBITING',False,1,False)):
        calls = []
        env = dict(HASNODE=True,NEXTNODE=NS(DELTAV=NS(MAG=15),ETA=500),
                   SHIP=NS(STATUS=status,PERIAPSIS=15000,BODY=NS(NAME='Minmus')),
                   LANDING_SKIP_TARGET_SEARCH=skip,
                   stateGet=lambda *args: 'true' if started else 'false',
                   landingResolveTarget=lambda: dict(FOUND=True,LAT=19,LNG=129),
                   landingDeorbitNodeAccepted=lambda *args: calls.append('validate') or allowed,
                   executeDeorbitNode=lambda *args: calls.append('burn') or False,
                   yieldToPrompt=lambda: calls.append('hold'),stateSet=lambda *args: None)
        try: ks.run(nodes,env)
        except ks.Returned as result: assert result.value is True
        assert ('validate' in calls) == (status=='ORBITING' and not started and not skip)
        assert ('burn' in calls) == (allowed or status!='ORBITING' or started or skip)
        assert env['HASNODE'] is True
    nodes = without_print(ks.parse(function_body(LANDING,'_landingTargetedDeorbit')))
    for prior,success in ((150,True),(150,False),(2000,True)):
        events,config = [],NS(IPU=prior)
        env = dict(CONFIG=config,LANDING_MIN_IPU=2000,LANDING_REQUIRE_SITE=0,
                   landingResolveTarget=lambda: dict(FOUND=True,LAT=19,LNG=129),
                   selectScanSatLandingSite=lambda *args: dict(FOUND=False),
                   stateSet=lambda *args: events.append(('save',args)),
                   stateRemove=lambda *args: events.append(('remove',args)),
                   targetedDeorbitAt=lambda *args: events.append(('plan',config.IPU)) or success)
        try: ks.run(nodes,env)
        except ks.Returned as result: assert result.value is success
        assert config.IPU == prior and ('plan',2000) in events
        if prior==150: assert events[-1] == ('remove',('landing_prior_ipu',))
    print('PASS: unflown retained nodes revalidate without deletion; interrupted/suborbital/timed paths keep recovery behavior; planning CPU restores after success or failure')


def check_actual_trial_budget():
    source = function_body(SOURCE,'_evalGeometricDeorbitNode')
    source = source.replace('REMOVE NEXTNODE.', 'remove_node(NEXTNODE).').replace('REMOVE nd.', 'remove_node(nd).')
    nodes = ks.parse(source)
    for used,available,ut,aborted,allowed in ((63,1000,1000,False,True),(64,1000,1000,False,False),
                                            (0,1,1000,False,False),(0,1000,100,False,False),
                                            (0,1000,1000,True,False)):
        events = []
        env = dict(burnUT=ut,retroDv=15,targetLat=19,targetLng=129,minLead=120,ABORT=aborted,
                   desiredDownfield=15000,normalDv=0,_deorbitEvaluations=used,
                   TARGET_DEORBIT_MAX_EVALUATIONS=64,TIME=NS(SECONDS=0),SQRT=math.sqrt,
                   SHIP=NS(DELTAV=NS(VACUUM=available)),HASNODE=not allowed,NEXTNODE=object(),
                   fixture_wait=lambda _: None)
        def plan(*args):
            events.append('add')
            env['HASNODE'] = True
            return object()
        def remove(node):
            events.append('remove')
            env['HASNODE'] = False
        env.update(_planRetroNode=plan,remove_node=remove,
                   _readGeometricDeorbitNode=lambda *args: dict(VALID=True,HAS_IMPACT=True))
        try: ks.run(nodes,env)
        except ks.Returned as result: assert result.value['VALID'] is allowed
        assert env['_deorbitEvaluations'] == used + int(allowed)
        assert events == (['add','remove'] if allowed else [])
        assert env['HASNODE'] is (not allowed) # Existing node untouched on refusal.
    print('PASS: production evaluation entry enforces the 64-call, fuel and lead-time bounds before touching nodes')


def check_shared_terrain():
    env,_,_ = environment(lambda *args: None)
    requests = []
    env.update(TERRAIN_VALIDATE=True,TERRAIN_MIN_CLEARANCE=100,TERRAIN_SAFE_ALT=6500)
    for hit,downfield,expected in ((False,0,True),(True,-1,False),(True,19672,True)):
        env['lmTerrainClearanceInfo'] = lambda *args: requests.append(args) or dict(HIT=hit,DOWNFIELD=downfield)
        assert env['_targetDeorbitTerrainAccepted'](1000,19,129) is expected
    assert all(args == (19,129,1000,1030,2800,2,100,6500) for args in requests)
    env['TERRAIN_VALIDATE'] = False
    assert env['_targetDeorbitTerrainAccepted'](1000,19,129) and len(requests) == 3
    planner = function_body(SOURCE,'targetedDeorbitAt')
    retained = function_body(SOURCE,'landingDeorbitNodeAccepted')
    assert '_targetDeorbitTerrainAccepted(bestUT, targetLat, targetLng)' in planner
    assert '_targetDeorbitTerrainAccepted(nd:TIME, targetLat, targetLng)' in retained
    print('PASS: new and retained unflown nodes share the original terrain window/clearance guard; pre-target collisions reject, intentional post-target contact remains allowed')


if __name__ == '__main__':
    check_physical_solver()
    check_progress_and_failure()
    check_geometry_before_light()
    check_resume_and_cpu()
    check_actual_trial_budget()
    check_shared_terrain()
