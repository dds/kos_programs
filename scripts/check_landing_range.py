"""Coupled powered-range/native-conic fixtures; no KSP/kOS flight runner.

The nominal model assumes approximately steady descent. These checks bound
its error against the actual controller in stated point-mass cases; they do
not certify whole-landing fuel, arbitrary terrain or native execution timing.
"""
import math
from types import SimpleNamespace as NS
import re

import check_deorbit_solver as solver
from check_landing_braking import fixture,call,Vec
from check_codebase import ROOT,function_body
from check_runtime_contracts import run

LEAD=(ROOT/'lib/landing_deorbit_lead.ks').read_text()


def check_reported_ignition():
    env,ctx=fixture(gravity=1.6284599,twr=44.68/1.6284599,
                    horizontal=516.1,down=44.9,height=6101)
    env.update(LANDING_STAGE_BRAKE_CREDIT=1,LANDING_ECONOMY_BRAKE=1)
    ctx.update(PLAN_ACC=2.72,BRAKE_STAGE_DV=223.9,downrange=43000)
    env['SHIP'].BODY=NS(RADIUS=200000)
    env['SHIP'].ALTITUDE=10212
    old=call('_landingBrakeGateInfo',env,ctx)
    assert old['H_NOW'] and not old['V_NOW'] and 42000<old['H_GATE']<44000
    env['LANDING_POWERED_LEAD']=1
    new=call('_landingBrakeGateInfo',env,ctx)
    assert not new['H_NOW'] and not new['V_NOW'] and 20000<new['H_GATE']<21000
    for key in ('V_GATE','V_ETA','V_NOW'):assert old[key]==new[key]
    call('_landingCoastTick',env,ctx)
    assert ctx['STATE']=='BRAKE_ALIGN' and ctx['throttle']==0
    # Being inside the alignment lead permits attitude preparation, not burn.
    env['SHIP'].FACING.FOREVECTOR=ctx['steering']
    call('_landingBrakeAlignTick',env,ctx)
    assert ctx['STATE']=='BRAKE_ALIGN' and ctx['throttle']==0
    ctx['height']=new['V_GATE']-1
    assert call('_landingBrakeGateInfo',env,ctx)['V_NOW']
    ctx.update(H_SPEED=286.7,H_VEL=Vec((286.7,0,0)),MAX_ACC=2.72,
               BRAKE_STAGE_DV=0,downrange=39974)
    miss=call('_landingBrakeGateInfo',env,ctx)['RANGE_ERROR']
    assert -23000<miss<-22000
    print('PASS: supplied 516/-44.9/223.9 state replaces the 43km geographic gate with ~20.2km nominal range, preserves every vertical safety value and alignment guard; post-stage 40km target remains far beyond nominal capture')


def check_range_physics():
    env,_=fixture()
    for grav,active,weak,hs,fuel in ((1.63,44.68,2.72,516,224),(.491,8,2.5,180,80),
                                    (1.63,2.72,2.72,287,0),(1.63,44,2.72,100,1000)):
        estimated=call('lmNominalBrakeRange',env,hs,active,weak,fuel,grav,3)
        # Independent impulse integration: gravity support plus full lateral
        # thrust. Split precisely at fuel exhaustion and the capture speed.
        speed=hs;distance=hs*3;budget=fuel
        dt=.01
        while speed>18+1e-8:
            acc=active if active>weak and budget>1e-9 else weak
            lateral=math.sqrt(acc**2-grav**2)
            step=min(dt,(speed-18)/lateral)
            if acc==active and active>weak:step=min(step,budget/acc)
            distance+=speed*step-lateral*step**2/2
            speed-=lateral*step
            if acc==active and active>weak:
                budget-=acc*step
                if budget<=1e-9 and speed>18:distance+=speed*3
        assert abs(estimated-distance)<1e-5,(estimated,distance)
    for active,weak in ((0,0),(2,1.63),(1.63,2.72)):
        assert call('lmNominalBrakeRange',env,300,active,weak,200,1.63,3)<0
    assert call('lmNominalBrakeRange',env,0,3,3,0,1.63,3)==0
    print('PASS: staged nominal range agrees with independent full-thrust gravity-support integration; finite fuel/staging gaps/capture speed retained and underpowered/inverted acceleration inputs rejected')


