"""Interrupted repair -> passive atmospheric attitude; source fixtures, not KSP."""
import re
from types import SimpleNamespace as NS

from check_codebase import ROOT, function_body as uncached_body
from check_aerobrake_assist import fixture, entry_helpers
from check_aerobrake_reentry import execute, alarm_fixture
from functools import lru_cache

function_body=lru_cache(maxsize=32)(uncached_body)
AERO=(ROOT/'lib/aerobrake.ks').read_text()
COMMAND=(ROOT/'cmd/entrynow.ks').read_text()


def context():
    env,sim,data,refresh=fixture(before_entry=42.617)
    alarms,events=alarm_fixture(env)
    env['ADDONS'].TR=NS(AVAILABLE=True)
    data.update(phase='AEROBRAKE',mission_id='return',launch_time=4880796,
        burn_pending='true',burn_started='true',burn_phase='AEROBRAKE',burn_body='Kerbin',
        burn_abort_reason='residual-outside-tolerance',burn_abort_residual=.008181178,
        last_burn_report='historical burn evidence')
    env['maneuverBurnInterrupted']=lambda:data.get('burn_pending')=='true'
    env.update(AEROBRAKE_PE_TARGETING=1,AEROBRAKE_TARGETING=1,AEROBRAKE_AP_BURN=1,
        AEROBRAKE_BRAKE_PE_FLOOR=51000,AEROBRAKE_PE=53000,REENTRY_PE=53000,
        AEROBRAKE_CORRECTION_PE_MIN=52000,AEROBRAKE_CORRECTION_PE_MAX=54000,
        AEROBRAKE_HANDOFF_SPEED=600,label='entry-test',atmHeight=70000,
        targetPe=53000,peLow=52000,peHigh=54000,
        _aerobrakeAtmoHeight=lambda:70000,
        yieldToPrompt=lambda:events.append(('yield',)),
        fixture_wait=lambda dt:env['TIME'].__setattr__('SECONDS',env['TIME'].SECONDS+dt))
    return env,sim,data,events


def check_entry_protection():
    for mode in ('near','inside','prograde','warp','far','other-mission','other-launch','other-body','cutoff','abort'):
        env,sim,data,events=context();before=dict(data)
        env['aerobrakeApEntryEta']=lambda _:42.617 if mode!='far' else 900
        if mode=='inside':env['SHIP'].ALTITUDE=65000
        if mode=='prograde':env['AEROBRAKE_REENTRY_DIR']='PROGRADE'
        if mode=='warp':env['WARP']=4
        if mode=='abort':env['ABORT']=True
        if mode.startswith('other-'):
            data['aerobrake_entry_only']=env['aerobrakeEntryOnlyId']()
            data.pop('burn_pending')
            if mode=='other-mission':data['mission_id']='other'
            if mode=='other-launch':data['launch_time']+=1
            if mode=='other-body':env['SHIP'].BODY.NAME='Duna'
        if mode=='cutoff':env['thrustCutoffOk']=lambda:False
        if mode=='warp':
            source=re.sub(r'WAIT UNTIL [^.]+\.', '',function_body(AERO,'_aerobrakeProtectEntry')).replace('SAS OFF.','SET SAS TO FALSE.')
            accepted=execute(source,env)
            assert env['WARP']==0
        else:accepted=env['_aerobrakeProtectEntry']()
        assert bool(accepted)==(mode not in ('cutoff','abort')),mode
        if mode in ('near','inside','prograde','warp'):
            assert env['aerobrakeEntryOnly']()
            assert sim['steering']=='_aerobrakeEntryDirection()'
            assert env['AEROBRAKE_REENTRY_DIR']==('PROGRADE' if mode=='prograde' else 'RETROGRADE')
            assert all(data[k]==value for k,value in before.items())
            # Real correction/capture/separation entry guards stop BEFORE
            # touching a node, engine, part or maneuver acceptance helper.
            for name,wanted in (('_aerobrakeRestorePe',True),('_aerobrakeTargetingWindowOk',False),
                                ('_aerobrakeBrakingBurn',None),('_aerobrakeDecouple',None)):
                assert execute(function_body(AERO,name),env)==wanted,name
            # A fresh function scope after a reboot retains the same mode.
            entry_helpers(env)
            assert env['aerobrakeEntryOnly']()
        else:assert not env['aerobrakeEntryOnly'](),mode
    print('PASS:42.617s/inside-atmo interrupted repair installs live surface-retrograde and verified zero thrust without accepting/deleting the burn; correction/capture/separation guards and reboot identity remain safe')


