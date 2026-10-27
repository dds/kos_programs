"""Shared bounded lateral braking: source/3D staged physics, not a native flight."""
import math
from functools import lru_cache
from types import SimpleNamespace as NS

from check_landing_prediction import environment,recorded_stack,Vec,independent_inertial_capture
from check_landing_braking import fixture,call
from check_codebase import ROOT,function_body
from check_runtime_contracts import KList


def check_thrust_bounds():
    env,_=fixture()
    up=Vec((0,0,1))
    for hs in (0,1,18,18.01,25,120,541):
        for error in (-1e6,-2000,0,1200,1e6):
            for acc in (2.45,40.):
                vel=Vec((hs,0,0));offset=Vec((12000,error,1000))
                base=call('lmEconomyBrakeThrust',env,vel,-38,-28,up,acc,1.63)
                thrust=call('lmBrakeLateralThrust',env,base,vel,offset,up,acc,1.63)
                assert abs(thrust[2]-base[2])<1e-10
                assert abs(thrust.MAG-base.MAG)<1e-10
                assert thrust.MAG<=acc+1e-9 and thrust[2]>=0
                assert thrust[0]<=1e-10
                if hs>18:
                    assert abs(thrust[1])<=-thrust[0]*math.tan(math.radians(15))+1e-9
                    assert thrust[1]*error>=0
                else:assert (thrust-base).MAG<1e-10
    print('PASS: lateral steering preserves vertical thrust and total magnitude across both stages, never accelerates along travel or exceeds15deg; low-speed handoff and zero-error command are unchanged')


@lru_cache(maxsize=None)
def recorded():
    env=environment();env['LANDING_POWERED_LEAD']=1
    pos=Vec((208461.,0,0));vel=Vec((-38.3,0,541.));stack=recorded_stack()
    baseline=env['landingPredictBrake'](pos,vel,stack,4113.1358,.5)
    assert baseline['VALID']
    return pos,vel,stack,baseline


@lru_cache(maxsize=None)
def run_case(error):
    env=environment();env['LANDING_POWERED_LEAD']=1
    pos,vel,stack,baseline=recorded()
    target=(baseline['POSITION'].NORMALIZED*204113.1358+Vec((0,error,0))).NORMALIZED*204113.1358
    result=env['landingPredictBrake'](pos,vel,stack,4113.1358,.5,target)
    assert result['VALID'],result
    old=(baseline['POSITION'].NORMALIZED-target.NORMALIZED).MAG*200000
    miss=(result['POSITION'].NORMALIZED-target.NORMALIZED).MAG*200000
    assert miss<300 and result['HS']<=1 and result['HEIGHT']>3
    assert result['STAGES_USED']==2 and result['IMPULSE']-baseline['IMPULSE']<15
    if error:assert miss<old/4
    else:assert miss<50
    print('PASS: staged Mun lateral%+dm -> %.1fm capture miss (unguided%.1fm), extra impulse%.2fm/s; no hover, two permitted engines only' %
          (error,miss,old,result['IMPULSE']-baseline['IMPULSE']))
    return env,pos,vel,stack,target,result


