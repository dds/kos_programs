"""Execute SOI/retry alarm source with a fake KAC store; no KSP/KAC runner."""
import math
from types import SimpleNamespace as NS

import check_landing_guidance as ks
import check_midcourse as mid
from check_codebase import ROOT, function_body
from check_runtime_contracts import KList, run

SOURCE=(ROOT/'lib/orbit.ks').read_text()+'\n'+mid.SOURCE
SOURCE=SOURCE.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
ks.SOURCES=SOURCE+'\n'+ks.SOURCES


def fixture():
    env,saved,events,_,moon,hit=mid.retry_environment()
    alarms={}
    env['SHIP'].NAME='RO9'
    env['SHIP'].ORBIT.BODY=env['SHIP'].BODY
    serial=[0]
    def create(kind,ut,name,note):
        serial[0]+=1
        alarm=NS(ID='alarm-'+str(serial[0]),TIME=ut,NAME=name,NOTES=note,ACTION='')
        alarms[alarm.ID]=alarm
        events.append(('created',name,ut))
        return alarm
    def delete(key):
        alarm=alarms.pop(key,None)
        if alarm:events.append(('deleted',alarm.NAME))
    env.update(ADDALARM=create,DELETEALARM=delete,LISTALARMS=lambda _:list(alarms.values()))
    for name in ('kacShipAlarmName','kacEnsureAlarm','ensureSoiAlarm',
                 '_bplaneEnsureSoiAlarm','waitUntilOrSOI','waitForSOI'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    return env,saved,events,alarms,moon,hit


def named(alarms,name):
    matches=[alarm for alarm in alarms.values() if alarm.NAME=='RO9: '+name]
    assert len(matches)==1,(name,matches)
    return matches[0]


def check_soi_reuse_and_stale_cache():
    env,saved,_,alarms,moon,_=fixture()
    first=env['ensureSoiAlarm'](moon,11000)
    assert env['ensureSoiAlarm'](moon,11000)==first and len(alarms)==1
    for key in ('soi_alarm_id','soi_alarm_ut','soi_alarm_target'):saved.pop(key)
    assert env['ensureSoiAlarm'](moon,11000)==first and len(alarms)==1
    shifted=env['ensureSoiAlarm'](moon,12000)
    assert shifted!=first and first not in alarms and len(alarms)==1
    assert named(alarms,'SOI: Mun').TIME==12000 and alarms[shifted].ACTION=='KillWarp'
    for actual_time in (999,2000):
        # The saved timestamp can look fresh while the actual KAC alarm is
        # expired or points elsewhere. The old fast path accepted both.
        alarms[shifted].TIME=actual_time
        saved['soi_alarm_ut']=1001
        next_id=env['ensureSoiAlarm'](moon,1002)
        assert next_id!=shifted and shifted not in alarms and len(alarms)==1
        assert alarms[next_id].TIME==1002 and alarms[next_id].ACTION=='KillWarp'
        shifted=next_id
    for invalid in (0,999,math.nan,math.inf):
        assert env['ensureSoiAlarm'](moon,invalid)=='' and len(alarms)==1
    print('PASS: actual SOI alarm reuses across reboot/cache loss, replaces retimed/expired/mis-timed entries, rejects invalid epochs and creates KillWarp alarms')


def check_midpoint_and_final_alarm_independence():
    env,saved,_,alarms,moon,hit=fixture()
    run(function_body(SOURCE,'phaseBplane'),env)
    assert saved['phase']=='COAST_1HALF'
    soi_id=named(alarms,'SOI: Mun').ID
    def enter_midpoint(label,orient,health,deadline):
        assert named(alarms,'SOI: Mun').ID==soi_id
        assert named(alarms,'Midcourse refine: Mun').TIME==deadline
        return 1
    env['enterSolarCoast']=enter_midpoint
    ks.call('phaseCoast1Half',env)
    assert saved['phase']=='REFINE_BPLANE' and len(alarms)==1
    assert named(alarms,'SOI: Mun').ID==soi_id
    def enter_final(label,orient,health,deadline):
        assert named(alarms,'SOI: Mun').TIME==hit['entryUt']
        retry=named(alarms,'B-plane retry: Mun')
        assert retry.TIME==deadline and retry.ID!=soi_id
        return 1
    env['enterSolarCoast']=enter_final
    assert env['_bplaneWaitBeforeSolverRetry'](moon)
    assert env['TIME'].SECONDS==hit['entryUt']-env['BPLANE_FINAL_REFINE_LEAD']
    assert len(alarms)==1 and named(alarms,'SOI: Mun').ID==soi_id
    assert saved['soi_alarm_id']==soi_id and not saved['bplane_retry_wait']['waiting']
    env['bplaneClearRetryWait']()
    assert named(alarms,'SOI: Mun').ID==soi_id
    # The coast must also install the alarm when no B-plane-created alarm
    # survived, for example after a deleted alarm or a different boot path.
    env,saved,_,alarms,moon,hit=fixture()
    saved['phase']='COAST_1HALF'
    def standalone_midpoint(*_):
        assert named(alarms,'SOI: Mun').TIME==11000
        assert named(alarms,'Midcourse refine: Mun').TIME==6000
        return 1
    env['enterSolarCoast']=standalone_midpoint
    ks.call('phaseCoast1Half',env)
    assert saved['phase']=='REFINE_BPLANE' and len(alarms)==1
    assert named(alarms,'SOI: Mun').TIME==11000
    print('PASS: real phase/clock source creates SOI before midpoint/final solar work; each retry alarm cleans up independently and leaves the future SOI alarm intact')


def check_correction_refreshes_actual_soi():
    for phase in ('phaseBplane','phaseRefineBplane'):
        for success in (True,False):
            env,saved,events,alarms,moon,hit=fixture()
            saved['phase']='BPLANE' if phase=='phaseBplane' else 'REFINE_BPLANE'
            executed=[]
            queries=[]
            def arrival(node,target):
                queries.append(node)
                return hit if node==0 else dict(entryUt=99999,patch=hit['patch'])
            env['findArrivalPatch']=arrival
            env['_bplaneCurrentCorridorOk']=lambda *_:bool(executed)
            env['measureArrival']=lambda *_:dict(pe=15000,inc=89,lan=0)
            env['_bplaneCorridorError']=lambda *_:dict(planeErr=1,peErr=0)
            env['_bplaneCorridorOk']=lambda *_:False
            node=NS(DELTAV=NS(MAG=1))
            env['planBplaneCorrection']=lambda *_:node
            env['bplaneCorrectionAllowed']=lambda *_:True
            env['_bplaneReserveCorrection']=lambda *_:None
            env['_bplaneClearCoastTimes']=lambda:ks.call('_bplaneClearCoastTimes',env)
            def burn():
                assert named(alarms,'SOI: Mun').TIME==11000
                executed.append(True)
                hit['entryUt']=12345  # Actual orbit after successful/partial burn.
                return success
            env['_bplaneExecuteCorrection']=burn
            env['bplaneArrivalStatus']=lambda:None
            env['_bplaneHoldCorrection']=lambda reason,*_:events.append(('held',reason))
            run(function_body(SOURCE,phase),env)
            assert executed==[True] and queries and all(query==0 for query in queries)
            assert len(alarms)==1 and named(alarms,'SOI: Mun').TIME==12345
            assert saved['soi_alarm_ut']==12345 and named(alarms,'SOI: Mun').ACTION=='KillWarp'
            if not success:assert events[-1]==('held','correction-execution-failed')
    print('PASS: both B-plane handlers create an initial SOI alarm and refresh from the actual unburned patch after successful or partial corrections, excluding temporary node predictions')


def check_arrival_coast_consumes_soi_alarm():
    env,saved,_,alarms,moon,hit=fixture()
    saved['phase']='COAST_2HALF'
    env['xferSeq']=KList(('COAST_2HALF','CAPTURE'))
    env.update(PHASES_HAS_SOLAR=False,coastHealthCheck=lambda *_:False,
               orbitSummary=lambda:None)
    env['TIME'].SECONDS=10000
    env['SHIP'].ORBIT.NEXTPATCHETA=1000
    def enter(*_):
        assert named(alarms,'SOI: Mun').TIME==hit['entryUt']
        return 1
    env['enterSolarCoast']=enter
    original_wait=env['fixture_wait']
    def ticking(dt):
        original_wait(dt)
        if env['TIME'].SECONDS>=hit['entryUt']:
            env['SHIP'].BODY=moon
            env['SHIP'].ORBIT.BODY=moon
    env['fixture_wait']=ticking
    ks.call('phaseCoast2Half',env)
    assert env['SHIP'].BODY is moon and saved['phase']=='CAPTURE'
    assert not alarms and all(key not in saved for key in ('soi_alarm_id','soi_alarm_ut','soi_alarm_target'))
    print('PASS: arrival coast installs SOI before solar work, polls through the buffer, reaches the target and clears its alarm/state only after real SOI entry')


def check_optional_kac_and_solar_order():
    env,saved,_,alarms,moon,_=fixture()
    env['ADDONS'].KAC.AVAILABLE=False
    assert env['ensureSoiAlarm'](moon,11000)=='' and not alarms
    env['_bplaneEnsureSoiAlarm'](moon)
    assert not alarms and 'soi_alarm_id' not in saved
    saved['phase']='COAST_1HALF'
    env['enterSolarCoast']=lambda *_:1
    ks.call('phaseCoast1Half',env)
    assert saved['phase']=='REFINE_BPLANE' and not alarms and 'soi_alarm_id' not in saved
    env['ADDONS'].KAC.AVAILABLE=True
    env['findArrivalPatch']=lambda *_:0
    env['_bplaneEnsureSoiAlarm'](moon)
    assert not alarms
    env['SHIP'].BODY=moon
    env['_bplaneEnsureSoiAlarm'](moon)
    assert not alarms
    env,saved,_,alarms,moon,hit=fixture()
    env['TIME'].SECONDS=10000
    env['SHIP'].ORBIT.NEXTPATCHETA=1000
    env['coastHealthCheck']=lambda *_:False
    def solar():
        assert named(alarms,'SOI: Mun').TIME==11000
        return True
    env['orientForSolar']=solar
    original_wait=env['fixture_wait']
    def ticking(dt):
        original_wait(dt)
        if env['TIME'].SECONDS>=hit['entryUt']:
            env['SHIP'].BODY=moon
            env['SHIP'].ORBIT.BODY=moon
    env['fixture_wait']=ticking
    ks.call('waitForSOI',env,moon)
    assert env['SHIP'].BODY is moon and not alarms and 'soi_alarm_id' not in saved
    print('PASS: missing KAC/encounter or already-entered target cannot invent an alarm; standalone SOI waits install the alarm before solar orientation')


if __name__=='__main__':
    check_soi_reuse_and_stale_cache()
    check_midpoint_and_final_alarm_independence()
    check_correction_refreshes_actual_soi()
    check_arrival_coast_consumes_soi_alarm()
    check_optional_kac_and_solar_order()
