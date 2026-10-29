"""Reported Mun ignition with explicit terrain/engine approximations.

Executes real live/forecast gates and the powered predictor. This is a local
coast and flat-datum replay, not native TR/KSP propagation or a flight proof.
"""
import math
import re
from functools import lru_cache
from types import SimpleNamespace as NS

from check_codebase import ROOT, function_body
from check_landing_range import LEAD, lead_environment
from check_landing_braking import fixture, call, Vec
from check_runtime_contracts import KList, run
from check_surface_return import read_settings
from check_deorbit_geometry import cross
from check_deorbit_disk import Text


def replay():
    env, _, _ = lead_environment()
    # Native boot017: hs537, down29.9, ASL9216.4, local terrain5103.5,
    # target elevation4985.8, activeAcc39.05, reserveAcc2.45, stageDv376.3.
    # 55/2kN and 345/290s are RO9 hardware assumptions, not new telemetry.
    # The full diagnostic now records actual snapshot values for verification.
    mass, retained = 55/39.05, 2/2.45
    fuel = mass*(1-math.exp(-376.3/(345*9.80665)))
    stack = dict(VALID=True, MASS=mass, STAGE=3, RESERVE_ACC=2.45,
                 STAGES=KList([dict(THRUST=55,EXHAUST=345*9.80665,FUEL=fuel,DROP=mass-retained-fuel),
                               dict(THRUST=2,EXHAUST=290*9.80665,FUEL=.22,DROP=0)]))
    lat0, lon0, lat1, lon1 = map(math.radians,(-10.06428,96.64864,-10.590,99.490))
    angle = math.acos(math.sin(lat0)*math.sin(lat1)+math.cos(lat0)*math.cos(lat1)*math.cos(lon1-lon0))
    target_lng = math.degrees(angle)
    radius, elevation, terrain = 200000.,4985.8,5103.5
    pos0, vel0 = Vec((radius+9216.4,0,0)), Vec((-29.9,0,537.))
    gravity = pos0*(-env['SHIP'].BODY.MU/pos0.MAG**3)
    # Rotate into one vertical plane. Constant initial coast acceleration is
    # adequate for the <1sec difference; the burn uses the full real model.
    position = lambda ut:pos0+vel0*ut+gravity*ut*ut/2
    velocity = lambda ut:vel0+gravity*ut
    def geo(lat,lng):
        theta=math.radians(lng)
        return NS(LAT=lat,LNG=lng,TERRAINHEIGHT=terrain,
                  ALTITUDEPOSITION=lambda alt:Vec(((radius+alt)*math.cos(theta),0,(radius+alt)*math.sin(theta))))
    env.update(LANDING_FLEXIBLE_SITE=0,TARGET_TOLERANCE=500,
               LATLNG=geo,lmGroundPositionAt=position,lmGroundVelocityAt=velocity,
               lmGroundGeoAt=lambda ut:geo(0,math.degrees(math.atan2(position(ut)[2],position(ut)[0]))),
               VCRS=cross,
               landingRotationVector=lambda:Vec((0,-2*math.pi/138984.376574476,0)))
    live,ctx = fixture()
    live.update(env)
    target=geo(0,target_lng).ALTITUDEPOSITION(elevation)
    ctx.update(HAS_TARGET=True,PLAN_ACC=2.45,MAX_ACC=39.05,BRAKE_STAGE_DV=376.3,
               BRAKE_MODEL=stack,BRAKE_GRAV=env['SHIP'].BODY.MU/radius**2)
    env['SHIP'].MASS=mass
    def gates(ut):
        pos,vel=position(ut),velocity(ut)
        up=pos.NORMALIZED;vs=float(vel@up);hvel=vel-up*vs
        env['SHIP'].ALTITUDE=pos.MAG-radius
        sample=env['_landingLeadStateAt'](ut,elevation,4.64)
        ctx.update(UP_VEC=up,H_VEL=hvel,H_SPEED=hvel.MAG,V_SPEED=vs,DOWN_SPEED=max(0,-vs),
                   height=sample['HEIGHT'],downrange=float((target-pos)@hvel.NORMALIZED))
        live['LANDING_BRAKE_UNDERSHOOT_BIAS']=env['LANDING_BRAKE_UNDERSHOOT_BIAS']
        gate=call('_landingBrakeGateInfo',live,ctx)
        predicted=env['_landingLeadGateAt'](ut,0,target_lng,elevation,39.05,2.45,376.3,
                                            ctx['BRAKE_GRAV'],3,stack,4.64)
        assert predicted == (gate['H_NOW'] or gate['V_NOW'])
        return gate
    return env,ctx,stack,position,velocity,target,angle,gates


