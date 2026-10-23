"""Source-expression/order checks, not a kOS flight-control simulation."""
import re
from pathlib import Path
from types import SimpleNamespace as NS
from check_launch_and_staging import body, evaluate
import check_landing_guidance as ks
from check_runtime_contracts import run

ROOT = Path(__file__).resolve().parents[1]
ASCENT = (ROOT / 'lib/ascent.ks').read_text()
PHASES = (ROOT / 'lib/phases.ks').read_text()
ks.SOURCES=ASCENT+'\n'+PHASES+'\n'+ks.SOURCES


def safe_throttle(control, pe=9000, now=20, abort=False, command=.7):
    src = body(ASCENT, '_circSafeThrottle')
    env = dict(control=control, SHIP=NS(PERIAPSIS=pe), TIME=NS(SECONDS=now),
               ABORT=abort, command=command)
    for cond, action in re.findall(r'IF (.*?) \{(.*?)\}', src, re.S):
        if evaluate(cond, **env):
            if 'RETURN 0.' in action:
                return 0
            reason = re.search(r'SET control\["REASON"\] TO "(.*?)"', action)[1]
            control['REASON'] = reason
    return evaluate(src[src.rindex('RETURN ')+7:].strip().removesuffix('.'), **env)


def check_cutoffs():
    fresh = lambda: dict(REASON='', TARGET_PE=9900, DEADLINE=90, APPLIED_DV=0, DV_CAP=100)
    for condition, reason in ((dict(pe=9900), 'parking-periapsis'),
                              (dict(now=90), 'time-limit'), (dict(abort=True), 'abort')):
        control = fresh()
        assert safe_throttle(control, **condition) == 0
        assert control['REASON'] == reason
        # A stale nonzero command or a later change in Pe cannot restart thrust.
        assert safe_throttle(control, pe=8000, now=30, command=1) == 0
    control = fresh()
    control['APPLIED_DV'] = 100
    assert safe_throttle(control) == 0 and control['REASON'] == 'dv-limit'
    assert safe_throttle(fresh(), command=2) == 1
    assert safe_throttle(fresh(), command=-1) == 0
    assert safe_throttle(fresh(), command=.03) == .03
    stop = body(ASCENT, '_ascentStopThrottle')
    assert 'RETURN thrustCutoffOk(releaseLock).' in stop
    circ = body(ASCENT, '_ascentCircularize')
    assert 'LOCK THROTTLE TO _circSafeThrottle(throt, control).' in circ
    loop = circ[circ.index('UNTIL ABORT OR appliedDv'):circ.index('IF control["REASON"] = ""')]
    assert 'mLog(' not in loop and 'mLogWarn(' not in loop
    assert 'LOCK THROTTLE TO throt.' not in circ
    assert circ.index('IF NOT _ascentStopThrottle()', circ.index('SET throt TO 0.')) < circ.index('FOR traceLine IN burnTrace')
    taper = re.search(r'SET throt TO (MIN\(1, remDv.*?\))\.', circ)[1]
    for acceleration in (.2, 4, 100):
        for dt in (.02, .2, 2):
            throttle = evaluate(taper, remDv=.31, currentAcc=acceleration, dt=dt)
            assert 0 < throttle <= 1
            assert throttle*acceleration*dt <= .31 + 1e-9
    deorbit = (ROOT / 'lib/deorbit_burn.ks').read_text()
    assert 'LOCAL stopped IS vesselLandingCleanup().' in deorbit
    assert 'LOCAL success IS stopped AND NOT ABORT' in deorbit
    print('PASS: latched parking/abort/time/dV cutoffs, no throttle floor, zero reaches physics before unlock/logging')


def check_preview():
    src = (ROOT / 'lib/return_escape.ks').read_text()
    preview = body(src, 'previewReturnEscape')
    assert preview.index('IF HASNODE') < preview.index('_planReturnEscape(')
    assert 'SET ESCAPE_KSC_TARGET TO 0.' in preview
    assert all(term not in preview for term in ('executeManeuver(', 'nextPhase(', 'stateSet(', 'REBOOT.', 'REMOVE '))
    command = (ROOT / 'cmd/returncheck.ks').read_text()
    assert 'bootPreamble().' in command and 'bootLibLoad("return_escape").' in command
    assert 'previewReturnEscape(53000).' in command
    entry = body(src, '_returnEscapeEntryValid')
    expr = entry[entry.index('RETURN ')+7:].strip().removesuffix('.')
    for pe, expected in ((52000,True),(53000,True),(54000,True),(51999,False),
                         (54001,False),(-1000,False),(22050000,False)):
        assert evaluate(expr, predictedPe=pe, targetPe=53000, RETURN_ESCAPE_PE_TOLERANCE=1000) == expected
    phase = body(src, 'phaseEscape')
    guard = phase.index('IF ABORT OR NOT _returnEscapeEntryValid(')
    execute = phase.index('SET success TO executeManeuver().')
    assert guard < execute and 'yieldToPrompt().' in phase[guard:execute]
    assert 'nd:DELTAV:MAG > SHIP:DELTAV:VACUUM' in phase[guard:execute]
    assert 'RETURN.' in phase[guard:execute]
    print('PASS: return preview preserves phase/existing nodes and never executes a burn')
    print('PASS: 22,050 km Pe rejected; automatic execution holds outside entry corridor or fuel budget')