def control_distance(hs,vs,height,budget,active=44.68,weak=2.72,
                     initial_delay=3,stage_delay=3):
    env,ctx=fixture(gravity=1.6284599,twr=active/1.6284599,
                    horizontal=hs,down=-vs,height=height)
    distance=0.;dt=.4;pause=initial_delay;now=0.
    while now<600 and ctx['H_SPEED']>18:
        acc=active if budget>1e-6 else weak
        radius=200000+4113+height
        grav=max(.01,1.6284599*(200000/radius)**2-ctx['H_SPEED']**2/radius)
        target_vs=call('lmBrakeDescentTarget',env,ctx['H_SPEED'],max(0,-vs),height,
                       acc,weak,1.6284599,3,grav)
        thrust=call('lmEconomyBrakeThrust',env,ctx['H_VEL'],vs,target_vs,ctx['UP_VEC'],acc,grav)
        if now<pause:thrust=thrust*0
        elif budget>1e-6:
            thrust=thrust*min(1,budget/max(thrust.MAG*dt,1e-20))
            budget-=thrust.MAG*dt
            if budget<=1e-6:pause=now+stage_delay
        old_h=ctx['H_SPEED'];vel=Vec((old_h,0,vs))+(thrust-Vec((0,0,grav)))*dt
        ctx.update(H_SPEED=max(0,vel[0]),H_VEL=Vec((max(0,vel[0]),0,0)))
        vs=vel[2];height+=vs*dt;distance+=(old_h+ctx['H_SPEED'])*dt/2;now+=dt
        assert height>0
    assert now<600
    return distance


def check_controller_range():
    # Two actual supplied velocity states; altitude at the later row was not
    # supplied, so 5km is an explicit illustrative assumption, not telemetry.
    for hs,vs,height,fuel in ((516.1,-44.9,6101,223.9),(286.7,-32.3,5000,0)):
        env,_=fixture()
        estimate=call('lmNominalBrakeRange',env,hs,44.68 if fuel else 2.72,
                      2.72,fuel,1.6284599,3,200000,height+4113)
        physical=control_distance(hs,vs,height,fuel)
        assert abs(physical-estimate)<700,(physical,estimate)
    print('PASS: nominal range is within 700m of actual descending-controller capture in the reported ignition case and an explicitly assumed 5km post-stage case; far smaller than the old ~20km geographic error, not a flight accuracy guarantee')


def check_nominal_timing():
    env,_=fixture()
    for hs,vs,height,fuel in ((516.1,-44.9,6101,223.9),(286.7,-32.3,5000,0)):
        active=44.68 if fuel else 2.72
        old=call('lmNominalBrakeRange',env,hs,active,2.72,fuel,1.6284599,3,200000,height+4113)
        revised=call('lmNominalBrakeRange',env,hs,active,2.72,fuel,1.6284599,0,
                      200000,height+4113,2*env['LANDING_STAGE_SETTLE'])
        physical=control_distance(hs,vs,height,fuel,initial_delay=.05,
                                   stage_delay=2*env['LANDING_STAGE_SETTLE'])
        assert abs(revised-physical)<700 and abs(revised-physical)<abs(old-physical)/2
        if fuel:assert old-physical>2000
    main=(ROOT/'lib/landing_main.ks').read_text()
    assert 'LOCAL tickRate IS 0.33.' in main and 'SET tickRate TO 0.05.' in main
    hardware=(ROOT/'lib/vessel_hardware.ks').read_text()
    assert 'GLOBAL LANDING_STAGE_SETTLE IS 0.25.' in hardware
    for path in ('landing_main','landing_divert'):
        text=(ROOT/f'lib/{path}.ks').read_text()
        callsite=text[text.index('lmNominalBrakeRange('):]
        callsite=callsite[:callsite.index(').')]
        assert '2*MAX(0.05,LANDING_STAGE_SETTLE)' in callsite
        assert 'BRAKE_REACTION_TIME' not in callsite
    print('PASS: source-aligned .05s actuation/.5s staging fixture exposes >2km bias hidden by forced 3s pauses; nominal geographic prediction improves without changing the V deadline, and all three production callers share actual settle timing')


