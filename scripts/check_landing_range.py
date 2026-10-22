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
    assert not new['H_NOW'] and not new['V_NOW'] and 21000<new['H_GATE']<24000
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
    assert -22000<miss<-19000
    print('PASS: supplied 516/-44.9/223.9 state replaces the 43km geographic gate with ~23km nominal range, preserves every vertical safety value and alignment guard; post-stage 40km target is flagged ~20km beyond nominal capture')


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


def control_distance(hs,vs,height,budget,active=44.68,weak=2.72):
    env,ctx=fixture(gravity=1.6284599,twr=active/1.6284599,
                    horizontal=hs,down=-vs,height=height)
    distance=0.;dt=.4;pause=3.;now=0.
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
            if budget<=1e-6:pause=now+3
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
        theta=math.radians(lng)
        return NS(LAT=lat,LNG=lng,TERRAINHEIGHT=0,
                  ALTITUDEPOSITION=lambda alt:Vec((math.sin(theta)*(radius+alt),0,math.cos(theta)*(radius+alt))))
    def geo_at(ut):
        pos=position(ut)
        return geo(0,math.degrees(math.atan2(pos[0],pos[2])))
    impact_ut=nd.TIME+coast
    env.update(SHIP=NS(MASS=1.,BODY=NS(RADIUS=radius,MU=mu,POSITION=Vec((0,0,0)),ATM=NS(EXISTS=False)),
                       BOUNDS=NS(BOTTOMALTRADAR=15000)),ALT=NS(RADAR=15000),
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
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',LEAD):
        env[name]=lambda *args,name=name:call(name,env,*args)
    env['lmSurfaceTrackOffset']=lambda *args:call('lmSurfaceTrackOffset',env,*args)
    return env,nd,impact_ut


def check_native_lead():
    env,nd,impact_ut=lead_environment()
    policy=env['landingDeorbitLeadPolicy'](nd,0,0)
    assert policy['VALID'],policy
    assert nd.TIME<policy['IGNITION_UT']<impact_ut
    assert 10000<policy['RANGE']<50000 and policy['AIM']>20000,policy
    assert abs(policy['AIM']+policy['RANGE']-policy['BALLISTIC'])<1e-8
    assert policy['MIN']==policy['AIM']-1500 and policy['MAX']==policy['AIM']+1500
    # Deorbit impulse has already been charged against the transfer budget.
    full_fuel=env['vesselLandingBrakeStageDv']
    env['vesselLandingBrakeStageDv']=lambda:full_fuel()+20
    extra=env['landingDeorbitLeadPolicy'](nd,0,0)
    assert extra['RANGE']<policy['RANGE'] and extra['IGNITION_UT']>policy['IGNITION_UT']
    nd.DELTAV.MAG=0
    env['vesselLandingBrakeStageDv']=full_fuel
    uncharged=env['landingDeorbitLeadPolicy'](nd,0,0)
    assert uncharged==extra
    env['LANDING_POWERED_LEAD']=0
    legacy=env['landingDeorbitLeadPolicy'](nd,0,0)
    assert legacy['AIM']==15000 and legacy['MIN']==10000 and legacy['MAX']==20000
    print('PASS: real source policy samples a post-node Kepler conic, finds a finite ignition before impact, derives >20km lead from ballistic minus powered travel, subtracts deorbit fuel first and preserves legacy policy on opt-out')


def check_lead_refusals():
    for kind in ('mode','credit','atmosphere','impact','underpowered','unknown-fuel','spent-fuel','timing','abort','no-coast','range','upfield'):
        env,nd,impact_ut=lead_environment()
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
        if kind=='range':env['lmNominalBrakeRange']=lambda *args:-1
        if kind=='upfield':env['lmSurfaceTrackOffset']=lambda *args:dict(VALID=True,DOWNFIELD=-1)
        result=env['landingDeorbitLeadPolicy'](nd,0,0)
        assert not result['VALID'],(kind,result)
    print('PASS: unsupported models, insufficient/unknown transfer fuel, underpowered stages, missing/late impacts, absent coast, abort and invalid/upfield ranges cannot authorize a deorbit')


def powered_source():
    source=function_body(solver.SOURCE,'targetedDeorbitAt')
    source=source[source.index('LOCAL poweredPass IS'):source.index('LOCAL bestUT IS')]
    return source.replace('REMOVE probeNode.','remove_probe(probeNode).')


def check_powered_refinement():
    for kind in ('solve','third-step','model-fails','no-progress','nonconverging',
                 'spent-trials','validation-reserve','no-impact'):
        env,_,_=solver.environment(lambda *args:None)
        base=solver.impact(1000,15,0,0,0)
        env['_deorbitEvaluations']=40
        if kind=='spent-trials':env['_deorbitEvaluations']=64
        if kind=='validation-reserve':env['_deorbitEvaluations']=60
        policies=[];nodes=[];refinements=[]
        def policy(*args):
            policies.append(1)
            aim=35000+len(policies)*10000 if kind=='nonconverging' else 63610
            return dict(VALID=kind!='model-fails',REASON='fixture',AIM=aim,MIN=aim-1500,MAX=aim+1500)
        def refine(best,lat,lng,lead,aim,lo,hi,min_dv,max_dv,reserve):
            assert reserve==1 and lo<=aim<=hi
            refinements.append(aim)
            assert env['_deorbitEvaluations']+3<=63
            env['_deorbitEvaluations']+=3
            result=dict(best)
            if kind!='no-progress':
                result['DOWNFIELD']=min(aim,best['DOWNFIELD']+20000) if kind=='third-step' else aim
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
        assert env['poweredAccepted']==(kind in ('solve','third-step'))
        if kind in ('solve','third-step'):assert env['solved']['DOWNFIELD']==63610
        else:assert result is False
        if kind=='third-step':
            assert len(refinements)==3 and len(policies)==4 and env['_deorbitEvaluations']==53
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
        return dict(VALID=True,AIM=aim,MIN=aim-1500,MAX=aim+1500)
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
    if contraction:assert len(forecasts)>3
    assert abs(forecasts[-1][0]-forecasts[-1][1])<=1500
    assert counter.value<=64 and counter.value==start+len(forecasts)+len(trials)
    if start==59:assert counter.value==64 and len(forecasts)==2 and len(trials)==3
    assert env['targetLat']==44.593 and env['targetLng']==-24.926
    assert env['solved']['CROSS']<=500 and abs(env['solved']['NORMAL'])<=10
    print(f'PASS: actual coupled Newton/powered-model loop converges a footprint-dependent lead in {len(forecasts)} fresh forecasts / {counter.value}/64 total trials, retaining target, lateral/fuel bounds and probe cleanup')


def check_shared_admission_and_rescue():
    env,_,_=solver.environment(lambda *args:None)
    calls=[]
    env.update(_readGeometricDeorbitNode=lambda *args:dict(VALID=True,HAS_IMPACT=True,
                   DV=20,NORMAL=0,DOWNFIELD=35000,CROSS=0,ANGLE=20),
               landingDeorbitLeadPolicy=lambda *args:dict(VALID=True,AIM=35000,MIN=33500,MAX=36500),
               _targetDeorbitTerrainAccepted=lambda *args:calls.append('terrain') or True)
    assert env['landingDeorbitNodeAccepted'](NS(TIME=1000),0,0) and calls==['terrain']
    env['landingDeorbitLeadPolicy']=lambda *args:dict(VALID=True,AIM=15000,MIN=10000,MAX=20000)
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


if __name__=='__main__':
    check_reported_ignition()
    check_range_physics()
    check_controller_range()
    check_native_lead()
    check_lead_refusals()
    check_powered_refinement()
    check_coupled_powered_refinement()
    check_coupled_powered_refinement(59,0)
    check_shared_admission_and_rescue()
