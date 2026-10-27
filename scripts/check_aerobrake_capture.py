"""Emergency capture against independent point-mass physics, not native KSP."""
import math

import check_landing_guidance as ks
from check_aerobrake_assist import fixture, AERO
from check_codebase import function_body


def capture_fixture(turn=math.inf):
    env,sim,data,refresh=fixture(before_entry=60,thrust=55)
    # Reflect the incoming ellipse into an outbound pass, then increase
    # speed beyond escape. The production helpers read the resulting orbit.
    sim['pos'][1]*=-1;sim['vel'][0]*=-1
    sim['vel']=[speed*1.05 for speed in sim['vel']];refresh()
    assert env['SHIP'].ORBIT.ECCENTRICITY>1 and env['SHIP'].ALTITUDE>70000
    env['STAGE'].LIQUIDFUEL=env['STAGE'].OXIDIZER=100
    env.update(AEROBRAKE_BRAKE_PE_FLOOR=28000,_aerobrakeAtmoHeight=lambda:70000,
               yieldToPrompt=lambda:env.update(phaseShouldYield=True))
    for name in ('_aerobrakeCaptureStop','_aerobrakeCaptureThrottle'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    sim['turn_rate']=turn
    if not math.isinf(turn):env['SHIP'].FACING.FOREVECTOR=env['SHIP'].VELOCITY.ORBIT.NORMALIZED
    return env,sim,data


def run(env):
    source=function_body(AERO,'_aerobrakeBrakingBurn')
    source=source.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','').replace('SAS OFF.','SET SAS TO FALSE.')
    try:ks.run(ks.parse(source),env)
    except ks.Returned as result:return result.value


def check_capture_alignment():
    for turn in (math.inf,20,0):
        env,sim,data=capture_fixture(turn)
        assert bool(run(env))==(turn!=0)
        assert env['SHIP'].THRUST==0 and not data['aerobrake_capture_active']
        assert env['CONFIG'].IPU==150 and env['LOG_ARCHIVE_DEFERRED']==0
        if turn==0:
            assert sim['actual_dv']==0 and env['phaseShouldYield']
        else:
            assert env['SHIP'].ORBIT.ECCENTRICITY<1 and 100<sim['actual_dv']<150
            if turn==20:
                assert min(ut for ut,thrust in sim['thrust_history'] if thrust>0)>8
    print('PASS: outbound hyperbola captures with ideal/finite slew;180deg rotation consumes no burn fuel before alignment; immobile attitude times out at zero thrust and all successful cutoffs restore CPU/log policy')


def check_capture_latched_guards():
    for fault in ('abort','hold','node','stage','body','stale','deadline','fuel','pe','landed','warp','angle','invalid-orbit'):
        env,sim,_=capture_fixture()
        control=dict(REASON='',UPDATED=0,DEADLINE=1000,BODY='Kerbin',STAGE=1,
            DIR=-env['SHIP'].VELOCITY.ORBIT,FLOOR=28000,ATMO=70000,PEAK_FACING_ERR=0)
        env['SHIP'].FACING.FOREVECTOR=control['DIR'].NORMALIZED
        if fault=='abort':env['ABORT']=True
        if fault=='hold':env['phaseShouldYield']=True
        if fault=='node':env['HASNODE']=True
        if fault=='stage':env['STAGE'].NUMBER=0
        if fault=='body':env['SHIP'].BODY.NAME='Mun'
        if fault=='stale':env['TIME'].SECONDS=1
        if fault=='deadline':control['DEADLINE']=0
        if fault=='fuel':env['STAGE'].LIQUIDFUEL=env['STAGE'].OXIDIZER=0
        if fault=='pe':env['SHIP'].PERIAPSIS=27999
        if fault=='landed':env['SHIP'].STATUS='LANDED'
        if fault=='warp':env['WARP']=1
        if fault=='angle':env['SHIP'].FACING.FOREVECTOR=-control['DIR'].NORMALIZED
        if fault=='invalid-orbit':env['SHIP'].ORBIT.ECCENTRICITY=math.nan
        assert env['_aerobrakeCaptureThrottle'](1,control)==0 and control['REASON'],fault
        # A restored attitude/context cannot erase a latched stop.
        env['ABORT']=False;env['HASNODE']=False;control['UPDATED']=env['TIME'].SECONDS
        assert env['_aerobrakeCaptureThrottle'](1,control)==0
    print('PASS: capture throttle lock independently latches Abort/hold/node/stage/body/freshness/deadline/fuel/Pe/landing/warp/alignment/invalid-orbit failures at zero')


if __name__=='__main__':
    check_capture_alignment()
    check_capture_latched_guards()