def lead_environment():
    env,_=fixture()
    mu,radius,apo=6.5138398e10,200000.,215000.
    speed=math.sqrt(mu/apo)-20
    semi=1/(2/apo-speed**2/mu);ecc=apo/semi-1;rate=math.sqrt(mu/semi**3)
    impact_e=2*math.pi-math.acos((1-radius/semi)/ecc)
    coast=(impact_e-ecc*math.sin(impact_e)-math.pi)/rate
    nd=NS(TIME=1000.,DELTAV=NS(MAG=20.))
    def position(ut):
        mean=math.pi+rate*(ut-nd.TIME)
        anomaly=mean
        for _ in range(12):anomaly-=(anomaly-ecc*math.sin(anomaly)-mean)/(1-ecc*math.cos(anomaly))
        return Vec((-semi*math.sqrt(1-ecc**2)*math.sin(anomaly),0,-semi*(math.cos(anomaly)-ecc)))
    def geo(lat,lng):
        theta=math.radians(lng);latitude=math.radians(lat)
        return NS(LAT=lat,LNG=lng,TERRAINHEIGHT=0,
                  ALTITUDEPOSITION=lambda alt:Vec((math.cos(latitude)*math.sin(theta)*(radius+alt),math.sin(latitude)*(radius+alt),math.cos(latitude)*math.cos(theta)*(radius+alt))))
    def geo_at(ut):
        pos=position(ut)
        return geo(0,math.degrees(math.atan2(pos[0],pos[2])))
    impact_ut=nd.TIME+coast
    env.update(SHIP=NS(MASS=1.,ALTITUDE=15000.,BODY=NS(RADIUS=radius,MU=mu,POSITION=Vec((0,0,0)),ATM=NS(EXISTS=False)),
                       BOUNDS=NS(BOTTOMALTRADAR=15000,EXTENTS=Vec((0,0,0)),ABSCENTER=Vec((0,0,0))),
                       POSITION=Vec((0,0,0))),ALT=NS(RADAR=15000),
               ADDONS=NS(TR=NS(HASIMPACT=True,TIMETILLIMPACT=impact_ut,IMPACTPOS=geo_at(impact_ut))),
               LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1,LANDING_STAGE_BRAKE_CREDIT=1,
               TARGET_TOLERANCE=1500,LATLNG=geo,
               vesselLandingThrust=lambda:44.68,vesselLandingReserveAcc=lambda:2.72,
               vesselLandingBrakeStageDv=lambda:244,
               lmGroundPositionAt=position,lmGroundVelocityAt=lambda ut:(position(ut)-position(ut-.5))/.5,
               lmGroundGeoAt=geo_at,
               VDOT=lambda a,b:float(a@b),VCRS=lambda a,b:Vec(__import__('numpy').cross(a,b)),
               ARCCOS=lambda x:math.degrees(math.acos(x)),ARCSIN=lambda x:math.degrees(math.asin(x)),
               ARCTAN2=lambda a,b:math.degrees(math.atan2(a,b)))
    from check_landing_prediction import SOURCE as prediction_source
    from check_runtime_contracts import KList
    env['CONSTANT']=NS(E=math.e,PI=math.pi)
    env['LN']=math.log
    env['LIST']=lambda *args:KList(args)
    env['SHIP'].BODY.ROTATIONPERIOD=1e30
    env['SHIP'].BODY.GEOPOSITIONOF=lambda pos:geo(math.degrees(math.asin(pos[1]/pos.MAG)),math.degrees(math.atan2(pos[0],pos[2])))
    def stack():
        mass=1.;retained=.6;exhaust=320*9.80665
        fuel=mass*(1-math.exp(-244/exhaust))
        return solver.Lex(VALID=True,MASS=mass,STAGE=2,RESERVE_ACC=2.72,
                    STAGES=KList([dict(THRUST=44.68,EXHAUST=exhaust,FUEL=fuel,DROP=mass-retained-fuel),
                                  dict(THRUST=2.72*retained,EXHAUST=300*9.80665,FUEL=.25,DROP=0)]))
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',LEAD+'\n'+prediction_source):
        env[name]=lambda *args,name=name:call(name,env,*args)
    lead_body=function_body(LEAD,'landingDeorbitLeadPolicy')
    lead_body=re.sub(r'LOCAL diagnostic IS .*?capture=true"\.',
                     'LOCAL diagnostic IS "fixture diagnostic".',lead_body,flags=re.S)
    env['landingDeorbitLeadPolicy']=lambda nd,lat,lng,legacy=15000:run(lead_body,
        dict(env,nd=nd,targetLat=lat,targetLng=lng,legacyAim=legacy))
    env['LEXICON']=lambda *xs:solver.Lex(zip(xs[::2],xs[1::2]))
    env['landingBrakeStack']=stack
    env['LANDING_FLEXIBLE_SITE']=1
    env['lmSurfaceTrackOffset']=lambda *args:call('lmSurfaceTrackOffset',env,*args)
    return env,nd,impact_ut


