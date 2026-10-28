"""Variable-mass main-burn source fixtures, not native KSP flight validation."""
import math
from types import SimpleNamespace as NS

from check_codebase import ROOT, function_body, dependency_tables, closure
from check_landing_braking import fixture, call, Vec
from check_deorbit_geometry import cross, Geo
from check_runtime_contracts import KList

SOURCE=(ROOT/'lib/landing_prediction.ks').read_text()+'\n'+(ROOT/'lib/landing_brake_fuel.ks').read_text()


def environment():
    env,_=fixture()
    env.update(CONSTANT=NS(E=math.e,PI=math.pi),LN=math.log,LIST=lambda *args:KList(args))
    env['SHIP']=NS(BODY=NS(RADIUS=200000.,MU=65138397520.7807,
                           ROTATIONPERIOD=138984.376574476,POSITION=Vec((0,0,0))))
    env['LATLNG']=lambda lat,lng:Geo(lat,lng,env['SHIP'].BODY)
    env['VCRS']=cross
    import re
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:call(name,env,*args)
    env.update(ARCCOS=lambda value:math.degrees(math.acos(value)),
               ARCSIN=lambda value:math.degrees(math.asin(value)),
               ARCTAN2=lambda a,b:math.degrees(math.atan2(a,b)))
    return env


def recorded_stack():
    mass=1.36875534057617;retained=2/2.45251843949879;exhaust=345*9.80665
    fuel=mass*(1-math.exp(-293.416764006029/exhaust))
    return dict(VALID=True,MASS=mass,STAGE=3,RESERVE_ACC=2.45251843949879,
                STAGES=KList([dict(THRUST=55.,EXHAUST=exhaust,FUEL=fuel,DROP=mass-retained-fuel),
                              dict(THRUST=2.,EXHAUST=290*9.80665,FUEL=.22,DROP=0.)]))


def check_recorded_capture():
    env=environment();stack=recorded_stack()
    # Reported ignition state: local relief isn't recoverable from this log.
    # Constant target elevation is explicit; we do not assert exact replay.
    pos=Vec((200000+9522,0,0));vel=Vec((-31.2123,0,542.3246))
    model=env['landingPredictBrake'](pos,vel,stack,4113.1358,1.)
    assert model['VALID'],model
    angle=math.atan2(model['POSITION'][2],model['POSITION'][0]);distance=200000*angle
    quick=env['lmFuelBrakeRange'](542.3246,stack,1.63*(200000/(200000+9522/2))**2,204761.,.5)
    assert 16000<quick<18500
    print('PASS: logged ignition replay forecasts %.0fm / %.1fs vs ~17052m /154s flown; engine Isp and flat target-height assumptions are explicit, not an exact native replay' % (distance,model['SECONDS']))
    assert 13000<distance<20000
    assert model['MASS']<2/2.45251843949879 and model['STAGES_USED']==2
    assert 100<model['SECONDS']<240 and model['HS']<=1
    assert not stack['STAGES'][0]['FUEL']==0 # Pure model never mutates the snapshot.