@lru_cache(maxsize=2)
def bias_result(legacy):
    env,ctx,stack,position,velocity,target,angle,gates=replay()
    profile=(ROOT/'missions/RO9/mun_target_science_return.ks').read_text()
    settings='\n'.join(line for line in profile.splitlines()
                       if re.match(r'SET (?:TARGET_TOLERANCE|LANDING_BRAKE_UNDERSHOOT_BIAS)\b',line))
    configured=read_settings(settings,dict(env))
    env['LANDING_BRAKE_UNDERSHOOT_BIAS']=(env['LANDING_BRAKE_UNDERSHOOT_BIAS'] if legacy
                                      else configured['LANDING_BRAKE_UNDERSHOOT_BIAS'])
    lo,hi=-2.,2.
    assert not gates(lo)['H_NOW'] and gates(hi)['H_NOW']
    for _ in range(12):
        mid=(lo+hi)/2
        if gates(mid)['H_NOW']:hi=mid
        else:lo=mid
    gate=gates(hi)
    assert gate['H_NOW'] and not gate['V_NOW'] and ctx['height']-gate['V_GATE']>1500
    model=env['landingPredictBrake'](position(hi),velocity(hi),stack,4985.8,1,target)
    assert model['VALID'] and model['STAGES_USED']==2 and model['HS']<=1
    error=200000*(math.atan2(model['POSITION'][2],model['POSITION'][0])-angle)
    assert configured['TARGET_TOLERANCE']==500
    return hi,error,model


def check_reported_bias_conflict(legacy):
    _,error,_=bias_result(legacy)
    assert error<-500 if legacy else abs(error)<500,error
    print('PASS: actual %s bias gives %.0fm capture error using the reported ignition, explicit terrain/hardware approximations and agreeing live/forecast gates, with V reserve>1.5km' % ('legacy500m' if legacy else 'mission0m',error))


def check_timing_and_fuel():
    old,new=bias_result(True),bias_result(False)
    assert 0<new[0]-old[0]<1.1
    assert abs(new[2]['IMPULSE']-old[2]['IMPULSE'])<2
    assert new[2]['HEIGHT']>500 and new[2]['MASS']>.7
    print('PASS: geographic correction moves H ignition by only%.2fs, capture error%.0f->%.0fm; impulse changes<2m/s and two-stage fuel/vertical capture remain valid' % (new[0]-old[0],old[1],new[1]))


def check_vertical_priority_and_config_scope():
    env,ctx,stack,_,_,_,_,gates=replay()
    before=gates(0)
    env['LANDING_BRAKE_UNDERSHOOT_BIAS']=0
    after=gates(0)
    assert before['H_NOW'] and not after['H_NOW']
    for key in ('V_GATE','V_ETA','V_NOW','H_MODEL_VALID','H_BRAKE','BRAKE_LEAD'):
        assert before[key]==after[key],key
    # At a safety deadline, changing the geographic preference cannot coast.
    ctx['height']=after['V_GATE']-1
    live,_=fixture();live.update(env)
    gate=call('_landingBrakeGateInfo',live,ctx)
    assert gate['V_NOW']
    config=(ROOT/'lib/landing_config.ks').read_text()
    assert 'GLOBAL LANDING_BRAKE_UNDERSHOOT_BIAS IS 500.' in config
    for name in ('minmus_economy_return','mun_economy_return'):
        source=(ROOT/f'missions/RO9/{name}.ks').read_text()
        assert not re.search(r'SET LANDING_BRAKE_UNDERSHOOT_BIAS\b',source)
    print('PASS: only this mission changes its deliberate geographic offset; lead/nominal range and every V safety value remain identical, V still commands ignition independently, and other profiles retain their defaults')


def check_diagnostic_snapshot():
    env,node,_=lead_environment()
    node.PROGRADE=-node.DELTAV.MAG
    node.NORMAL=0
    source=function_body(LEAD,'landingDeorbitLeadPolicy')
    # Native scalar/string concatenation: only adapt the first literal to
    # the existing fixture Text type; execute the complete real expression.
    source=source.replace('"STATS deorbit powered-lead aimM="','Text("STATS deorbit powered-lead aimM=")')
    local=dict(env,nd=node,targetLat=0,targetLng=0,legacyAim=15000,Text=Text)
    policy=run(source,local)
    assert policy['VALID']
    text=policy['DIAGNOSTIC']
    assert 'hBiasM=500' in text and 'hLeadM=100' in text
    assert 'startMass=' in text and 'stages=2' in text and len(text)<1800
    for prefix,item in (('first',local['stack']['STAGES'][0]),('last',local['stack']['STAGES'][-1])):
        for name,digits in (('Thrust',4),('Exhaust',4),('Fuel',6),('Drop',6)):
            assert prefix+name+'='+str(round(item[name.upper()],digits)) in text
    # Single-engine snapshots must index that same engine as first and last.
    snapshot=source[source.index('LOCAL firstEngine IS'):source.index('SET policy["DIAGNOSTIC"]')]
    one=local['stack']['STAGES'][-1]
    local['stack']=dict(local['stack'],STAGES=KList([one]))
    run(snapshot,local)
    assert 'stages=1' in local['diagnostic']
    assert 'firstThrust='+str(round(one['THRUST'],4)) in local['diagnostic']
    assert 'lastThrust='+str(round(one['THRUST'],4)) in local['diagnostic']
    print('PASS: actual full forecast diagnostic serializes bias/lead and both engine fuel/thrust/exhaust/drop snapshots, stays below1800bytes, and handles a single engine without an invalid index')


if __name__=='__main__':
    check_reported_bias_conflict(True)
    check_reported_bias_conflict(False)
    check_timing_and_fuel()
    check_vertical_priority_and_config_scope()
    check_diagnostic_snapshot()