def check_native_lead():
    env,nd,impact_ut=lead_environment()
    ship=env['SHIP'];reads=[]
    class CountedShip:
        def __getattr__(self,name):
            if name=='BOUNDS':reads.append(name)
            return getattr(ship,name)
    env['SHIP']=CountedShip()
    policy=env['landingDeorbitLeadPolicy'](nd,0,0)
    env['SHIP']=ship
    assert len(reads)==1,reads
    assert policy['VALID'],policy
    assert nd.TIME<policy['IGNITION_UT']<impact_ut
    assert 10000<policy['RANGE']<50000 and policy['AIM']>20000,policy
    assert abs(policy['AIM']+policy['RANGE']-policy['BALLISTIC'])<1e-8
    assert policy['MIN']==policy['AIM']-1500 and policy['MAX']==policy['AIM']+1500
    # The exact same physical post-deorbit stack must yield the same result
    # when supplied as a now-flown (zero-node-dV) trajectory. Charge once.
    full_fuel=env['vesselLandingBrakeStageDv']
    original_stack=env['landingBrakeStack']
    charged=env['landingBrakeStackAt'](original_stack(),1.,20.)
    env['landingBrakeStack']=lambda:charged
    env['SHIP'].MASS=charged['MASS']
    env['vesselLandingBrakeStageDv']=lambda:full_fuel()-20
    nd.DELTAV.MAG=0
    env['ALT'].RADAR+=2299.01 # Unrelated current radar/terrain change during coast.
    assert env['landingDeorbitLeadPolicy'](nd,0,0)==policy
    env['ALT'].RADAR-=2299.01
    # More measured transfer fuel may help, but cannot come from return tanks.
    env['SHIP'].MASS=1.;nd.DELTAV.MAG=20.
    env['vesselLandingBrakeStageDv']=lambda:full_fuel()+20
    def fuller_stack():
        result=original_stack();result['STAGES'][0]['FUEL']+=.01;result['STAGES'][0]['DROP']-=.01
        return result
    env['landingBrakeStack']=fuller_stack
    extra=env['landingDeorbitLeadPolicy'](nd,0,0)
    assert extra['VALID'] and extra['RANGE']<policy['RANGE'] and extra['IGNITION_UT']>policy['IGNITION_UT']
    env['LANDING_POWERED_LEAD']=0
    legacy=env['landingDeorbitLeadPolicy'](nd,0,0)
    assert legacy['AIM']==15000 and legacy['MIN']==10000 and legacy['MAX']==20000
    print('PASS: real source policy samples a post-node Kepler conic, finds a finite ignition before impact, derives >20km lead from ballistic minus powered travel, subtracts deorbit fuel first and preserves legacy policy on opt-out')


def check_lead_refusals():
    for kind in ('bounds','mode','credit','atmosphere','impact','underpowered','unknown-fuel','spent-fuel','timing','abort','no-coast','range','upfield'):
        env,nd,impact_ut=lead_environment()
        if kind=='bounds':env['SHIP'].BOUNDS.EXTENTS=Vec((float('nan'),0,0))
        if kind=='mode':env['LANDING_ECONOMY_BRAKE']=0
        if kind=='credit':env['LANDING_STAGE_BRAKE_CREDIT']=0
        if kind=='atmosphere':env['SHIP'].BODY.ATM.EXISTS=True
        if kind=='impact':env['ADDONS'].TR.HASIMPACT=False
        if kind=='underpowered':env['vesselLandingReserveAcc']=lambda:1
        if kind=='unknown-fuel':env['vesselLandingBrakeStageDv']=lambda:0
        if kind=='spent-fuel':env['vesselLandingBrakeStageDv']=lambda:19
        if kind=='timing':nd.TIME=impact_ut
        if kind=='abort':env['ABORT']=True
        if kind=='no-coast':env['_landingLeadStateAt']=lambda *args:dict(HS=500,DOWN=80,HEIGHT=1)
        if kind=='range':env['landingPredictBrake']=lambda *args:solver.Lex(VALID=False,REASON='test-range-failure')
        if kind=='upfield':env['lmSurfaceTrackOffset']=lambda *args:solver.Lex(VALID=True,DOWNFIELD=-1)
        result=env['landingDeorbitLeadPolicy'](nd,0,0)
        assert not result['VALID'],(kind,result)
    print('PASS: unsupported models, insufficient/unknown transfer fuel, underpowered stages, missing/late impacts, absent coast, abort and invalid/upfield ranges cannot authorize a deorbit')