def check_snapshot():
    from check_landing_stage_brake import Mixture
    env=environment();template=recorded_stack();mass=template['MASS'];retained=2/2.45251843949879
    fuels=[NS(NAME=name,RATIO=ratio,DENSITY=.005) for name,ratio in (('LiquidFuel',.45),('Oxidizer',.55))]
    def resources(fuel_mass):
        return KList(NS(NAME=f.NAME,AMOUNT=fuel_mass*f.RATIO/.005,ENABLED=True) for f in fuels)
    def engine(stage,group,thrust,isp,ignition):
        return NS(STAGE=stage,DECOUPLEDIN=group,AVAILABLETHRUST=thrust if ignition else 0,
                  POSSIBLETHRUST=thrust,POSSIBLETHRUSTAT=lambda pressure:thrust,VISP=isp,
                  CONSUMEDRESOURCES=Mixture((f.NAME,f) for f in fuels),IGNITION=ignition,
                  FLAMEOUT=False,THROTTLELOCK=False,MULTIMODE=False)
    active=engine(3,2,55,345,True);lander=engine(2,1,2,290,False);returning=engine(1,-1,4,300,False)
    env['SHIP'].MASS=mass;env['SHIP'].BODY.ATM=NS(EXISTS=False)
    env['SHIP'].ENGINES=KList([active,lander,returning])
    env['SHIP'].PARTS=KList([NS(MASS=mass-retained,DECOUPLEDIN=2,RESOURCES=resources(template['STAGES'][0]['FUEL'])),
                            NS(MASS=retained-.4,DECOUPLEDIN=1,RESOURCES=resources(.22)),
                            NS(MASS=.4,DECOUPLEDIN=-1,RESOURCES=resources(.1))])
    env.update(STAGE=NS(NUMBER=3,DELTAV=NS(VACUUM=293.416764006029)),
               CORE=NS(PART=NS(DECOUPLEDIN=-1)),LANDING_STAGE_LIMIT=2)
    env['vesselLandingNextEngineStage']=lambda:call('vesselLandingNextEngineStage',env)
    env['landingRolePolicy']=dict(VALID=True,RETURN=0)
    original=env['landingBrakeStack']()
    assert original['VALID'] and len(original['STAGES'])==2
    assert abs(original['STAGES'][0]['FUEL']-template['STAGES'][0]['FUEL'])<1e-10
    assert abs(original['RESERVE_ACC']-template['RESERVE_ACC'])<1e-10
    assert abs(original['STAGES'][1]['FUEL']-.22)<1e-10
    # Retained return fuel may never increase either landing-engine budget.
    env['SHIP'].PARTS[2].RESOURCES=resources(1e6)
    assert env['landingBrakeStack']()==original
    charged=env['landingBrakeStackAt'](original,mass,20)
    assert charged['MASS']<mass and charged['STAGES'][0]['FUEL']<original['STAGES'][0]['FUEL']
    assert charged['STAGES'][1]==original['STAGES'][1]
    assert not env['landingBrakeStackAt'](original,mass,400)['VALID']
    for attr in ('MULTIMODE','THROTTLELOCK'):
        setattr(active,attr,True)
        assert not env['landingBrakeStack']()['VALID']
        setattr(active,attr,False)
    lander.CONSUMEDRESOURCES['Oxidizer'].DENSITY=0
    assert not env['landingBrakeStack']()['VALID']
    print('PASS: actual 3/2/1 snapshot isolates limiting mixtures and return wet mass, charges deorbit fuel once, copies without mutation and rejects unsupported/depleted hardware')


def independent_inertial_capture(env,stack,pos,ground_vel,dt=.25,target=None):
    # An independent RK4 flight model in a NONROTATING frame. The production
    # model uses midpoint integration in a surface-fixed rotating frame.
    omega=env['landingRotationVector']();rate=omega.MAG
    axis=omega/rate if rate else Vec((0,0,1))
    def rotate(vec,angle):
        return vec*math.cos(angle)+cross(axis,vec)*math.sin(angle)+axis*float(axis@vec)*(1-math.cos(angle))
    inertial_pos=pos.copy();inertial_vel=ground_vel+cross(omega,pos)
    mass=stack['MASS'];index=0;item=stack['STAGES'][0];fuel=item['FUEL'];pause=0.;elapsed=0.
    while elapsed<600:
        pos=rotate(inertial_pos,-rate*elapsed)
        vel=rotate(inertial_vel-cross(omega,inertial_pos),-rate*elapsed)
        up=pos.NORMALIZED;hs=(vel-up*float(up@vel)).MAG;vs=float(up@vel)
        height=pos.MAG-200000-4113.1358
        desired=env['lmDescentSpeed'](height,2,3,30)
        if height<=1000 and hs<=1 and abs(vs+desired)<=5:
            return pos,elapsed,mass
        assert height>3
        acc=item['THRUST']/mass
        planned=min(acc,stack['RESERVE_ACC']) if index==0 and stack['RESERVE_ACC'] else acc
        force=env['_landingPredictionCommand'](pos,vel,acc,planned,4113.1358,
            Vec((0,0,0)) if target is None else target)*mass
        if pause>0:force=force*0
        flow=force.MAG/item['EXHAUST']
        step=min(dt,fuel/flow) if flow else dt
        if pause>0:step=min(step,pause)
        def acceleration(position,offset):
            return -65138397520.7807*position/position.MAG**3+rotate(force,rate*(elapsed+offset))/(mass-flow*offset)
        k1p=inertial_vel;k1v=acceleration(inertial_pos,0)
        k2p=inertial_vel+k1v*step/2;k2v=acceleration(inertial_pos+k1p*step/2,step/2)
        k3p=inertial_vel+k2v*step/2;k3v=acceleration(inertial_pos+k2p*step/2,step/2)
        k4p=inertial_vel+k3v*step;k4v=acceleration(inertial_pos+k3p*step,step)
        inertial_pos=inertial_pos+(k1p+2*k2p+2*k3p+k4p)*step/6
        inertial_vel=inertial_vel+(k1v+2*k2v+2*k3v+k4v)*step/6
        elapsed+=step;mass-=flow*step;fuel-=flow*step;pause=max(0,pause-step)
        if fuel<=1e-8:
            mass-=item['DROP'];index+=1
            assert index<len(stack['STAGES'])
            item=stack['STAGES'][index];fuel=item['FUEL'];pause=.5
    raise AssertionError('independent capture deadline')


