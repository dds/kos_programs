"""Execute landing coast/alarm source against a fake KAC store; no KSP VM."""
import math

import check_soi_alarms as soi
from check_codebase import ROOT, function_body


class Context(dict):
    HASKEY = dict.__contains__


def fixture():
    env, _, events, alarms, _, _ = soi.fixture()
    for name in ('_landingCoastAlarm', '_landingClearCoastAlarm'):
        env[name] = lambda *args, name=name: soi.ks.call(name, env, *args)
    return env, events, alarms


def check_lifecycle():
    env, events, alarms = fixture()
    now = env['TIME'].SECONDS
    unrelated = env['ADDALARM']('Raw', now+400, 'Other craft: landing', '')
    soi_alarm = env['kacEnsureAlarm']('SOI: Minmus', now+300, '')
    ctx = Context(HAS_TARGET=True)
    update = env['_landingCoastAlarm']
    update(ctx, 90)
    first = ctx['COAST_ALARM_ID']
    assert alarms[first].TIME == now+90 and alarms[first].ACTION == 'KillWarp'
    assert alarms[first].NAME == 'RO9: Landing braking alignment'
    count = len(events)
    env['TIME'].SECONDS += 1
    update(ctx, 70)
    assert len(events) == count  # No addon scan/create on every guidance tick.
    env['TIME'].SECONDS += 4
    update(ctx, 85)
    assert ctx['COAST_ALARM_ID'] == first and len(events) == count
    env['TIME'].SECONDS += 5
    update(ctx, 50)  # 30 s shift, inside the ordinary helper's 60 s reuse band.
    second = ctx['COAST_ALARM_ID']
    assert second != first and first not in alarms
    assert alarms[second].TIME == env['TIME'].SECONDS+50
    reboot = Context(HAS_TARGET=True)
    update(reboot, 50)
    assert reboot['COAST_ALARM_ID'] == second  # Reboot reuses the owned alarm.
    env['DELETEALARM'](second)
    env['TIME'].SECONDS += 5
    update(reboot, 45)
    assert reboot['COAST_ALARM_ID'] in alarms  # Recover manual alarm deletion.
    update(reboot, 0)
    assert reboot['COAST_ALARM_ID'] == ''
    assert set(alarms) == {unrelated.ID, soi_alarm}
    env['_landingClearCoastAlarm'](reboot)
    assert set(alarms) == {unrelated.ID, soi_alarm}
    print('PASS: landing alarm creates, reuses, retimes within 60 s, survives reboot and recovers deletion; cleanup preserves SOI/other-craft alarms')


def check_fallback_and_wiring():
    env, _, alarms = fixture()
    ctx = Context(HAS_TARGET=False)
    for eta in (-1, 0, 999999, math.nan, math.inf):
        env['_landingCoastAlarm'](ctx, eta)
        assert not alarms
    env['ADDONS'].KAC.AVAILABLE = False
    env['_landingCoastAlarm'](ctx, 90)
    assert not alarms and ctx['COAST_ALARM_UNAVAILABLE']
    env['ADDONS'].KAC.AVAILABLE = True
    env['TIME'].SECONDS += 5
    env['_landingCoastAlarm'](ctx, 85)
    assert alarms[ctx['COAST_ALARM_ID']].NAME == 'RO9: Landing braking burn'
    # Actual COAST exit prefix must release its alarm before entering another track.
    source = (ROOT/'lib/landing_main.ks').read_text()
    prefix = function_body(source, '_landingSetState').split('_landingStateLog(', 1)[0]
    ctx['STATE'] = 'COAST'
    soi.ks.run(soi.ks.parse(prefix), dict(env,ctx=ctx,nextState='BRAKE_ALIGN',reason='fixture'))
    assert not alarms
    coast = function_body((ROOT/'lib/landing_coast.ks').read_text(), '_landingCoastTick')
    assert coast.index('nextBrakeEta - LANDING_BRAKE_ALIGN_LEAD') < coast.index('_landingCoastAlarm(')
    assert coast.index('_landingCoastAlarm(') < coast.index('_landingHudText(')
    main = function_body(source, 'landExecute')
    assert main.index('_landingClearCoastAlarm(ctx).') > main.index('WAIT tickRate.')
    helper = function_body(source, '_landingCoastAlarm')
    assert not any(x in helper for x in ('WAIT ', 'SET WARP', 'orientForSolar(', 'enterSolarCoast('))
    print('PASS: invalid/past ETAs create no alarm; no-KAC keeps resident guidance, recovery works; live COAST exit/finish/abort cleanup is wired without waits, solar or auto-warp')


if __name__ == '__main__':
    check_lifecycle()
    check_fallback_and_wiring()