def powered_source():
    source=function_body(solver.SOURCE,'targetedDeorbitAt')
    source=source[source.index('LOCAL poweredPass IS'):source.index('LOCAL bestUT IS')]
    return source.replace('REMOVE probeNode.','remove_probe(probeNode).')


def check_powered_refinement():
    for kind in ('solve','third-step','secant-fallback','model-fails','no-progress','nonconverging',
                 'spent-trials','validation-reserve','no-impact'):
        env,_,_=solver.environment(lambda *args:None)
        base=solver.impact(1000,15,0,0,0)
        env['_deorbitEvaluations']=40
        if kind=='spent-trials':env['_deorbitEvaluations']=64
        if kind=='validation-reserve':env['_deorbitEvaluations']=60
        policies=[];nodes=[];refinements=[]
        def policy(*args):
            policies.append(1)
            aim=env['solved']['DOWNFIELD']+10000 if kind=='nonconverging' else 63610
            return solver.Lex(VALID=kind!='model-fails',REASON='fixture',AIM=aim,MIN=aim-1500,MAX=aim+1500)
        def refine(best,lat,lng,lead,aim,lo,hi,min_dv,max_dv,reserve,max_steps):
            assert reserve==1 and max_steps==1 and lo<=aim<=hi
            refinements.append(aim)
            assert env['_deorbitEvaluations']+3<=63
            env['_deorbitEvaluations']+=3
            result=dict(best)
            if kind!='no-progress' and not (kind=='secant-fallback' and len(refinements)==2):
                result['DOWNFIELD']=min(aim,best['DOWNFIELD']+20000) if kind in ('third-step','secant-fallback') else aim
                result['ERR']=result['DOWNFIELD']-aim
                result['RETRO']=max(min_dv,best['RETRO']-1)
            return result
        def read(*args):
            result=dict(env['solved'])
            if kind=='no-impact':result.update(VALID=False,HAS_IMPACT=False)
            return result
        env.update(solved=base,geometry=dict(UT=1000),LANDING_POWERED_LEAD=1,
                   targetLat=0,targetLng=0,minLead=120,minRetroDv=2,maxRetroDv=120,
                   desiredDownfield=15000,minDownfield=10000,maxDownfield=20000,
                   _planRetroNode=lambda *args:nodes.append(1) or object(),
                   _readGeometricDeorbitNode=read,
                   remove_probe=lambda _:nodes.pop(),landingDeorbitLeadPolicy=policy,
                   _refineDeorbitFootprint=refine)
        result=run(powered_source(),env)
        assert not nodes and env['_deorbitEvaluations']<=64
        if kind=='spent-trials':assert not policies
        assert env['poweredAccepted']==(kind in ('solve','third-step','secant-fallback')),(kind,policies,refinements,env['solved'])
        if kind in ('solve','third-step','secant-fallback'):assert env['solved']['DOWNFIELD']==63610
        else:assert result is False
        if kind=='third-step':
            assert len(refinements)==3 and len(policies)==4 and env['_deorbitEvaluations']==53
        if kind=='secant-fallback':
            assert len(refinements)==4 and len(policies)==4 and env['_deorbitEvaluations']==56
        if kind=='no-progress':assert len(policies)==1 and env['poweredStop']=='no-improving-step'
        if kind=='validation-reserve':assert not refinements and len(policies)==1
    print('PASS: powered polish freshly validates the third refinement instead of falsely holding at 53/64; absent impacts, bad models, no progress, drifting targets and exhausted budgets retain orbit, remove all probes and reserve the final validation trial')