def check_independent_prediction():
    env=environment();stack=recorded_stack();pos=Vec((209522.,0,0));vel=Vec((-31.2123,0,542.3246))
    reference,seconds,mass=independent_inertial_capture(env,stack,pos,vel)
    coarse=env['landingPredictBrake'](pos,vel,stack,4113.1358,1.)
    fine=env['landingPredictBrake'](pos,vel,stack,4113.1358,.5)
    assert coarse['VALID'] and fine['VALID']
    assert (coarse['POSITION']-reference).MAG<120
    assert (fine['POSITION']-reference).MAG<120
    assert abs(fine['SECONDS']-seconds)<3 and abs(fine['MASS']-mass)<.003
    assert (fine['POSITION']-coarse['POSITION']).MAG<40
    print('PASS: rotating-frame midpoint controller prediction agrees within120m with independent inertial RK4 flight physics, mass flow and discrete dry-mass separation; half-step convergence stays within40m')


def check_prediction_limits():
    env=environment();stack=recorded_stack();pos=Vec((209522.,0,0));vel=Vec((-31.,0,542.))
    env['ABORT']=True
    assert not env['landingPredictBrake'](pos,vel,stack,4113.)['VALID']
    env['ABORT']=False
    stack['STAGES'][1]['FUEL']=.00001
    assert env['landingPredictBrake'](pos,vel,stack,4113.)['REASON']=='landing-fuel-exhausted'
    assert not env['landingPredictBrake'](Vec((204115,0,0)),vel,recorded_stack(),4113.)['VALID']
    requested=env['_landingPredictionCommand'](pos,vel,.1,.1,4113.)
    assert requested.MAG<=.100001
    class DeadlineClock:
        reads=0
        @property
        def SECONDS(self):
            self.reads+=1
            return 0 if self.reads==1 else 21
    env['TIME']=DeadlineClock()
    assert env['landingPredictBrake'](pos,vel,recorded_stack(),4113.)['REASON']=='prediction-budget'
    from check_surface_return import read_settings
    for moon in ('mun','minmus'):
        profile=read_settings((ROOT/f'missions/RO9/{moon}_landing_return.ks').read_text(),{})
        assert profile['TARGET_LOCK']==1 and profile['LANDING_AUTO_TARGET']==0 and profile['LANDING_FLEXIBLE_SITE']==0
        assert profile['LANDING_POWERED_LEAD']==profile['LANDING_ECONOMY_BRAKE']==profile['LANDING_STAGE_BRAKE_CREDIT']==1
        assert profile['TARGET_DEORBIT_NORMAL_DV_CAP']==10
        assert profile['DEORBIT_CROSSTRACK_AUTHORITY_KM']==(2 if moon=='mun' else .5)
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    planning=closure(['landing_deorbit_lead'],deps);flight=closure(['landing_main'],deps)
    assert 'landing_brake_math' in planning and 'landing_brake_math' in flight
    assert 'landing_prediction' not in flight and 'landing_main' not in planning and 'landing_brake' not in planning
    assert 'lmBrakeDescentTarget' not in (ROOT/'lib/landing_brake.ks').read_text().split('GLOBAL FUNCTION _landingBrakeSteeringInfo')[0]
    print('PASS: Abort, exhausted engine fuel and uncaptured surface reject forecasts; shared math is resident but heavy orbital predictor/FSM remain in separate bands')