def check_live_predictor_and_attitude():
    env,ctx=fixture(gravity=1.63,horizontal=541,down=38.3,height=4348)
    predict=environment();predict['LANDING_POWERED_LEAD']=1
    pos,vel,stack,_=recorded()
    target=Vec((204000.,1200.,14000.)).NORMALIZED*204113.1358
    effective=65138397520.7807/pos.MAG**2-541**2/pos.MAG
    env.update(LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1,
               LATLNG=lambda *_:NS(ALTITUDEPOSITION=lambda _:target),
               _landingBurnHeight=lambda _:pos.MAG-204113.1358)
    ctx.update(POSITION=pos,UP_VEC=pos.NORMALIZED,H_VEL=Vec((0,0,541.)),
               MAX_ACC=stack['STAGES'][0]['THRUST']/stack['MASS'],PLAN_ACC=stack['RESERVE_ACC'],
               BRAKE_GRAV=65138397520.7807/200000**2,GRAV=effective)
    info=call('_landingBrakeSteeringInfo',env,ctx)
    env['SHIP'].FACING.FOREVECTOR=ctx['steering']
    info=call('_landingBrakeSteeringInfo',env,ctx)
    command=predict['_landingPredictionCommand'](pos,vel,ctx['MAX_ACC'],ctx['PLAN_ACC'],4113.1358,target)
    actual=ctx['steering']*ctx['MAX_ACC']*info['THROTTLE']
    assert info['LATERAL'] and info['LATERAL_MISS']>1000 and 0<info['LATERAL_YAW']<=15.0001
    assert (actual-command).MAG<1e-8
    env['SHIP'].FACING.FOREVECTOR=-ctx['steering']
    assert call('_landingBrakeSteeringInfo',env,ctx)['THROTTLE']==0
    for blocked in ('flexible','no-target','divert','legacy'):
        env['LANDING_FLEXIBLE_SITE']=int(blocked=='flexible')
        env['LANDING_POWERED_LEAD']=int(blocked!='legacy')
        ctx.update(HAS_TARGET=blocked!='no-target',DIVERT_PENDING=blocked=='divert')
        assert not call('_landingBrakeSteeringInfo',env,ctx)['LATERAL']
    print('PASS: flight and predictor return identical guided thrust; actual-facing cutoff still blocks wrong attitude and flexible/blind/divert/legacy paths retain their control law')


def check_independent_guided_physics():
    env,pos,vel,stack,target,predicted=run_case(1200)
    reference,seconds,mass=independent_inertial_capture(env,stack,pos,vel,dt=.5,target=target)
    assert (predicted['POSITION']-reference).MAG<120
    assert abs(predicted['SECONDS']-seconds)<3 and abs(predicted['MASS']-mass)<.003
    coarse=env['landingPredictBrake'](pos,vel,stack,4113.1358,1.,target)
    assert coarse['VALID'] and (coarse['POSITION']-predicted['POSITION']).MAG<50
    lead=function_body((ROOT/'lib/landing_deorbit_lead.ks').read_text(),'landingDeorbitLeadPolicy')
    assert 'stack,elevation,1,targetPosition)' in lead
    assert lead.index('LOCAL targetPosition')<lead.index('landingPredictBrake(')
    print('PASS: guided rotating-frame midpoint capture matches independent inertial RK4/mass/staging physics within120m; half-step convergence and target wiring are checked')


def check_minmus_flats():
    env=environment();env['LANDING_POWERED_LEAD']=1
    world=env['SHIP'].BODY
    world.RADIUS=60000;world.MU=1.7658e9;world.ROTATIONPERIOD=40400
    pos=Vec((66000,0,0));vel=Vec((-25.,0,160.))
    stack=dict(VALID=True,MASS=1.,RESERVE_ACC=2.,STAGES=KList([
        dict(THRUST=2.,EXHAUST=290*9.80665,FUEL=.3,DROP=0.)]))
    original=env['landingPredictBrake'](pos,vel,stack,0,.5)
    assert original['VALID']
    target=(original['POSITION'].NORMALIZED*60000+Vec((0,1200,0))).NORMALIZED*60000
    guided=env['landingPredictBrake'](pos,vel,stack,0,.5,target)
    assert guided['VALID'] and guided['STAGES_USED']==1
    miss=(guided['POSITION'].NORMALIZED-target.NORMALIZED).MAG*60000
    assert miss<50 and guided['IMPULSE']-original['IMPULSE']<10
    print('PASS: rotating Minmus single-stage/sea-level Flats case corrects1.2km to%.1fm without inventing transfer fuel or skipping guidance at zero terrain elevation' % miss)


if __name__=='__main__':
    check_thrust_bounds()
    check_live_predictor_and_attitude()
    for cross in (0,1200,2000,-2000):run_case(cross)
    check_independent_guided_physics()
    check_minmus_flats()