def check_coupled_powered_refinement(start=30,contraction=.6):
    # The model changes with the measured footprint, rather than following
    # a requested aim. A contracting moving goal requires more than three
    # passes. Execute the REAL timing/normal Newton refiner inside the outer
    # model loop, charging every footprint probe and forecast to one counter.
    def oracle(ut,retro,normal):
        along=5000*(15-retro)+500*(ut-1000)
        cross=60*(ut-1000)+1000*normal
        return solver.impact(ut,retro,normal,along,cross)
    env,counter,trials=solver.environment(oracle)
    counter.value=start
    base=oracle(1000,15,0)
    nodes=[];forecasts=[]
    evaluate=env['_evalGeometricDeorbitNode']
    def measured(ut,retro,lat,lng,lead,desired,normal=0):
        result=evaluate(ut,retro,lat,lng,lead,desired,normal)
        if result['VALID']:result['ERR']=result['DOWNFIELD']-desired
        return result
    env['_evalGeometricDeorbitNode']=measured
    def plan(ut,retro,normal):
        node=NS(TIME=ut,retro=retro,normal=normal)
        nodes.append(node)
        return node
    def read(node,lat,lng,desired):
        result=oracle(node.TIME,node.retro,node.normal)
        result['ERR']=result['DOWNFIELD']-desired
        return result
    def policy(node,*_):
        actual=oracle(node.TIME,node.retro,node.normal)['DOWNFIELD']
        aim=63610+contraction*(actual-63610)
        forecasts.append((actual,aim))
        return solver.Lex(VALID=True,AIM=aim,MIN=aim-1500,MAX=aim+1500)
    env.update(solved=base,geometry=dict(UT=1000),LANDING_POWERED_LEAD=1,
               targetLat=44.593,targetLng=-24.926,minLead=120,minRetroDv=2,maxRetroDv=120,
               desiredDownfield=15000,minDownfield=10000,maxDownfield=20000,
               _planRetroNode=plan,_readGeometricDeorbitNode=read,landingDeorbitLeadPolicy=policy,
               remove_probe=lambda node:nodes.remove(node),
               charge_forecast=lambda:setattr(counter,'value',counter.value+1))
    source=powered_source().replace('SET _deorbitEvaluations TO _deorbitEvaluations+1.',
                                     'charge_forecast().')
    run(source,env)
    assert env['poweredAccepted'] and not nodes,forecasts
    if contraction:assert 1<len(forecasts)<=3
    assert abs(forecasts[-1][0]-forecasts[-1][1])<=1500
    assert counter.value<=64 and counter.value==start+len(forecasts)+len(trials)
    if start==59:assert counter.value==64 and len(forecasts)==2 and len(trials)==3
    assert env['targetLat']==44.593 and env['targetLng']==-24.926
    assert env['solved']['CROSS']<=500 and abs(env['solved']['NORMAL'])<=10
    print(f'PASS: actual coupled Newton/powered-model loop converges a footprint-dependent lead in {len(forecasts)} fresh forecasts / {counter.value}/64 total trials, retaining target, lateral/fuel bounds and probe cleanup')


def check_shared_admission_and_rescue():
    env,_,_=solver.environment(lambda *args:None)
    calls=[]
    env.update(HASNODE=True,_readGeometricDeorbitNode=lambda *args:solver.Lex(VALID=True,HAS_IMPACT=True,
                   DV=20,NORMAL=0,DOWNFIELD=35000,CROSS=0,ANGLE=20,ERR=0),
               landingDeorbitLeadPolicy=lambda *args:solver.Lex(VALID=True,AIM=35000,MIN=33500,MAX=36500),
               _targetDeorbitTerrainAccepted=lambda *args:calls.append('terrain') or True)
    assert env['landingDeorbitNodeAccepted'](NS(TIME=1000),0,0) and calls==['terrain']
    env['landingDeorbitLeadPolicy']=lambda *args:solver.Lex(VALID=True,AIM=15000,MIN=10000,MAX=20000)
    assert not env['landingDeorbitNodeAccepted'](NS(TIME=1000),0,0)
    command=(ROOT/'cmd/landfallback.ks').read_text()
    saved=dict(SEQUENCE=['LAND_ASSIST','SURFACE_RETURN_SETUP'],RETURN_PE=53000)
    for phase,thrust,expected in (('LAND_ASSIST',0,True),('LAND',0,True),('LAND_DEORBIT',0,False),('LAND_ASSIST',1,False)):
        env=dict(enabled=1,stateGet=lambda *args:phase,SHIP=NS(STATUS='SUB_ORBITAL',
                 BODY=NS(ATM=NS(EXISTS=False)),THRUST=thrust,
                 CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),ABORT=False,
                 missionOverrideUpdate=lambda changes:saved.update(changes))
        source=function_body(command,'_cmdLandfallback')
        source=source.replace('RUNPATH("1:/lib/boot_lib").','').replace('bootPreamble().','')
        source=re.sub(r'PRINT "[^"\n]*"[^\n]*?\.(?= RETURN|\n)', '', source)
        saved.pop('LANDING_FLEXIBLE_SITE',None)
        run(source,env)
        assert ('LANDING_FLEXIBLE_SITE' in saved)==expected
        assert saved['SEQUENCE']==['LAND_ASSIST','SURFACE_RETURN_SETUP'] and saved['RETURN_PE']==53000
    print('PASS: retained admission uses the same fresh lead/terrain policy, accepts a modeled 35km footprint and rejects stale 15km policy; local fallback command preserves return intent and rejects wrong phases or live thrust')


