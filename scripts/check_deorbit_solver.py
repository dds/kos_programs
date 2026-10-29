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
from check_runtime_contracts import run, KList

SOURCE = (ROOT/'lib/deorbit_targeting.ks').read_text()
LANDING = (ROOT/'lib/landing_deorbit.ks').read_text()
LEAD = (ROOT/'lib/landing_deorbit_lead.ks').read_text()
ks.SOURCES += '\n' + SOURCE + '\n' + LEAD


class Lex(dict):
    HASKEY=dict.__contains__


class Counter:
    def __init__(self): self.value = 0
    def __add__(self, number): return self.value + number
    def __ge__(self, number): return self.value >= number


def environment(oracle, cap=10, budget=64):
    counter, trials = Counter(), []
    env = dict(LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),TIME=NS(SECONDS=0), ABORT=False, SHIP=NS(DELTAV=NS(VACUUM=1000)),
               TARGET_DEORBIT_NORMAL_DV_CAP=cap, TARGET_DEORBIT_MAX_EVALUATIONS=budget,
               TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS=0, LANDING_POWERED_LEAD=0,
               TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM=.25, DEORBIT_MIN_FPA=0,
               vesselLandingPrepareRoles=lambda:True,
               fixture_charge_forecast=lambda:setattr(counter,'value',counter.value+1),
               _deorbitEvaluations=counter, LIST=lambda *xs: KList(xs),
               SQRT=math.sqrt, fixture_wait=lambda _: None)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)', SOURCE + LEAD):
        env[name] = lambda *args,name=name: ks.call(name,env,*args)
    env['_targetDeorbitCrossAuthority'] = lambda _: 500
    def evaluate(ut, retro, lat, lng, lead, desired, normal=0):
        if counter.value >= budget or ut <= env['TIME'].SECONDS+lead:
            return Lex(VALID=False,HAS_IMPACT=False)
        assert 2-1e-8 <= retro <= 120+1e-8 and abs(normal) <= cap+1e-8
        counter.value += 1
        result = oracle(ut,retro,normal)
        trials.append(result)
        return result
    env['_evalGeometricDeorbitNode'] = evaluate
    return env, counter, trials


def impact(ut, retro, normal, along_error, signed_cross, valid=True):
    return Lex(VALID=valid, HAS_IMPACT=valid, UT=ut, RETRO=retro, NORMAL=normal,
                DV=math.hypot(retro,normal), DOWNFIELD=15000+along_error, ERR=along_error,
                CROSS=abs(signed_cross), SIGNED_CROSS=signed_cross, ANGLE=20,
                PE=-8000,LAT=19.,LNG=129.,DIST=math.hypot(15000+along_error,signed_cross),TTI=500)


def solve(env, base):
    return env['_refineDeorbitFootprint'](base,19.,129.,120,15000,10000,20000,2,120)


