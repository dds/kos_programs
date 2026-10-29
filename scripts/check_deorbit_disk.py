"""Execute disk-selection/reserve policy with the reported8.8KiB budget."""
import re
from types import SimpleNamespace as NS

from check_codebase import ROOT,function_body
from check_aerobrake_reentry import execute

LOG=(ROOT/'lib/logs.ks').read_text()
DEORBIT=(ROOT/'lib/deorbit_targeting.ks').read_text()


class Text(str):
    def __add__(self,other):return Text(str(self)+str(other))
    def __radd__(self,other):return Text(str(other)+str(self))
    LENGTH=property(len)
    STARTSWITH=str.startswith
    def SUBSTRING(self,start,count):return Text(self[start:start+count])


def fixture(free=8797,verbose=0,deferred=0):
    disk,console,archives=[],[],[]
    volume=NS(FREESPACE=free)
    env=dict(CORE=NS(VOLUME=volume),LOG_INFO_TO_FILE=verbose,LOG_ARCHIVE_DEFERRED=deferred,
        LOG_FILE_RESERVE_BYTES=1024,LOG_INFO_RESERVE_BYTES=4096,
        _logSpaceWarned=False,_logInfoSpaceWarned=False,
        HOMECONNECTION=NS(ISCONNECTED=True),_fmtTime=lambda:Text('4915549.0'),
        archiveLog=lambda:archives.append(len(disk)),fixture_console=console.append)
    source=function_body(LOG,'mLog').replace('PRINT line.','fixture_console(line).')
    source=source.replace('LOG line TO flightLogPath().','fixture_write(line).')
    def write(line):
        assert volume.FREESPACE>1024+len(line)+100
        disk.append(line);volume.FREESPACE-=len(line)+2
    env['fixture_write']=write
    def log(message,level='INFO'):
        execute(source,dict(env,message=Text(message),level=Text(level)))
    env.update(mLog=log,mLogDetail=lambda msg:log(msg,'DETAIL'),mLogSummary=lambda msg:log(msg,'SUMMARY'))
    return env,disk,console,archives


def check_rank_and_forecast_budget():
    env,disk,console,archives=fixture()
    env['mLog']('STATS phase entry phase=LAND_DEORBIT body=Mun PeKm=14 ApKm=15.1 inc=14.94 free=8797')
    # Execute the source classification, not an independently copied rank cap.
    match=re.search(r'IF ordered:LENGTH <= 3 \{ mLog\(rankLine\)\. \}\s*ELSE \{ mLogDetail\(rankLine\)\. \}',DEORBIT)
    assert match
    for rank in range(1,49):
        message=f'STATS deorbit fixed-pass rank={rank} passUT=5040291.81619251 eta=124731.448779955 unburnedMissKm=0.528049451813737'
        execute(match[0].replace("mLogDetail(","recordDetail(").replace("mLog(","recordInfo("),
                dict(env,ordered=NS(LENGTH=rank),rankLine=message,recordDetail=env["mLogDetail"],recordInfo=env["mLog"]))
    for index in range(12):
        env['mLogDetail']('STATS deorbit step '+('native-derivative-detail '*15))
        env['mLogDetail']('STATS deorbit powered-lead '+('forecast-detail '*80))
        env['mLog'](f'STATS deorbit powered-summary aimM=51903 rangeM=13696 height=3588 captureDownfield=-638 captureCross=0 toleranceM=500 impulseDv=637.3 pass={index}')
    env['mLog']('STATS deorbit pass-survey complete samples=3635 ranked=48 nativeTrials=0 elapsedSec=12.3')
    summary='STATS deorbit result=hold reason=powered-lead-not-converged trials=63/64 stop=no-improving-step downfieldM=51265 aimM=51903 residualM=-638 toleranceM=500 crossM=0'
    env['mLog'](summary,'WARN')
    env['mLogSummary']('STATS deorbit powered-lead '+('last-validated-model-detail '*45))
    env['mLog']('Landing deorbit planning or execution failed; holding for manual review.','ERROR')
    assert len([line for line in disk if 'fixed-pass rank=' in line])==3
    assert len([line for line in console if 'fixed-pass rank=' in line])==48
    assert any(summary in line for line in disk)
    assert len([line for line in disk if 'powered-lead ' in line])==1
    assert any('holding for manual review' in line for line in disk)
    assert env['CORE'].VOLUME.FREESPACE>=1024 and len(archives)==len(disk)
    assert 'mLogDetail("STATS deorbit candidate' in DEORBIT
    print('PASS: actual rank classifier/logger keeps3 of48 ranked rows, all48 on console, compact forecasts and one detailed final model plus hold/error within reported8797 bytes; hard1024-byte reserve preserved')


def check_priority_reserve_and_verbosity():
    env,disk,console,archives=fixture()
    for index in range(200):env['mLog']('STATS routine '+str(index)+' '+('x'*250))
    assert env['CORE'].VOLUME.FREESPACE>=4096
    before=len(disk)
    env['mLogSummary']('STATS final decision '+('y'*1000))
    env['mLog']('critical failure '+('z'*500),'ERROR')
    env['mLog']('=== PHASE: LAND_DEORBIT ===','PHASE')
    assert len(disk)==before+3 and env['CORE'].VOLUME.FREESPACE>=1024
    env,disk,console,archives=fixture(verbose=1,deferred=1)
    env['mLogDetail']('STATS deorbit full operator-requested detail')
    assert disk and console and not archives
    env,disk,_,_=fixture(free=1100)
    env['mLog']('still no room','ERROR')
    assert not disk and env['CORE'].VOLUME.FREESPACE==1100
    print('PASS: routine saturation cannot spend final/error space; critical rows still stop at unchanged hard reserve; explicit verbose detail is recorded, archive deferral remains effective, and low disk never overruns storage')


def check_direct_refit_reserve():
    from check_runtime_contracts import run
    admission=function_body(DEORBIT,'landingDeorbitNodeAccepted')
    policy=admission[admission.index('LOCAL checkLevel IS'):admission.index('    mLog("STATS deorbit retained-node')]
    env,disk,_,_=fixture()
    for full in (False,True):
        scope=dict(emitModelDiagnostic=full)
        run(policy,scope)
        assert scope['checkLevel']==('SUMMARY' if full else 'INFO')
    # Fill routine telemetry to its soft floor, then exercise seven direct
    # samples. They cannot consume the protected final diagnosis allowance.
    for index in range(80):env['mLog']('STATS routine '+str(index)+' '+('x'*300))
    begin=len(disk)
    scope=dict(emitModelDiagnostic=False)
    run(policy,scope)
    for index in range(7):env['mLog']('STATS deorbit retained-node '+('y'*350),scope['checkLevel'])
    assert len(disk)==begin
    env['mLogSummary']('STATS deorbit direct-fit accepted=False '+('z'*200))
    env['mLogSummary']('STATS deorbit powered-lead '+('p'*1700))
    env['mLog']('STATS deorbit result=hold '+('q'*250),'WARN')
    env['mLog']('Landing deorbit failed; holding for review.','ERROR')
    assert len(disk)==begin+4 and env['CORE'].VOLUME.FREESPACE>=1024
    print('PASS: source admission keeps ordinary preburn diagnostics critical but compact planner refits informational; seven samples cannot spend the protected final result/model/error reserve')


if __name__=='__main__':
    check_rank_and_forecast_budget()
    check_priority_reserve_and_verbosity()
    check_direct_refit_reserve()