def check_powered_step_hint_guards():
    env,_,_=solver.environment(lambda *args:None)
    hint=lambda down,err,old_down,old_err,history=True:env['_targetPoweredStepAim'](
        dict(DOWNFIELD=down,ERR=err),down-err,old_down,old_err,history)
    # Native pass1->2 data: actual powered residual, not just the ballistic
    # footprint. A useful positive secant accelerates the moving-goal solve.
    measured=hint(34667,-10464,18301,-16380)
    assert measured['MODE']=='secant' and 63000<measured['AIM']<64000
    for args in ((44650,-15216,34667,-10464), # Reversed/noisy branch.
                 (60018,-5253,59900,-5300), # Too little motion.
                 (60018,-5253,44650,-5300), # Too little residual change.
                 (10000,-1000,0,-1001),    # Near-zero derivative.
                 (10000,-1000,9000,-10000), # Excessive derivative.
                 (10000,-1000,0,float('nan'))):
        assert hint(*args)['MODE']=='model',args
    assert hint(34667,-10464,18301,-16380,False)['MODE']=='model'
    bounded=hint(10000,-10000,0,-11000)
    assert bounded['MODE']=='secant' and bounded['AIM']==40000 # Three residuals max.
    print('PASS: measured powered residuals drive the step hint; reversed/noisy/nonfinite/ill-conditioned slopes fall back, extrapolation stays bounded and cannot change admission tolerances')


def check_logged_moving_lead(curvature):
    # Observed (ballistic downfield, freshly modeled required lead). Linear
    # interpolation/extrapolation supplies a test response, NOT a native
    # orbit replay. The independent nonlinear geometry exercises the real
    # timing/normal Newton refiner and full outer admission under64 trials.
    measured=((18301,34681),(34667,45131),(44650,59866),(60018,65270),(66635,70623))
    def required(downfield):
        index=0
        while index<len(measured)-2 and downfield>measured[index+1][0]:index+=1
        left,aim=measured[index];right,next_aim=measured[index+1]
        return aim+(downfield-left)*(next_aim-aim)/(right-left)
    outcomes=[]
    for legacy in (True,False):
        def oracle(ut,retro,normal):
            delta=60-retro;elapsed=ut-1000
            down=18301+2500*delta+50*delta**2+500*elapsed+2*elapsed**2
            cross=100*elapsed-200*delta+curvature*elapsed**2+1000*normal
            return solver.impact(ut,retro,normal,down-15000,cross)
        env,count,trials=solver.environment(oracle);count.value=18
        geometry=env['_evalGeometricDeorbitNode']
        def evaluate(ut,retro,lat,lng,lead,aim,normal=0):
            result=geometry(ut,retro,lat,lng,lead,aim,normal)
            if result['VALID']:result['ERR']=result['DOWNFIELD']-aim
            return result
        env['_evalGeometricDeorbitNode']=evaluate
        nodes=[];forecasts=[]
        def plan(ut,retro,normal):
            node=NS(TIME=ut,retro=retro,normal=normal);nodes.append(node);return node
        def read(node,lat,lng,aim):
            result=oracle(node.TIME,node.retro,node.normal)
            result['ERR']=result['DOWNFIELD']-aim
            return result
        def policy(node,*_):
            down=oracle(node.TIME,node.retro,node.normal)['DOWNFIELD'];aim=required(down)
            forecasts.append((down,aim))
            return solver.Lex(VALID=True,AIM=aim,MIN=aim-1500,MAX=aim+1500)
        env.update(solved=oracle(1000,60,0),geometry=dict(UT=1000),LANDING_POWERED_LEAD=1,
            targetLat=44.593,targetLng=-24.926,minLead=120,minRetroDv=2,maxRetroDv=120,
            desiredDownfield=15000,minDownfield=10000,maxDownfield=20000,
            _planRetroNode=plan,_readGeometricDeorbitNode=read,landingDeorbitLeadPolicy=policy,
            remove_probe=lambda node:nodes.remove(node),
            charge_forecast=lambda:setattr(count,'value',count.value+1))
        if legacy:
            env['_targetPoweredStepAim']=lambda solved,aim,*_:dict(AIM=aim,MODE='model',SLOPE=0)
            env['_refineDeorbitFootprint']=lambda *args:call('_refineDeorbitFootprint',env,*args[:-1],0)
            # Include the previous inner preference-polishing policy in the
            # legacy comparison, not the revised powered-seed stopping rule.
            env['_targetDeorbitRefineDone']=lambda solved,lo,hi:env['_targetDeorbitSolutionAccepted'](solved,lo,hi) and solved['CROSS']<=250
        source=powered_source().replace('SET _deorbitEvaluations TO _deorbitEvaluations+1.','charge_forecast().')
        run(source,env)
        assert not nodes and count.value<=64
        assert count.value==18+len(trials)+len(forecasts)
        assert env['targetLat']==44.593 and env['targetLng']==-24.926
        outcomes.append((env['poweredAccepted'],count.value,env['solved']['ERR']))
        if not legacy:
            assert abs(forecasts[-1][0]-forecasts[-1][1])<=1500
            assert env['solved']['CROSS']<=500 and abs(env['solved']['NORMAL'])<=10
    assert not outcomes[0][0] and outcomes[1][0],outcomes
    assert outcomes[1][1]<outcomes[0][1],outcomes
    print('PASS: observed moving-lead curve with independent nonlinear geometry curvature%d holds the legacy policy outside tolerance at%d/64, while fresh one-step/secant refinement passes at%d/64 with unchanged1500m/cross/fuel bounds (not a native replay)'%(curvature,outcomes[0][1],outcomes[1][1]))