def kepler_oracle(true_ut=1000, true_retro=15, true_normal=3.5, mirror=1, mun=False):
    """Independent inclined circular orbit, instantaneous deorbit.

    Exact ellipse intersection with the surface, including Minmus rotation.
    Target is 15 km upstream of one known reachable ballistic footprint.
    """
    mu, orbital_radius, radius = (6.5138398e10,215000.,200000.) if mun else (1.7658e9,75000.,60000.)
    inc, spin = (math.pi/2,2*math.pi/138984.) if mun else (math.radians(20),2*math.pi/40400.)
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
        along = radius*math.atan2(-np.dot(oracle.target,tangent),np.dot(oracle.target,up))
        cross = radius*math.asin(np.clip(np.dot(oracle.target,np.cross(up,tangent)),-1,1))
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
        return Lex(VALID=True,UT=ut,ANGLE=math.degrees(math.acos(np.clip(
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


def check_selected_pass():
    def setup(fraction):
        oracle = kepler_oracle()
        pass_ut = fraction*oracle.period
        # The real picker chooses the UNBURNED ground track, not a point
        # constructed backwards from a conveniently feasible deorbit.
        oracle.target = oracle.ground(pass_ut)
        env,count,_ = environment(oracle)
        env['_targetGroundAngleAt'] = lambda ut,*args: Lex(VALID=True,UT=ut,
            ANGLE=math.degrees(math.acos(np.clip(np.dot(oracle.ground(ut),oracle.target),-1,1))),
            LAT=0,LNG=0)
        return oracle,pass_ut,env,count

    def search(oracle,env,pass_ut):
        for window_index in range(4):
            for angle in (50,35,65,20,80):
                if env['_deorbitEvaluations'] >= 64: return None
                window = env['_targetDeorbitScanWindow'](0,oracle.period,120,37,window_index,pass_ut)
                seed = env['_findDeorbitGeometryNode'](19,129,window['START'],window['END'],oracle.period/512,angle)
                if seed['VALID']:
                    result = env['_solveGeometricDeorbitDv'](seed['UT'],19,129,120,2,120,15,15000,10000,20000)
                    if env['_targetDeorbitRefineDone'](result,10000,20000): return result
        return None

    oracle,pass_ut,env,count = setup(1.5)
    # Reproduce the regression: discarded pass context spends all the
    # native evaluation budget on a 6+ km lateral miss in earlier passes.
    assert search(oracle,env,0) is None and count.value == 64
    for fraction in (.35,.7,1,1.5,2,2.7,3.8,4.3):
        oracle,pass_ut,env,count = setup(fraction)
        result = search(oracle,env,pass_ut)
        assert result is not None, (fraction,count.value)
        assert result['CROSS'] <= 250 and count.value <= 16, (fraction,result,count.value)
        assert abs(result['NORMAL']) < 1, result
        assert pass_ut-oracle.period/2 <= result['UT'] < pass_ut

    # Live lead margin still applies, later windows follow the selected
    # pass, and fixed/manual sites retain their ordinary forward search.
    env['TIME'].SECONDS = 500
    for context,index,expected in ((0,0,(657,3758)),(0,2,(6262,9363)),
                                    (4607,0,(3071.5,4607)),(4607,1,(4607,7708)),
                                    (4607,2,(7678,10779)),(600,0,(657,600))):
        window = env['_targetDeorbitScanWindow'](0,3071,120,37,index,context)
        assert (window['START'],window['END']) == expected, window
    env['_targetGroundAngleAt'] = lambda *args: (_ for _ in ()).throw(AssertionError('expired/aborted window sampled'))
    assert not env['_findDeorbitGeometryNode'](19,129,657,600,6,50)['VALID']
    env['ABORT'] = True
    assert not env['_findDeorbitGeometryNode'](19,129,657,800,6,50)['VALID']
    planner = function_body(SOURCE,'targetedDeorbitAt')
    assert 'window_["START"], window_["END"], stepA, candidateAngle' in planner
    assert 'after scanning ' not in planner
    assert 'windowsTried=' in planner and '"trial-budget"' in planner
    print('PASS: discarded pass time reproduces the 64-trial hold; matching eight unburned Minmus ground-track sites solves in <=16 trials with <1 m/s normal; expired/aborted windows refuse sampling')


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
    stop = planner.index('\n            } ELSE {\n                mLogDetail("No deorbit node found',start)
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
                   candidateAngle=50,bestAccepted=Lex(VALID=False),bestAcceptedCross=1e9,
                   newClosest=True,closestLight='not-checked',
                   preferredCrossTrack=250,acceptedSolution=False,
                   _targetDeorbitLightAccepted=lambda solved,ut,*args: light_calls.append(ut) or kind != 'bad-light')
        ks.run(nodes,env)
        assert light_calls == ([1234] if kind in ('accepted','bad-light') else [])
        assert env['acceptedSolution'] is (kind == 'accepted')
        assert env['closestLight'] == ('accepted' if kind=='accepted' else 'rejected' if kind=='bad-light' else 'not-checked')
    for craft in ('RO8','RO9'):
        for moon in ('mun','minmus'):
            profile = read_settings((ROOT/f'missions/{craft}/{moon}_economy_return.ks').read_text(),{})
            assert profile['TARGET_DEORBIT_NORMAL_DV_CAP'] == 10
            assert profile['TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM'] == .25
            assert profile['DEORBIT_CROSSTRACK_AUTHORITY_KM'] == .5
    print('PASS: impossible/fuel-invalid footprints never run the light solve; adjusted burn UT is used for light, and all economy profiles enable bounded lateral correction')


def without_print(nodes):
    return [(s,without_print(yes),without_print(no)) for s,yes,no in nodes if not s.startswith('PRINT ')]


def check_explicit_deorbit_retry():
    command=(ROOT/'cmd/deorbitretry.ks').read_text()
    ready=function_body(command,'ready')
    entry=function_body(command,'_cmdDeorbitretry').replace('LOCAL FUNCTION ready {'+ready+'}','')
    entry=re.sub(r'RUNPATH\([^\n]+\)\.', 'fixture_load().',entry)
    entry=entry.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
    entry=entry.replace('REMOVE nd.','remove_node(nd).')
    nodes=without_print(ks.parse(entry))
    for failure in ('none','minmus','no-node','more-nodes','no-kac','phase','body','suborbital',
                    'periapsis','eccentricity','soi','deorbit-started','burn-interrupted',
                    'abort','thrust','raw','pilot','nan-thrust','abort-after-settle'):
        saved=dict(phase='LAND_DEORBIT',vehicle='RO9',mission_id='mun_landing_return',
                   targetLat=44.593,targetLng=-24.926,returnReserve=900,
                   last_burn_report='keep',runtimeOverrides='keep byte for byte')
        removed=[];deleted=[]
        class Node:
            detached=False
            @property
            def TIME(self):
                assert not self.detached;return 2517639.3
            @property
            def DELTAV(self):
                assert not self.detached;return NS(MAG=38.5)
        node=Node();other=Node()
        queue=[] if failure=='no-node' else [node,other] if failure=='more-nodes' else [node]
        env=dict(HASNODE=bool(queue),NEXTNODE=queue[0] if queue else None,ABORT=False,WARP=4,
            SHIP=NS(BODY=NS(NAME='Mun'),STATUS='ORBITING',PERIAPSIS=14600,THRUST=0,
                ORBIT=NS(ECCENTRICITY=.0011,HASNEXTPATCH=False),
                CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
            stateGet=saved.get,fixture_load=lambda:None,bootPreamble=lambda:None,
            ADDONS=NS(KAC=NS(AVAILABLE=failure!='no-kac')),
            kacShipAlarmName=lambda name:'RO9: '+name,
            LISTALARMS=lambda _: [NS(NAME='RO9: Deorbit burn',ID='old-deorbit'),
                                 NS(NAME='Other: Deorbit burn',ID='other-vessel'),
                                 NS(NAME='RO9: SOI: Mun',ID='soi')],DELETEALARM=deleted.append)
        def available():
            try:ks.run(ks.parse(ready),env)
            except ks.Returned as result:return result.value
        def remove(candidate):
            assert candidate is queue.pop(0);candidate.detached=True;removed.append(candidate)
            env['HASNODE']=bool(queue);env['NEXTNODE']=queue[0] if queue else None
        def settle():
            if failure=='abort-after-settle':env['ABORT']=True
        env.update(ready=available,remove_node=remove,fixture_settle=settle)
        if failure=='minmus':env['SHIP'].BODY.NAME='Minmus'
        if failure=='phase':saved['phase']='LAND_ASSIST'
        if failure=='body':env['SHIP'].BODY.NAME='Kerbin'
        if failure=='suborbital':env['SHIP'].STATUS='SUB_ORBITAL'
        if failure=='periapsis':env['SHIP'].PERIAPSIS=-10
        if failure=='eccentricity':env['SHIP'].ORBIT.ECCENTRICITY=1.1
        if failure=='soi':env['SHIP'].ORBIT.HASNEXTPATCH=True
        if failure=='deorbit-started':saved['deorbit_burn_started']='true'
        if failure=='burn-interrupted':saved.update(burn_pending='true',burn_started='true')
        if failure=='abort':env['ABORT']=True
        if failure=='thrust':env['SHIP'].THRUST=1
        if failure=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if failure=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if failure=='nan-thrust':env['SHIP'].THRUST=math.nan
        original=dict(saved)
        try:ks.run(nodes,env)
        except ks.Returned:pass
        allowed=failure in ('none','minmus','no-node','more-nodes','no-kac')
        assert removed==([node] if allowed and failure!='no-node' else []),failure
        assert deleted==(['old-deorbit'] if allowed and failure not in ('no-node','no-kac') else []),failure
        assert saved==original,failure
        if allowed:assert env['WARP']==0
        if failure=='more-nodes':assert queue==[other] and not other.detached
    resume=function_body(LANDING,'_resumeExistingLandingDeorbitNode')
    assert 'cmd/deorbitretry' in resume and 'landlight apply' not in resume
    assert 'landingDeorbitNodeAccepted(nd,' in resume
    assert 'REBOOT.' not in mask(entry) and 'missionOverrideUpdate(' not in entry
    print('PASS: explicit unflown deorbit retry preserves fixed target/return/overrides byte-for-byte, removes only the next node and its vessel burn alarm, guards interruption/throttle/orbit changes and never flies or reboots')


def check_resume_and_cpu():
    nodes = without_print(ks.parse(function_body(LANDING,'_resumeExistingLandingDeorbitNode').replace('landingDeorbitNodeReady@','fixtureAdmission')))
    for status,started,skip,allowed in (('ORBITING',False,0,False),('ORBITING',False,0,True),
                                       ('SUB_ORBITAL',False,0,False),('ORBITING',True,0,False),
                                       ('ORBITING',False,1,False)):
        calls = []
        env = dict(fixtureAdmission=NS(CALL=lambda *args:allowed),
                   HASNODE=True,NEXTNODE=NS(DELTAV=NS(MAG=15),ETA=500),
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
    for prior,success,refined in ((150,True,False),(150,False,False),(2000,True,False),(150,True,True)):
        events,config = [],NS(IPU=prior)
        env = dict(CONFIG=config,LANDING_MIN_IPU=2000,LANDING_REQUIRE_SITE=0,LANDING_SITE_SCAN_ENABLE=int(refined),
                   LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),
                   _landingTargetPassUT=4607,
                   landingResolveTarget=lambda: dict(FOUND=True,LAT=19,LNG=129),
                   selectScanSatLandingSite=lambda *args: dict(FOUND=refined,LAT=19.2,LNG=129.1,SLOPE=2,DIST=400),
                   _landingWriteTargetOverrides=lambda: events.append(('persist',)),
                   stateSet=lambda *args: events.append(('save',args)),
                   stateRemove=lambda *args: events.append(('remove',args)),
                   targetedDeorbitAt=lambda *args: events.append(('plan',config.IPU,args[5])) or success)
        try: ks.run(nodes,env)
        except ks.Returned as result: assert result.value is success
        assert config.IPU == prior and ('plan',2000,4607) in events
        assert (('persist',) in events) == refined
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
                   _readGeometricDeorbitNode=lambda *args: Lex(VALID=True,HAS_IMPACT=True))
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
    assert 'landingDeorbitNodeAccepted(realNode,targetLat,targetLng)' in planner
    assert '_targetDeorbitTerrainAccepted(nd:TIME, targetLat, targetLng)' in retained
    print('PASS: new and retained unflown nodes share the original terrain window/clearance guard; pre-target collisions reject, intentional post-target contact remains allowed')


def planner_prefix(env, period=1000, target_pass=0,target_lat=19,target_lng=129):
    """Run real search ordering/admission, stopping before final node creation."""
    env.update(targetLat=target_lat,targetLng=target_lng,overrideTolerance=0,overrideOvershoot=0,
               refineSite=False,targetPassUT=target_pass,ADDONS=NS(TR=NS(AVAILABLE=True,ISVERTWOTWO=True,
                   SETTARGET=lambda _:None)),targetReachable=lambda _:True,
               LATLNG=lambda lat,lng:None,HUDTEXT=lambda *args:None,CYAN='cyan',
               CONFIG=NS(IPU=2000),TARGET_TOLERANCE=1500,TARGET_DEORBIT_MIN_LEAD=120,
               TARGET_DEORBIT_SCAN_ORBITS=8,TARGET_DEORBIT_SCAN_SAMPLES=512,
               TARGET_DEORBIT_SCAN_CENTER_MINUTES=0,TARGET_DEORBIT_SCAN_WINDOW_MINUTES=0,
               LANDING_SIM_MODE=0,HASNODE=False)
    env['SHIP'].ORBIT=NS(PERIOD=period,ECCENTRICITY=0,HASNEXTPATCH=False)
    source=function_body(SOURCE,'targetedDeorbitAt').split('LOCAL bestUT IS geometry["UT"].',1)[0]
    source=source.replace('IF refineSite AND DEFINED BOOT_LIB_RAN AND BOOT_LIB_RAN:CONTAINS("landing_site") {',
                          'IF refineSite {')
    source=source.replace('SET _deorbitEvaluations TO 0.','fixture_reset().')
    source=source.replace('SET _deorbitEvaluations TO _deorbitEvaluations+1.','fixture_charge_forecast().')
    source=source.replace('REMOVE NEXTNODE.','fixture_remove().')
    source=source.replace('REMOVE probeNode.','fixture_remove_probe(probeNode).')
    return run(source,env)


def search_fixture(reachable_window=None):
    env,count,_=environment(lambda *args:None)
    calls=[]
    env['fixture_reset']=lambda:setattr(count,'value',0)
    def geometry(lat,lng,start,end,step,angle):
        return Lex(VALID=True,UT=start+200,ANGLE=angle,LAT=19,LNG=129)
    def solve_at(ut,*args):
        window=int(ut/1000)
        calls.append(window)
        # A bounded synthetic footprint response isolates search ordering;
        # the numerical source solver has independent conic fixtures.
        left=64-count.value
        count.value+=min(6,left)
        if left<6:return Lex(VALID=False,HAS_IMPACT=False)
        cross=100 if window==reachable_window else 600+abs(window-4)*200
        return impact(ut,15,3,0,cross)
    env.update(_findDeorbitGeometryNode=geometry,_solveGeometricDeorbitDv=solve_at,
               _targetDeorbitLightAccepted=lambda *args:True)
    return env,count,calls


def check_pass_first_order():
    env,count,calls=search_fixture(reachable_window=2)
    planner_prefix(env)
    assert env['acceptedSolution'] and calls==[0,1,2] and count.value==18
    assert env['windowsTried']==3 and env['candidatesTried']==3
    # Old five-angles-per-pass order exhausts this same 64-call budget
    # before completing a third-window candidate, where the valid footprint lives.
    old=[index for index in range(8) for _ in range(5)][:64//6]
    assert 2 not in old
    print('PASS: actual planner validates a third-window candidate in 18 trials; the former per-window angle order cannot complete it within 64; acceptance gates remain active')


def check_failure_candidate_summary():
    env,count,calls=search_fixture()
    assert planner_prefix(env) is False
    assert count.value==64 and env['windowsTried']==8
    assert env['closestWindow']==5 and env['closestRejected']['CROSS']==600
    assert env['closestLight']=='not-checked' and not env['acceptedSolution']
    assert env['_targetDeorbitRejection'](env['closestRejected'],10000,20000)=='cross-track'
    summary=SOURCE.split('STATS deorbit best-rejected window=',1)[1].split('} ELSE {',1)[0]
    for key in ('geometryReason=','light=','retro=','normal=','downfieldKm=',
                'crossKm=','crossCapKm=','fpa=','PeKm=','burnUT='):
        assert key in summary
    print('PASS: a failed actual search keeps the nearest rejected footprint through later worse trials, reports its real window/reason/limits and stops at 64 without approval')


def check_mun_normal_authority():
    cfg=read_settings((ROOT/'missions/RO9/mun_landing_return.ks').read_text(),{})
    assert cfg['TARGET_DEORBIT_NORMAL_DV_CAP']==10
    assert cfg['TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM']==.25
    assert cfg['DEORBIT_CROSSTRACK_AUTHORITY_KM']==2
    assert cfg['TARGET_LAT']==44.593 and cfg['TARGET_LNG']==-24.926 and cfg['TARGET_LOCK']==1
    assert cfg['TARGET_TOLERANCE']==1500
    widened,_,_=environment(lambda *args:None)
    widened['DEORBIT_CROSSTRACK_AUTHORITY_KM']=cfg['DEORBIT_CROSSTRACK_AUTHORITY_KM']
    widened['_targetDeorbitCrossAuthority']=lambda solved:ks.call('_targetDeorbitCrossAuthority',widened,solved)
    for cross,allowed in ((1563,True),(2000,True),(2001,False)):
        assert widened['_targetDeorbitSolutionAccepted'](impact(1000,32.43,-10,0,cross),10000,20000) is allowed
    for mirror in (-1,1):
        oracle=kepler_oracle(true_normal=8.5,mirror=mirror,mun=True)
        no_normal,_,_=environment(oracle,cap=0)
        base=oracle(1000,16,0)
        assert not no_normal['_targetDeorbitSolutionAccepted'](solve(no_normal,base),10000,20000)
        env,count,_=environment(oracle,cap=cfg['TARGET_DEORBIT_NORMAL_DV_CAP'])
        result=solve(env,base)
        assert env['_targetDeorbitRefineDone'](result,10000,20000),result
        assert .1<abs(result['NORMAL'])<=10 and count.value<=32
    print('PASS: synthetic 15km polar Mun footprints need lateral authority and solve within the 10m/s normal cap for both signs; fixed site unchanged and allowed cross-track tightens to 500m')


def check_reported_preference_budget():
    outcomes=[]
    for scenario in ('old-preference','powered','cross-cap','normal-cap','fuel','radio','model-fails'):
        # Native boot023 found this admissible coarse seed, then spent64/64
        # looking for250m and ran ZERO powered checks. The response below is
        # a synthetic measured Jacobian, not a replay of native trajectories.
        def oracle(ut,retro,normal):
            along=13235+(31.78-retro)*1000+(ut-357)*100
            cross=368+(normal+6.26)*300+(ut-357)*20
            return impact(ut,retro,normal,along-15000,cross)
        env,count,trials=environment(oracle)
        env.update(LANDING_POWERED_LEAD=1,fixture_reset=lambda:setattr(count,'value',0))
        searches=[];costs=[];models=[];nodes=[]
        def geometry(lat,lng,start,end,step,angle):
            return Lex(VALID=True,UT=start+200,ANGLE=angle,LAT=lat,LNG=lng)
        def coarse(ut,*args):
            searches.append(ut);cost=min(20,64-count.value);costs.append(cost);count.value+=cost
            if len(searches)==1:
                seed=impact(ut,31.78,-6.26,-1765,501 if scenario=='cross-cap' else 368)
                if scenario=='normal-cap':seed['NORMAL']=10.1
                return seed
            return impact(ut,33,0,0,1591)
        def plan(ut,retro,normal):
            node=NS(TIME=ut,retro=retro,normal=normal);nodes.append(node);return node
        def read(node,lat,lng,aim):
            result=oracle(node.TIME,node.retro,node.normal);result['ERR']=result['DOWNFIELD']-aim
            return result
        evaluate=env['_evalGeometricDeorbitNode']
        def measured(ut,retro,lat,lng,lead,aim,normal=0):
            result=evaluate(ut,retro,lat,lng,lead,aim,normal)
            if result['VALID']:result['ERR']=result['DOWNFIELD']-aim
            return result
        def policy(node,lat,lng):
            models.append((node.TIME,node.retro,node.normal))
            return Lex(VALID=scenario!='model-fails',REASON='fixture-model-rejected',
                        AIM=35000,MIN=33500,MAX=36500)
        env.update(_findDeorbitGeometryNode=geometry,_solveGeometricDeorbitDv=coarse,
                   _evalGeometricDeorbitNode=measured,_planRetroNode=plan,
                   _readGeometricDeorbitNode=read,landingDeorbitLeadPolicy=policy,
                   _targetDeorbitLightAccepted=lambda *args:scenario!='radio',
                   fixture_remove_probe=lambda node:nodes.remove(node))
        if scenario=='fuel':env['SHIP'].DELTAV.VACUUM=20
        if scenario=='old-preference':
            env['_targetDeorbitRefineDone']=lambda solved,lo,hi:env['_targetDeorbitSolutionAccepted'](solved,lo,hi) and solved['CROSS']<=250
        # Exercise the complete search AND powered refinement, stopping before
        # final node creation/execution. Node and counter adapters match the
        # other numerical solver fixtures; all acceptance logic is real code.
        result=planner_prefix(env,target_lat=44.593,target_lng=-24.926)
        assert not nodes and count.value<=64
        assert count.value==sum(costs)+len(trials)+len(models)
        assert env['targetLat']==44.593 and env['targetLng']==-24.926
        if scenario=='powered':
            assert result is None and env['poweredAccepted'] and len(searches)==1
            assert env['searchStop']=='powered-seed' and len(models)>1
            assert 33500<=env['solved']['DOWNFIELD']<=36500
            assert env['solved']['CROSS']<=500 and abs(env['solved']['NORMAL'])<=10
        else:
            assert result is False and not env.get('poweredAccepted',False)
            assert len(models)==(1 if scenario=='model-fails' else 0)
        if scenario=='old-preference':
            assert count.value==64 and env['poweredPass']==0
            assert env['bestAcceptedCross']==368
            assert env['holdReason']=='powered-validation-budget-exhausted'
        outcomes.append((scenario,count.value,len(models)))
    print('PASS: reported368m/250m preference reproduces64/64 and zero forecasts under the old policy; revised full search/Newton/powered flow validates in%d/64 with%d forecasts, preserving target and cross/normal/fuel/radio/model rejection'% (outcomes[1][1],outcomes[1][2]))


def band_normal_oracle(mirror=1,singular=False,range_coupled=False,retro_base=32.33,cross_base=736,normal_base=-5):
    def response(ut,retro,normal):
        delta=retro-retro_base
        normal_delta=mirror*normal-normal_base
        # Smooth nonlinear response: one-m/s retro probe sees zero ridge,
        # while the proposed intermediate retro changes spoil cross-track.
        # This stresses the measured Newton model, not a native TR replay.
        down=12827+(0 if singular else 5000*delta)-(4000*normal_delta if range_coupled else 0)
        cross=cross_base+300*normal_delta+10000*math.sin(math.pi*delta)**2
        return impact(ut,retro,normal,down-15000,cross)
    return response


def check_normal_band_fallback():
    for mirror in (-1,1):
        for singular,range_coupled in ((False,False),(True,False),(False,True)):
            oracle=band_normal_oracle(mirror,singular,range_coupled)
            env,count,trials=environment(oracle)
            env['LANDING_POWERED_LEAD']=1
            base=oracle(1000,32.33,-5*mirror)
            correction=env['_targetDeorbitNormalCorrection']
            env['_targetDeorbitNormalCorrection']=lambda *args:Lex(VALID=False)
            old=solve(env,base)
            assert not env['_targetDeorbitSolutionAccepted'](old,10000,20000)
            count.value=0;trials.clear();env['_targetDeorbitNormalCorrection']=correction
            result=solve(env,base)
            assert env['_targetDeorbitSolutionAccepted'](result,10000,20000),result
            assert result['CROSS']<500 and abs(result['NORMAL'])<=10 and count.value<20
            assert result['UT']==1000 and result['RETRO']==32.33
            assert all(abs(row['NORMAL'])<=10 and 2<=row['RETRO']<=120 for row in trials)
            if range_coupled:assert any(row['DOWNFIELD']>20000 for row in trials)
    # Bounds still win when the remaining normal/fuel/trial authority is
    # genuinely inadequate. Reserve the last forecast slot without guessing.
    oracle=band_normal_oracle()
    for cap,budget,reserve,used in ((5.5,64,0,0),(10,7,0,0),(10,64,1,56)):
        env,count,trials=environment(oracle,cap=cap,budget=budget)
        env['LANDING_POWERED_LEAD']=1;count.value=used
        base=oracle(1000,32.33,-5)
        result=env['_refineDeorbitFootprint'](base,19,129,120,15000,10000,20000,2,120,reserve)
        assert count.value<=budget-reserve
        assert not env['_targetDeorbitSolutionAccepted'](result,10000,20000)
        assert all(abs(row['NORMAL'])<=cap for row in trials)
    print('PASS: stalled736m banded footprint and singular Jacobian recover via measured normal-only steps for both signs; bad range roots backtrack, while normal/trial caps and reserved validation slot still hold')


def check_normal_probe_guards():
    env,_,_=environment(lambda *args:None)
    best=impact(1000,32.33,-5,-2173,736)
    for scenario in ('ok','out-of-band','no-impact','invalid','zero-step','flat','nan','nan-base','nan-range'):
        base=dict(best);probe=dict(best);probe['SIGNED_CROSS']=1036;delta=1
        if scenario=='out-of-band':base['DOWNFIELD']=9999
        if scenario=='no-impact':probe['HAS_IMPACT']=False
        if scenario=='invalid':probe['VALID']=False
        if scenario=='zero-step':delta=0
        if scenario=='flat':probe['SIGNED_CROSS']=base['SIGNED_CROSS']
        if scenario=='nan':probe['SIGNED_CROSS']=float('nan')
        if scenario=='nan-base':base['SIGNED_CROSS']=float('nan')
        if scenario=='nan-range':base['DOWNFIELD']=float('nan')
        result=env['_targetDeorbitNormalCorrection'](base,probe,delta,10000,20000)
        assert result['VALID']==(scenario=='ok'),scenario
        if scenario=='ok':assert result['RETRO']==0 and -2.46<result['OTHER']<-2.45
    print('PASS: normal-only fallback needs valid impacts, an already-admissible downfield band and a finite measured slope; zero/flat/NaN responses cannot produce a node request')


def check_normal_fallback_search_budget():
    results=[]
    for legacy in (True,False):
        oracle=band_normal_oracle(retro_base=15,cross_base=2236,normal_base=0)
        env,count,trials=environment(oracle)
        env.update(LANDING_POWERED_LEAD=1,fixture_reset=lambda:setattr(count,'value',0))
        models=[];nodes=[]
        env['_findDeorbitGeometryNode']=lambda lat,lng,start,end,*args:Lex(VALID=True,UT=start+200,ANGLE=50,LAT=lat,LNG=lng)
        env['_targetDeorbitLightAccepted']=lambda *args:True
        def plan(ut,retro,normal):
            node=NS(TIME=ut,retro=retro,normal=normal);nodes.append(node);return node
        env['_planRetroNode']=plan
        env['fixture_remove_probe']=lambda node:nodes.remove(node)
        env['_readGeometricDeorbitNode']=lambda node,*args:oracle(node.TIME,node.retro,node.normal)
        def policy(*args):
            models.append(1)
            return Lex(VALID=True,AIM=15000,MIN=10000,MAX=20000)
        env['landingDeorbitLeadPolicy']=policy
        if legacy:env['_targetDeorbitNormalCorrection']=lambda *args:Lex(VALID=False)
        result=planner_prefix(env,target_lat=44.593,target_lng=-24.926)
        assert not nodes and count.value<=64 and count.value==len(trials)+len(models)
        if legacy:assert result is False and not models and count.value==64
        else:
            assert result is None and env['poweredAccepted'] and env['windowsTried']==1
            assert env['solved']['CROSS']<=500 and len(models)==1
            assert count.value<30 and abs(env['solved']['NORMAL'])<=10
        results.append(count.value)
    print('PASS: actual full search/inner solver/powered validation avoids64-trial abandonment and finishes in%d/64 with first-pass normal recovery; fixed target and all hard admission gates remain'%(results[1]))


def check_preburn_refit():
    ready=function_body(SOURCE,'landingDeorbitNodeReady')
    admission=function_body(SOURCE,'landingDeorbitNodeAccepted')
    cases=('changed','already-ok','cross','normal','fuel','terrain','light','invalid',
           'flat','nan','wrong-slope','unreachable','deadline','late-model',
           'abort','removed','suborbital','committed','thrust','main','pilot','radial','body-change')
    for case in cases:
        env,_,_=environment(lambda *args:None)
        node=NS(TIME=300.,ETA=300.,PROGRADE=-14.59,NORMAL=-7.7,RADIALOUT=0.,DELTAV=NS(MAG=16.5))
        body=NS(NAME='Mun');seen=[]
        env.update(nd=node,targetLat=44.593,targetLng=-24.926,HASNODE=True,LANDING_POWERED_LEAD=1,
                   SHIP=NS(BODY=body,STATUS='ORBITING',PERIAPSIS=14500,THRUST=0.,
                           CONTROL=NS(MAINTHROTTLE=0.,PILOTMAINTHROTTLE=0.),DELTAV=NS(VACUUM=1000)),
                   stateGet=lambda *args:'true' if case=='committed' else 'false',
                   _targetDeorbitTerrainAccepted=lambda *args:case!='terrain',
                   landingLightNodeAllowed=lambda *args:case!='light')
        def policy(nd,lat,lng):
            seen.append(nd.PROGRADE)
            env['TIME'].SECONDS+=100 if case=='late-model' else 10
            if len(seen)>1 and case=='abort':env['ABORT']=True
            if len(seen)>1 and case=='removed':env['HASNODE']=False
            if len(seen)>1 and case=='body-change':env['SHIP'].BODY=NS(NAME='Kerbin')
            return Lex(VALID=case!='invalid',REASON='unsupported',AIM=126363.,MIN=124863.,MAX=127863.)
        def geometry(nd,lat,lng,aim):
            retro=-nd.PROGRADE
            error=-8149+(-1200)*(retro-14.59)
            if case=='already-ok':error=0
            if case in ('terrain','light'):error=0 if len(seen)>1 else error
            if case=='flat':error=-8149
            if case=='nan':error=float('nan') if len(seen)>1 else error
            if case=='wrong-slope':error=-8149+1200*(retro-14.59)
            if case=='unreachable':error=-8149+10*(retro-14.59)
            result=impact(nd.TIME,retro,nd.NORMAL,error,220)
            result.update(DOWNFIELD=aim+error,ERR=error,DV=16.5)
            if case=='cross':result['CROSS']=900
            if case=='normal':result['NORMAL']=11
            if case=='fuel':result['DV']=2000
            return result
        env.update(landingDeorbitLeadPolicy=policy,_readGeometricDeorbitNode=geometry)
        def actual_admission(nd,lat,lng):
            scope=dict(env,nd=nd,targetLat=lat,targetLng=lng)
            result=run(admission,scope)
            env['_deorbitLastCheck']=scope['_deorbitLastCheck']
            return result
        env['landingDeorbitNodeAccepted']=actual_admission
        if case=='deadline':env['TIME'].SECONDS=200
        if case=='suborbital':env['SHIP'].STATUS='SUB_ORBITAL'
        if case=='thrust':env['SHIP'].THRUST=.1
        if case=='main':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if case=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if case=='radial':node.RADIALOUT=1
        result=run(ready,env)
        expected=case in ('changed','already-ok','wrong-slope')
        assert result is expected,(case,result,seen)
        assert len(seen)<=7 and all(2<=-p<=120 and abs(p+14.59)<=10 for p in seen),(case,seen)
        assert node.TIME==300 and node.NORMAL==-7.7 and node.RADIALOUT==(1 if case=='radial' else 0)
        if not expected and env['HASNODE']:assert node.PROGRADE==-14.59,(case,node)
        if case=='changed':assert abs(geometry(node,44.593,-24.926,126363)['ERR'])<=1500
        if case=='already-ok':assert len(seen)==1 and node.PROGRADE==-14.59
    print('PASS: actual pre-burn admission/refit recovers the reported8.15km moving-forecast miss at the same epoch/normal/target; both slope signs work; <=7 forecasts, fuel/cross/normal/terrain/light/deadline/abort/interruption guards and exact original-node restoration remain')


def check_retro_only_fallback():
    for sign in (-1,1):
        outcomes=[]
        for enabled in (False,True):
            def response(ut,retro,normal):
                down=54283-12500.2*(retro-22.3587)+504.7*(ut-1000)-156.38*(normal-sign*10)
                lateral=-sign*1458+324.387*(normal-sign*10)+25*(retro-22.3587)+9.4*(ut-1000)
                result=impact(ut,retro,normal,down-68772,lateral,abs(ut-1000)<=5.001)
                result['DOWNFIELD']=down
                return result
            env,count,trials=environment(response)
            env.update(LANDING_POWERED_LEAD=1,_targetDeorbitCrossAuthority=lambda _:2000)
            if not enabled:env['_targetDeorbitRetroCorrection']=lambda *args:Lex(VALID=False)
            base=response(1000,22.3587,sign*10)
            result=env['_refineDeorbitFootprint'](base,44.593,-24.926,120,68772,67272,70272,2,120,1,1)
            outcomes.append(result)
            if enabled:
                assert env['_targetDeorbitSolutionAccepted'](result,67272,70272),result
                assert result['UT']==1000 and result['NORMAL']==sign*10 and result['CROSS']<=2000
                assert abs(result['RETRO']-base['RETRO'])<2 and count.value<=63
            else:assert result==base and not env['_targetDeorbitSolutionAccepted'](result,67272,70272)
        assert outcomes[1]['DOWNFIELD']>outcomes[0]['DOWNFIELD']
    env,_,_=environment(lambda *args:None);env['LANDING_POWERED_LEAD']=1
    base=impact(1000,22,-10,-14489,1458);probe=impact(1000,23,-10,-26989,1460)
    env['_targetDeorbitCrossAuthority']=lambda _:2000
    for fault in ('cross','flat','nan','in-band','invalid','no-impact','zero-probe','legacy'):
        best=dict(base);other=dict(probe);dv=1.;env['LANDING_POWERED_LEAD']=1
        if fault=='cross':best['CROSS']=2001
        if fault=='flat':other['ERR']=best['ERR']
        if fault=='nan':other['ERR']=float('nan')
        if fault=='in-band':best.update(DOWNFIELD=15000,ERR=0)
        if fault=='invalid':other['VALID']=False
        if fault=='no-impact':best['HAS_IMPACT']=False
        if fault=='zero-probe':dv=0
        if fault=='legacy':env['LANDING_POWERED_LEAD']=0
        assert not env['_targetDeorbitRetroCorrection'](best,other,dv,10000,20000)['VALID'],fault
    print('PASS: coupled timing steps fail and normal is capped in a reported54.3->68.8km/1458m synthetic footprint; retro-only fallback recovers both normal signs without changing epoch/normal/hard cross bounds, reserves validation and rejects invalid/flat/NaN/unacceptable cross inputs')


if __name__ == '__main__':
    check_physical_solver()
    check_selected_pass()
    check_progress_and_failure()
    check_geometry_before_light()
    check_explicit_deorbit_retry()
    check_resume_and_cpu()
    check_actual_trial_budget()
    check_shared_terrain()
    check_pass_first_order()
    check_failure_candidate_summary()
    check_mun_normal_authority()
    check_reported_preference_budget()
    check_normal_band_fallback()
    check_normal_probe_guards()
    check_normal_fallback_search_budget()
    check_preburn_refit()
    check_retro_only_fallback()
