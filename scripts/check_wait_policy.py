"""Execute shared coast/warp guards with a fake clock; no native KAC runner."""
from types import SimpleNamespace as NS

import check_midcourse as mid
import check_soi_alarms as soi
from check_codebase import ROOT, function_body
from check_runtime_contracts import run


def check_coast_fallback_and_alarm_ownership():
    for scenario in ('healthy', 'no-owned-alarm', 'disabled', 'failed-health',
                     'declined-warp', 'abort', 'body-change', 'already-due'):
        env, saved, events, alarms, moon, hit = mid.retry_environment()
        # Directly execute the loop so scalar WARP assignments are observable.
        env.update(targetBody=moon, targetUt=1100, pollInterval=10,
                   alarmId='' if scenario=='no-owned-alarm' else 'wake',
                   solarRef=1, checkPreWarpHealth=True, stayInBody=False,
                   WARP=5, COAST_AUTO_WARP=0 if scenario=='disabled' else 1,
                   COAST_AUTO_WARP_MIN=10, COAST_HEALTH_CHECK=1,
                   idealCoastWarpRate=lambda _:1, solarCoastCanWarp=lambda *_:True,
                   coastHealthCheck=lambda *_:scenario!='failed-health')
        alarms.update(wake=(1100, 'owned wake'), soi=(5000, 'independent SOI'))
        def settle():
            assert env['WARP']==0
            events.append(('settled',))
        def warp(ut, label, alarm):
            assert alarm and alarm in alarms
            events.append(('warp', alarm))
            if scenario=='declined-warp':return False
            env['WARP']=2
            return True
        def wait(seconds):
            env['TIME'].SECONDS+=seconds
            if scenario=='abort':env['ABORT']=True
            if scenario=='body-change':env['SHIP'].BODY=moon
        env.update(fixture_settle=settle, fixture_wait=wait, coastAutoWarp=warp,
                   coastEnsureHealthAlarm=lambda ut,label:env['kacEnsureAlarm'](label,ut,'health'))
        if scenario=='already-due':env['TIME'].SECONDS=1100
        run(function_body(mid.SOURCE,'waitUntilOrSOI'),env)
        assert env['WARP']==0 and events[0]==('settled',)
        assert set(alarms)=={'wake','soi'},(scenario,alarms)
        assert bool([e for e in events if e[0]=='warp']) == (scenario in (
            'healthy','declined-warp','abort','body-change'))
        if scenario in ('abort','body-change'):
            assert 1010 <= env['TIME'].SECONDS <= 1011,(scenario,env['TIME'].SECONDS)
        else:assert env['TIME'].SECONDS==1100,(scenario,env['TIME'].SECONDS)
        assert not any(e[0] in ('advance','yield') for e in events)
    print('PASS: coast waits discard inherited warp, require their own wake alarm, clean a declined midpoint alarm, settle on all exits and preserve independent SOI/wake alarms')


def check_expired_alarm_cannot_guard_warp():
    env, _, events, alarms, _, _ = soi.fixture()
    env.update(label='test coast',alarmId='owned')
    alarms['other']=NS(ID='other',TIME=9000)
    for timestamp,available,allowed in ((999,True,False),(1000,True,False),
                                        (1001,True,True),(1001,False,False)):
        alarms['owned']=NS(ID='owned',TIME=timestamp)
        env['ADDONS'].KAC.AVAILABLE=available
        assert run(function_body(mid.PHASES,'warpKacGuarded'),env)==allowed
    env['ADDONS'].KAC.AVAILABLE=True
    alarms.pop('owned')
    assert not run(function_body(mid.PHASES,'warpKacGuarded'),env)
    print('PASS: an expired/missing owned alarm or unavailable KAC cannot authorize warp, even with an unrelated future alarm present')


def check_powered_entry_settles_warp():
    for filename,name,cutoff,last in (
        ('hop','phaseHop','thrustCutoffOk()','LOCAL steeringTarget'),
        ('landing_main','landExecute','SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.','vesselLandingPrepareRoles()')):
        source=function_body((ROOT/'lib'/f'{filename}.ks').read_text(),name)
        assert source.index(cutoff)<source.index('SET WARP TO 0.')<source.index('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.')<source.index(last)
    print('PASS: hop launch and landing guidance enter at verified/commanded zero throttle and settle inherited warp before attitude, staging or powered control')


if __name__=='__main__':
    check_coast_fallback_and_alarm_ownership()
    check_expired_alarm_cannot_guard_warp()
    check_powered_entry_settles_warp()