def check_circularize_wait():
    source=body(ASCENT,'_ascentWaitForCircularize').replace(
        'WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
    for kind in ('normal','reboot-reuse','abort','already-raised','no-kac','imminent','past'):
        events=[];alarms={};serial=[0]
        start=1000;ignite=start+(30 if kind=='imminent' else -1 if kind=='past' else 1000)
        ship=NS(NAME='RO9',PERIAPSIS=8103)
        env=dict(TIME=NS(SECONDS=start),SHIP=ship,ABORT=False,WARP=0,
                 ADDONS=NS(KAC=NS(AVAILABLE=kind!='no-kac')),igniteUt=ignite,dv=1.7,targetPe=9900,
                 YELLOW=0,HUDTEXT=lambda *_:None,ROUND=lambda value,*args:str(round(value,*args)))
        # An unrelated alarm is deliberately present; the coast must own its
        # protection, and cleanup must leave this other mission alarm alone.
        alarms['other']=NS(ID='other',NAME='RO9: Other event',TIME=9999,ACTION='KillWarp')
        def add(kind_,ut,name,note):
            serial[0]+=1
            alarm=NS(ID=str(serial[0]),NAME=name,TIME=ut,ACTION='')
            alarms[alarm.ID]=alarm;events.append(('create',ut))
            return alarm
        def delete(key):
            events.append(('delete',key));alarms.pop(key,None)
        def coast(end,label,key):
            assert key!='other' and key in alarms
            assert end==ignite-60 and alarms[key].TIME==end
            assert alarms[key].ACTION=='KillWarp'
            events.append(('warp',key));env['WARP']=3
            return True
        def settle():
            assert env['WARP']==0
            events.append(('settle',env['TIME'].SECONDS))
        def wait(dt):
            env['TIME'].SECONDS+=dt*(10 if env['WARP'] else 1)
            if env['TIME'].SECONDS>=ignite-60:env['WARP']=0 # KAC KillWarp.
            if kind=='abort' and env['TIME'].SECONDS>=1010:env['ABORT']=True
            if kind=='already-raised' and env['TIME'].SECONDS>=1010:ship.PERIAPSIS=9900
        env.update(ADDALARM=add,DELETEALARM=delete,LISTALARMS=lambda _:list(alarms.values()),
                   coastAutoWarp=coast,fixture_settle=settle,fixture_wait=wait)
        for name in ('maneuverEnsureBurnAlarm','kacEnsureAlarm','kacShipAlarmName','_circHudInterval'):
            env[name]=lambda *args,name=name:ks.call(name,env,*args)
        if kind=='reboot-reuse':env['maneuverEnsureBurnAlarm'](ignite,1.7,'Ascent circularize')
        result=run(source,env)
        assert result==(kind!='abort') and env['WARP']==0
        assert set(alarms)=={'other'}
        long=kind not in ('no-kac','imminent','past')
        assert len([e for e in events if e[0]=='create'])==int(long)
        assert len([e for e in events if e[0]=='warp'])==int(long)
        if kind not in ('abort','already-raised','past'):assert ignite<=env['TIME'].SECONDS<ignite+.51
        assert events[-1][0]==('delete' if long else 'settle')
    circ=body(ASCENT,'_ascentCircularize')
    assert circ.index('_ascentWaitForCircularize(igniteUt,dv,targetPe)')<circ.index('LOCK THROTTLE TO _circSafeThrottle')
    assert 'coastAutoWarp(igniteUt, "Circularize coast", "")' not in circ
    print('PASS: direct circularization owns a reusable T-60 KillWarp alarm, leaves unrelated alarms intact, keeps a clock fallback without KAC, and settles warp on ignition/Abort/early target completion before any burn lock')


def check_ascent_stage_trace():
    class Rows(list):
        ADD=list.append
    class StageNumber(int):
        # Native KerboScript concatenates scalars with strings.
        def __radd__(self,other):return str(other)+str(int(self))
    env=dict(SHIP=NS(AVAILABLETHRUST=12,MASS=4,BODY=NS(MU=6.5138398e10,RADIUS=200000),
                    ALTITUDE=5000,APOAPSIS=10673,VELOCITY=NS(ORBIT=NS(MAG=400)),
                    VERTICALSPEED=30,DELTAV=NS(VACUUM=900)),
             ALT=NS(RADAR=500),STAGE=NS(NUMBER=StageNumber(2)),pitchAngle=30,
             ROUND=lambda value,*args:str(round(value,*args)),trace=dict(STAGE=-999,ROWS=Rows()))
    sample=body(ASCENT,'_logVacuumAscentTelemetry')
    run(sample,env);run(sample,env)
    assert len(env['trace']['ROWS'])==1 and 'stage=2' in env['trace']['ROWS'][0]
    env['STAGE'].NUMBER=StageNumber(1)
    env['SHIP'].AVAILABLETHRUST=0
    run(sample,env)
    assert len(env['trace']['ROWS'])==1 # Separation/ignition is not the new TWR.
    env['SHIP'].AVAILABLETHRUST=8;env['SHIP'].MASS=1
    env['SHIP'].DELTAV.VACUUM=654
    run(sample,env)
    assert len(env['trace']['ROWS'])==2 and 'stage=1' in env['trace']['ROWS'][1]
    assert 'acc=3.0' in env['trace']['ROWS'][0] and 'acc=8.0' in env['trace']['ROWS'][1]
    climb=body(ASCENT,'ascentAirlessToOrbit')
    assert climb.index('IF NOT _ascentStopThrottle(FALSE)')<climb.index('FOR row IN ascentTrace["ROWS"]')
    assert 'trace["ROWS"]:ADD("STATS ascent stage " + row)' in sample
    assert 'mLog("STATS ' not in sample
    print('PASS: stage observations measure changing live acceleration/TWR and fuel, retain one sample per observed stage and persist only after verified ascent cutoff; pitch control remains unchanged')


if __name__ == '__main__':
    check_cutoffs()
    check_circularize_wait()
    check_ascent_stage_trace()
    check_preview()