def check_passive_phase():
    for inside in (False,True):
        env,sim,data,events=context();ship=env['SHIP'];old=dict(data)
        ship.ALTITUDE=69000 if inside else 72000
        ship.AIRSPEED=2400;ship.ORBIT.APOAPSIS=94717
        ship.PERIAPSIS=48000 # Drag can move Pe outside the repair corridor.
        env['HASNODE']=True;node=NS(TIME=4898201,DELTAV=NS(MAG=.008181178));env['NEXTNODE']=node
        env['aerobrakeApEntryEta']=lambda _:0 if ship.ALTITUDE<70000 else 42.617
        env['aerobrakeApRecover']=lambda:True
        env['_aerobrakeSolarWait']=lambda when:events.append(('solar',when))
        env['_aerobrakeTrimReentryPe']=lambda:execute(function_body(AERO,'_aerobrakeTrimReentryPe'),env)
        env['_aerobrakeReentryTargeting']=lambda:execute(function_body(AERO,'_aerobrakeReentryTargeting'),env)
        for name in ('_aerobrakeRestorePe','_aerobrakeBrakingBurn','_aerobrakeDecouple','_aerobrakeTargetingWindowOk'):
            env[name]=lambda *args,name=name:execute(function_body(AERO,name),dict(env,
                **dict(zip(('atmHeight','targetPe','peLow','peHigh'),args)) if name=='_aerobrakeRestorePe' else
                dict(label=args[0]) if args else {}))
        for name in ('_aerobrakeRetractSolarPanels','_aerobrakeRetractAntennas','_aerobrakeCloseExtendBays'):
            env[name]=lambda name=name:events.append((name,))
        env['_aerobrakeThroughThickPart']=lambda alt:execute(function_body(AERO,'_aerobrakeThroughThickPart'),dict(env,atmHeight=alt))
        ticks=[0]
        def orient():
            # Actual orient helper installs a live lock; ideal attitude
            # removes its alignment wait, without claiming native slew proof.
            ship.SRFRETROGRADE=NS(FOREVECTOR=ship.FACING.FOREVECTOR)
            env['_aerobrakeEntryDirection']=lambda:ship.SRFRETROGRADE
            execute(function_body(AERO,'_aerobrakeOrient').replace('SAS OFF.','SET SAS TO FALSE.'),env)
            ticks[0]+=1
            if ticks[0]==1:ship.ALTITUDE=69000
            else:ship.ORBIT.APOAPSIS=65000;ship.AIRSPEED=500
        env['_aerobrakeOrient']=orient
        env['_aerobrakeAwaitEntry']=lambda *args:False
        env['_aerobrakeAdvance']=lambda:events.append(('descent',))
        # Any attempted engine planning/staging would fail this replay.
        env['aerobrakeApAssist']=lambda *args:(_ for _ in ()).throw(AssertionError('assist during interrupted entry'))
        env['aerobrakeApStageCoast']=env['aerobrakeApAssist']
        execute(function_body(AERO,'phaseAerobrake'),env)
        assert events[-1]==('descent',) and ('yield',) not in events
        assert all(data[k]==value for k,value in old.items())
        assert env['NEXTNODE'] is node and env['HASNODE']
        assert ship.THRUST==0 and ship.CONTROL.MAINTHROTTLE==ship.CONTROL.PILOTMAINTHROTTLE==0
        assert ticks[0]>=2 and sim['steering']=='_aerobrakeEntryDirection()'
    print('PASS: actual AEROBRAKE phase resumes before/inside entry despite retained node and drag-shifted48km Pe, stows hardware, holds live retrograde, and reaches existing600m/s descent handoff without engine planning/staging or prompt exit')


def check_command():
    owner=function_body(COMMAND,'_cmdEntrynow')
    assert COMMAND.rstrip().endswith('_cmdEntrynow().')
    assert owner.index('LOCK THROTTLE TO 0.')<owner.index('bootPreamble()')
    assert owner.index('LOCK STEERING TO SHIP:SRFRETROGRADE.')<owner.index('bootPreamble()')
    assert owner.index('RUNPATH("0:/lib/aerobrake.ks").')<owner.index('bootApplyMissionConfig(')
    assert owner.index('bootApplyMissionConfig(')<owner.index('stateSet("aerobrake_entry_only"')<owner.index('main()')
    assert 'REBOOT.' not in owner and 'stateRemove(' not in owner and 'REMOVE NEXTNODE' not in owner
    assert 'missionProfileBegin(' not in owner and 'missionOverrideClear(' not in owner
    repair=(ROOT/'lib/reentry_pe.ks').read_text()
    assert 'stateRemove("aerobrake_entry_only")' in function_body(repair,'reentryPeRecover')
    print('PASS: entrynow establishes zero throttle/live retrograde before loading, refreshes stale function cache, restores existing craft/profile/overrides and resumes without reboot/replacing mission/clearing markers; successful outside repair reconciliation ends passive rescue')


if __name__=='__main__':
    check_entry_protection()
    check_passive_phase()
    check_command()