def check_geometric_hull_clearance():
    env,_,_=lead_environment()
    extents=Vec((2.,3.,8.));com=Vec((100.,-50.,20.));offset=Vec((0.,0.,2.))
    bounds=NS(EXTENTS=extents,ABSCENTER=com+offset,BOTTOMALTRADAR=12000.)
    radius=env['_landingLeadHullClearance'](bounds,com)
    assert abs(radius-(math.sqrt(77)+2))<1e-10
    # Independent corner distances: root/box centre differs from CoM, and
    # rotating the entire vessel cannot change its enclosing radius.
    for theta in (0.,.4,1.2,2.8):
        def rotate(v):return Vec((v[0]*math.cos(theta)-v[2]*math.sin(theta),v[1],v[0]*math.sin(theta)+v[2]*math.cos(theta)))
        bounds.ABSCENTER=com+rotate(offset)
        assert abs(env['_landingLeadHullClearance'](bounds,com)-radius)<1e-10
        for x in (-extents[0],extents[0]):
            for y in (-extents[1],extents[1]):
                for z in (-extents[2],extents[2]):
                    assert (rotate(Vec((x,y,z))+offset)).MAG<=radius+1e-10
    env['lmGroundPositionAt']=lambda _:Vec((0,0,200000+8791.7))
    env['lmGroundVelocityAt']=lambda _:Vec((533,0,-42.7))
    env['lmGroundGeoAt']=lambda _:NS(TERRAINHEIGHT=2460.5,LAT=33.78813,LNG=-25.69067)
    states=[]
    for false_hull in (0,2299.01,2358.15,20000):
        env['ALT'].RADAR=12000+false_hull
        bounds.BOTTOMALTRADAR=12000
        states.append(env['_landingLeadStateAt'](1234,4196,radius))
    assert all(state==states[0] for state in states)
    assert abs(states[0]['HEIGHT']-4595.7)<1e-7
    old_height=min(8791.7-4196,8791.7-2460.5-2299.01)
    assert old_height<=4039.5<states[0]['HEIGHT']
    print('PASS: logged2299m false radar-derived hull would ignite at4039.5m gate; geometric~10.8m enclosing radius preserves4595.7m clearance, bounds every corner/attitude and is independent of current terrain/radar mismatch')


if __name__=='__main__':
    check_reported_ignition()
    check_range_physics()
    check_controller_range()
    check_nominal_timing()
    check_native_lead()
    check_lead_refusals()
    check_powered_refinement()
    check_coupled_powered_refinement()
    check_coupled_powered_refinement(59,0)
    check_shared_admission_and_rescue()
    check_powered_step_hint_guards()
    check_logged_moving_lead(200)
    check_logged_moving_lead(500)
    check_geometric_hull_clearance()
