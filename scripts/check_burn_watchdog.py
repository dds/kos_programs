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


def check_cpu_budget_recovery():
    executor=body(SOURCE,'executeManeuver')
    setup=executor[executor.index('LOCAL priorIpu IS CONFIG:IPU.'):executor.index('LOCAL throttleCmd IS')]
    cleanup=executor[executor.index('SET CONFIG:IPU TO priorIpu.'):executor.index('// Compact evidence')]
    boot=(ks.ROOT/'lib/boot_lib.ks').read_text()
    recovery=ks.parse(body(boot,'bootPreamble'))
    retry=(ks.ROOT/'cmd/transferretry.ks').read_text()
    assert retry.index('bootPreamble().')<retry.index('stateRemovePrefix("burn_")')
    assert setup.index('stateSet("burn_prior_ipu"')<setup.index('SET CONFIG:IPU')
    assert executor.index('SET CONFIG:IPU TO MIN')<executor.index('LOCK THROTTLE TO _burnNodeThrottle')
    zero=executor.rindex('LOCK THROTTLE TO 0.0.')
    release=executor.index('UNLOCK THROTTLE.',zero)
    assert release<executor.index('SET CONFIG:IPU TO priorIpu.')<executor.index('stateSet("last_burn_report"')
    # Every terminal burn result reaches the common physical cutoff and
    # restoration. Early alignment/window refusals occur before the boost.
    running=executor[executor.index('LOCAL priorIpu'):release]
    assert 'RETURN ' not in running
    for initial,floor,expected in ((150,2000,2000),(500,2000,2000),
                                   (2000,2000,2000),(150,3000,2000)):
        saved={}
        loaded=[]
        env=ks.environment()
        env.update(CONFIG=NS(IPU=initial),BURN_MIN_IPU=floor,
                   stateSet=lambda key,value: saved.update({key:value}),
                   stateRemove=lambda key: saved.pop(key,None),
                   stateGetNum=lambda key,default: saved.get(key,default),
                   bootLibLoad=loaded.append)
        ks.run(ks.parse(setup),env)
        assert env['CONFIG'].IPU==expected
        assert saved==({'burn_prior_ipu':initial} if initial<expected else {})
        # Normal cutoff restores without changing any watchdog thresholds.
        ks.run(ks.parse(cleanup),env)
        assert env['CONFIG'].IPU==initial and not saved
        # Simulate a crash/reboot before common cutoff, then an ordinary
        # command invocation. Both use the actual bootPreamble source.
        ks.run(ks.parse(setup),env)
        ks.run(recovery,env)
        assert env['CONFIG'].IPU==initial and not saved
        ks.run(recovery,env)
        assert env['CONFIG'].IPU==initial and loaded==['core','core']
    print('PASS: scoped CPU budget capped at 2000; normal cutoff and interrupted boot restore original IPU before retry clears state')


def check_passive_cpu_and_probe():
    role=(ks.ROOT/'roles/descent_service.ks').read_text()
    main=body(role,'main')
    standby,separated=main.split('mLog("Descent service separated',1)
    # On one vessel the last CPU to update cooked throttle wins. A standby
    # zero lock actively overwrites the primary; releasing our own lock
    # preserves the primary's ownership. Keep zero after separation.
    assert 'UNLOCK THROTTLE.' in standby
    assert 'LOCK THROTTLE TO' not in standby and 'LOCK STEERING TO' not in standby
    assert 'LOCK THROTTLE TO 0.' in separated and 'LOCK STEERING TO RETROGRADE.' in separated
    probe=(ks.ROOT/'lib/burn_check.ks').read_text()
    command=(ks.ROOT/'cmd/burncheck.ks').read_text()
    assert 'bootLibLoad("maneuver")' in command and 'maneuverThrottleCheck()' in command
    for text in (probe,command,body(SOURCE,'maneuverThrottleCheck')):
        for forbidden in ('LOCK THROTTLE TO','LOCK STEERING TO','STAGE.',
                          ':ACTIVATE','executeManeuver(', 'REMOVE ', 'stateSet(',
                          'PILOTMAINTHROTTLE TO','SET CONFIG:'):
            assert forbidden not in text
    probe_body=body(probe,'_burnCheckMain')
    loop=probe_body[probe_body.index('FOR command IN LIST(0, 1)'):]
    nodes=ks.parse(loop)
    # Printing is not part of the probe computation under test.
    def without_print(items):
        return [(statement,without_print(yes),without_print(no))
                for statement,yes,no in items if not statement.startswith('PRINT ')]
    guards=probe_body[probe_body.index('IF NOT HASNODE'):probe_body.index('LOCAL ignitionVec')]
    for present,dv,vector,exits in ((False,0,0,True),(True,0,1,True),
                                   (True,float('nan'),1,True),(True,float('inf'),1,True),
                                   (True,500,0,True),(True,500,1,False)):
        env=dict(HASNODE=present)
        if present:
            env['NEXTNODE']=NS(DELTAV=NS(MAG=dv),BURNVECTOR=NS(MAG=vector))
        returned=False
        try:
            ks.run(without_print(ks.parse(guards)),env)
        except ks.Returned:
            returned=True
        assert returned==exits, (present,dv,vector)
    for delay in (0,.2,1.1):
        env,_,nd,_=fixture()
        results=[]
        def governor(node,vec,value,cutoff):
            env['TIME'].SECONDS+=delay
            output=ks.call('_burnNodeThrottle',env,node,vec,value,cutoff)
            results.append((value,output,cutoff['reason']))
            return output
        env.update(LIST=lambda *xs: list(xs),nd=nd,bdv=500,fixed=False,
                   ignitionVec=ks.Vec((1,0,0)),governorFn=NS(CALL=governor))
        ks.run(without_print(nodes),env)
        assert results[0]==(0,0,'')
        assert results[1][0]==1
        assert (results[1][1]>0)==(delay<=1)
        assert results[1][2]==('live-command-stale' if delay>1 else '')
        assert env['SHIP'].CONTROL.PILOTMAINTHROTTLE==1
    print('PASS: passive service CPU; probe safely returns for missing/invalid nodes and distinguishes stale-command gate')


if __name__=='__main__':
    check_frozen_node()
    check_heartbeat_abort_staging()
    check_physical_cutoff()
    check_command_publication()
    check_cpu_budget_recovery()
    check_passive_cpu_and_probe()