def check_live_gate_and_minmus():
    env=environment()
    _,ctx=fixture(horizontal=542.3246,down=31.2123,height=5410,twr=40.18249/1.63)
    ctx.update(PLAN_ACC=2.45251843949879,RESERVE_ACC=2.45251843949879,
               BRAKE_STAGE_DV=293.416764006029,downrange=21103)
    env.update(LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1,LANDING_STAGE_BRAKE_CREDIT=1,
               _landingTargetHeight=lambda c:c['height'],_landingBottomRadar=lambda:6264.,
               _landingDownrangeToTarget=lambda c:c['downrange'],lmDistanceToTarget=lambda *args:21103.)
    env['SHIP'].MASS=recorded_stack()['MASS'];env['SHIP'].ALTITUDE=9522
    old=call('_landingBrakeGateInfo',env,ctx)
    ctx['BRAKE_MODEL']=recorded_stack()
    new=call('_landingBrakeGateInfo',env,ctx)
    assert old['H_GATE']>new['H_GATE']
    assert not new['H_NOW']
    historical=env['lmNominalBrakeRange'](542.3246,40.18249,2.45251843949879,293.416764006029,1.63,3,200000,9522)
    assert 3000<historical-new['H_GATE']<4000
    assert 700<old['H_GATE']-new['H_GATE']<1100
    for field in ('V_GATE','V_ETA','V_NOW'):assert new[field]==old[field]
    # A smaller rotating body, single active landing stage, no transfer credit.
    env['SHIP'].BODY.RADIUS=60000.;env['SHIP'].BODY.MU=.491*60000**2
    env['SHIP'].BODY.ROTATIONPERIOD=40400.
    stack=dict(VALID=True,MASS=1.,STAGE=2,RESERVE_ACC=0,
               STAGES=KList([dict(THRUST=2.5,EXHAUST=300*9.80665,FUEL=.4,DROP=0)]))
    result=env['landingPredictBrake'](Vec((63000.,0,0)),Vec((-30.,0,180.)),stack,0)
    assert result['VALID'] and result['STAGES_USED']==1 and result['HEIGHT']>0
    print('PASS: recorded old H gate shrinks by3-4km (about0.9km beyond the prior timing fix) while every V safety value remains identical; rotating Minmus single-stage control captures without inventing transfer fuel')



def check_fixed_gate_coupling():
    from check_landing_range import lead_environment
    env,node,_=lead_environment()
    # The policies already run the full forecast. Capture those exact results
    # instead of paying for two identical extra integrations in this check.
    predictor=env['landingPredictBrake'];forecasts=[]
    def record_forecast(*args):
        result=predictor(*args);forecasts.append(result);return result
    env['landingPredictBrake']=record_forecast
    vertical=env['landingDeorbitLeadPolicy'](node,0,0)
    target_geo=env['SHIP'].BODY.GEOPOSITIONOF(forecasts[-1]['POSITION'])
    env['LANDING_FLEXIBLE_SITE']=0
    fixed=env['landingDeorbitLeadPolicy'](node,target_geo.LAT,target_geo.LNG)
    assert fixed['VALID'] and fixed['IGNITION_UT']<vertical['IGNITION_UT']
    assert len(forecasts)==2
    actual=forecasts[-1]
    capture=env['SHIP'].BODY.GEOPOSITIONOF(actual['POSITION'])
    error=env['lmSurfaceTrackOffset'](target_geo.LAT,target_geo.LNG,capture.LAT,capture.LNG,
                                      env['lmGroundVelocityAt'](fixed['IGNITION_UT']))
    assert error['DIST']<750
    print('PASS: native-conic fixture with the actual fixed-site H policy ignites before V and captures within750m of the intended site, rather than assuming V-only ignition while flight burns at H')


def check_terminal_brake_agreement():
    env=environment()
    body=env['SHIP'].BODY
    body.RADIUS=60000;body.MU=1765800026.31247
    pos=Vec((60247,0,0));vel=Vec((-15,0,15.3))
    angle=321/body.RADIUS
    target=Vec((body.RADIUS*math.cos(angle),0,body.RADIUS*math.sin(angle)))
    gravity=body.MU/pos.MAG**2-15.3**2/pos.MAG
    _,ctx=fixture(gravity=gravity,twr=2.69/gravity,horizontal=15.3,down=15,height=247)
    ctx.update(UP_VEC=Vec((1,0,0)),H_VEL=Vec((0,0,15.3)),POSITION=pos,
               BRAKE_GRAV=body.MU/body.RADIUS**2)
    env.update(LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1,MAX_TILT=12,
        _landingBurnHeight=lambda _:247,_landingBottomRadar=lambda:247,
        lmDistanceToTarget=lambda *_:321,
        _landingSetSteering=lambda c,x:c.update(steering=x))
    env['SHIP'].FACING=NS(FOREVECTOR=Vec((1,0,0)))
    forecast=env['_landingPredictionCommand'](pos,vel,2.69,2.69,0,target)
    call('_landingBrakeSteeringInfo',env,ctx)
    env['SHIP'].FACING.FOREVECTOR=ctx['steering']
    live=call('_landingBrakeSteeringInfo',env,ctx)
    actual=ctx['steering']*(2.69*live['THROTTLE'])
    assert (forecast-actual).MAG<1e-8,(forecast,actual)
    assert forecast.MAG>1 and forecast[2]<-.5
    print('PASS: close-target15.3m/s terminal braking uses the same stopping-speed decision and thrust vector in the powered predictor and actual live controller')


if __name__=='__main__':
    check_terminal_brake_agreement()
    check_recorded_capture()
    check_snapshot()
    check_independent_prediction()
    check_prediction_limits()
    check_live_gate_and_minmus()
    check_fixed_gate_coupling()
