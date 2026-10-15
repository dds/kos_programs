"""Source-driven independent cutoff fixtures; not the kOS scheduler or KSP.
Run: python3 -B scripts/check_burn_watchdog.py
"""
import math
from types import SimpleNamespace as NS
import check_landing_guidance as ks
from check_launch_and_staging import body

SOURCE=(ks.ROOT/'lib/maneuver.ks').read_text()
ks.SOURCES+='\n'+SOURCE


def fixture(fixed=False,cap=100,acc=10):
    env=ks.environment()
    ship=NS(THRUST=0,MASS=1,FACING=NS(FOREVECTOR=ks.Vec((1,0,0))),
            CONTROL=NS(PILOTMAINTHROTTLE=1))
    env.update(SHIP=ship,ABORT=False,_nf=math.isfinite,_sma=lambda: acc,
               LEX=lambda *xs: dict(zip(xs[::2],xs[1::2])))
    for name in ('_burnImpulseThrottle',):
        env[name]=lambda *args,name=name: ks.call(name,env,*args)
    control=dict(reason='',rem=-1,time=0,lastTick=0,tickDt=.02,output=0,
                 bestRem=-1,fixed=fixed,heartbeat=0,impulseTime=0,
                 impulse=0,lastAcc=0,impulseCap=cap)
    nd=NS(DELTAV=ks.Vec((500,0,0)))  # Deliberately frozen residual.
    def command(value):
        return ks.call('_burnNodeThrottle',env,nd,ks.Vec((1,0,0)),value,control)
    return env,control,nd,command


def check_frozen_node():
    for fixed in (False,True):
        env,control,nd,command=fixture(fixed)
        delivered=0
        dt=.02
        previous=0
        for i in range(3000):
            env['TIME'].SECONDS=i*dt
            control['heartbeat']=i*dt
            env['SHIP'].THRUST=previous*10
            delivered+=env['SHIP'].THRUST*dt
            previous=command(1)
            if control['reason']: break
        assert control['reason']=='live-impulse-limit'
        assert 99.9<=delivered<=100.02, delivered
        nd.DELTAV=ks.Vec((600,0,0))
        assert command(1)==0
        print(f'PASS: frozen node, fixed={fixed}: independent cutoff at {delivered:.4f} m/s')


def check_heartbeat_abort_staging():
    for fixed in (False,True):
        env,control,nd,command=fixture(fixed)
        assert command(1)>0
        env['TIME'].SECONDS=1.02
        env['SHIP'].THRUST=10
        assert command(1)==0 and control['reason']=='live-command-stale'
        control['heartbeat']=1.02
        assert command(1)==0
        env,control,nd,command=fixture(fixed)
        env['ABORT']=True
        assert command(1)==0 and control['reason']=='live-operator-abort'
        env,control,nd,command=fixture(fixed)
        env['SHIP'].THRUST=float('nan')
        assert command(1)==0 and control['reason']=='live-thrust-invalid'
    env,control,nd,command=fixture()
    # Intentional zero-throttle staging is allowed to take longer than the
    # heartbeat timeout, while the impulse budget survives the engine change.
    control.update(impulse=30,lastAcc=0)
    env['TIME'].SECONDS=30
    assert command(0)==0 and not control['reason'] and control['impulse']==30
    env['_sma']=lambda: 2
    env['SHIP'].MASS=2
    control['heartbeat']=30
    assert command(1)>0
    env['TIME'].SECONDS=30.02
    env['SHIP'].THRUST=4
    command(1)
    assert 30<control['impulse']<30.1
    # Multiple lock evaluations at the same UT must not invent impulse.
    before=control['impulse']
    command(1)
    assert control['impulse']==before
    print('PASS: stale-loop and ABORT latch in both modes; invalid thrust; staging preserves impulse; same-UT sampling')


def check_physical_cutoff():
    for stuck,shutdown_works in ((False,True),(True,True),(True,False)):
        env,_,_,_=fixture()
        events=[]
        env['SHIP'].THRUST=10
        eng=NS(IGNITION=True,THRUST=10,THROTTLELOCK=False,ALLOWSHUTDOWN=True)
        def shutdown():
            events.append('shutdown')
            if shutdown_works:
                env['SHIP'].THRUST=0
                eng.THRUST=0
        eng.SHUTDOWN=shutdown
        env['SHIP'].ENGINES=[eng]
        def wait(seconds):
            env['TIME'].SECONDS+=seconds
            if not stuck:
                env['SHIP'].THRUST=0
                eng.THRUST=0
        env.update(fixture_wait=wait,fixture_lock=lambda statement: events.append(statement))
        result=ks.call('_burnVerifyCutoff',env)
        assert result['forced']==stuck
        assert result['stopped']==(not stuck or shutdown_works)
        assert events.count('shutdown')==int(stuck)
        assert env['SHIP'].CONTROL.PILOTMAINTHROTTLE==0
        assert env['TIME'].SECONDS<=1.03
    executor=body(SOURCE,'executeManeuver')
    assert 'LOCK THROTTLE TO throttleCmd.' not in executor
    zero=executor.rindex('LOCK THROTTLE TO 0.0.')
    assert zero<executor.index('_burnVerifyCutoff()',zero)<executor.index('UNLOCK THROTTLE.',zero)
    assert executor.index('UNLOCK THROTTLE.',zero)<executor.index('stateSet("last_burn_report"')
    assert 'last_burn_report' not in body(SOURCE,'_cpb')
    for name in ('_burnNodeThrottle','_burnImpulseThrottle'):
        code=body(SOURCE,name)
        assert all(word not in code for word in ('WAIT ', 'mLog(', 'stateSet(', 'SHUTDOWN'))
    print('PASS: verified normal stop; forced engine shutdown; persistent-thrust failure; control cleanup precedes saved report')


def check_command_publication():
    executor=body(SOURCE,'executeManeuver')
    publish=executor.split('ELSE IF rem > BURN_TRIM_ABS_COMPLETE_DV {',1)[1].split('} ELSE {',1)[0]
    # Interrupt the actual publication statements after each operation, as
    # the cooked-control trigger can do. The old code exposed positive
    # throttle while its heartbeat was still from before a long zero hold.
    for fixed in (False, True):
        for remaining in (500, 1):
            env,control,_,command=fixture(fixed)
            env['TIME'].SECONDS=30
            env.update(throttleCmd=0,liveCutoff=control,dt=0,ma=10,rem=remaining)
            assert command(0)==0 and not control['reason']
            for statement in ks.parse(publish):
                ks.run([statement],env)
                command(env['throttleCmd'])
                assert not control['reason'], (fixed,remaining,statement[0],control)
                env['TIME'].SECONDS+=.02
            assert env['throttleCmd']>0 and control['output']>0
            env['TIME'].SECONDS+=1.1
            assert command(env['throttleCmd'])==0
            assert control['reason']=='live-command-stale'
    print('PASS: interleaved ignition/recovery publication starts both modes; genuine stale commands still latch off')


if __name__=='__main__':
    check_frozen_node()
    check_heartbeat_abort_staging()
    check_physical_cutoff()
    check_command_publication()
